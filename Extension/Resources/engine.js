// Tempo media engine.
//
// Runs in the page's own world so it can reach every media element, including Audio objects that never
// enter the DOM and players inside closed shadow roots. A second copy is loaded in the extension's isolated
// world and stays idle unless the page-world copy never answers (a browser that ignores "world": "MAIN").
// The content script talks to it with CustomEvents whose detail is a JSON string.
(() => {
  'use strict';
  if (window.__tempoEngine) return;
  window.__tempoEngine = true;

  const IN = 'tempo:to-engine';
  const OUT = 'tempo:from-engine';
  const ext = globalThis.browser || globalThis.chrome;
  const isolated = !!(ext && ext.runtime && ext.runtime.id);

  let active = !isolated;
  let target = null;               // forced playbackRate; null = leave media alone
  let refs = [];                   // WeakRef<HTMLMediaElement>, so discarded players can be collected
  const known = new WeakSet();
  const touched = new WeakMap();   // element -> last time it started playing
  const marks = new WeakMap();     // element -> remembered currentTime
  const guard = new WeakMap();     // element -> {t, n} re-apply budget for the current second
  const roots = new WeakMap();     // shadow host -> shadow root (closed ones included)
  const watched = new WeakSet();
  const dirty = new Set();         // shadow roots that gained nodes since the last scan
  let reported = null;
  let scanTimer = 0;

  const MEDIA_EVENTS = ['ratechange', 'play', 'playing', 'loadedmetadata', 'loadeddata', 'emptied'];
  const ROOT_EVENTS = ['play', 'playing', 'loadedmetadata', 'ratechange'];

  const emit = (msg) => document.dispatchEvent(new CustomEvent(OUT, { detail: JSON.stringify(msg) }));
  const isMedia = (el) => !!el && el.nodeType === 1 && (el.localName === 'video' || el.localName === 'audio');
  const hasSource = (el) => !!(el.currentSrc || el.src || el.srcObject || el.readyState > 0);

  function list() {
    const out = [];
    refs = refs.filter((ref) => {
      const el = ref.deref();
      if (el) out.push(el);
      return !!el;
    });
    return out;
  }

  function track(el) {
    if (!active || !isMedia(el) || known.has(el)) return;
    known.add(el);
    refs.push(new WeakRef(el));
    for (const type of MEDIA_EVENTS) el.addEventListener(type, onMediaEvent, true);
    apply(el);
    report();
  }

  function onMediaEvent(e) {
    const el = e.currentTarget;
    if (e.type === 'ratechange') return enforce(el);
    if (e.type === 'play' || e.type === 'playing') touched.set(el, Date.now());
    apply(el);
    report();
  }

  function setRate(el, rate) {
    try { el.playbackRate = rate; } catch {}
  }

  function apply(el) {
    if (!active || target == null) return;
    if (Math.abs(el.playbackRate - target) > 1e-4) setRate(el, target);
  }

  // A page changed the rate behind our back: put it back, but give up for the rest of the second if the
  // page keeps overriding, so the two never spin against each other.
  function enforce(el) {
    if (!active || target == null || Math.abs(el.playbackRate - target) <= 1e-4) return;
    const now = performance.now();
    let g = guard.get(el);
    if (!g || now - g.t > 1000) guard.set(el, (g = { t: now, n: 0 }));
    if (++g.n > 12) return;
    setRate(el, target);
  }

  function setTarget(speed) {
    const next = typeof speed === 'number' && speed > 0 ? speed : null;
    const prev = target;
    target = next;
    for (const el of list()) {
      if (next != null) apply(el);
      else if (prev != null) setRate(el, 1);
    }
  }

  function report() {
    let n = 0;
    for (const el of list()) if (hasSource(el) && (el.isConnected || !el.paused || el.currentTime > 0)) n++;
    if (reported === n > 0) return;
    reported = n > 0;
    emit({ t: 'media', n });
  }

  // ---- discovery ---------------------------------------------------------------------------------------

  function watchRoot(root) {
    if (!root || watched.has(root)) return;
    watched.add(root);
    // Media events do not leave a shadow tree, so each root gets its own capture listeners.
    for (const type of ROOT_EVENTS) root.addEventListener(type, (e) => track(e.target), true);
    observer.observe(root, { childList: true, subtree: true });
    if (root.querySelectorAll) for (const el of root.querySelectorAll('video,audio')) track(el);
    deepScan(root);
  }

  // One observer for the document and every shadow root; the work itself is batched in rescan().
  const observer = new MutationObserver((records) => {
    for (const r of records) {
      if (!r.addedNodes.length) continue;
      const root = r.target.getRootNode();
      if (root.nodeType === 11) dirty.add(root);
      schedule();
    }
  });

  function deepScan(root) {
    const doc = root.ownerDocument || root;
    const walker = doc.createTreeWalker(root, NodeFilter.SHOW_ELEMENT);
    for (let n = walker.nextNode(); n; n = walker.nextNode()) {
      const sr = n.shadowRoot || roots.get(n);
      if (sr) watchRoot(sr);
    }
  }

  function rescan(deep) {
    for (const tag of ['video', 'audio']) for (const el of document.getElementsByTagName(tag)) track(el);
    for (const root of dirty) {
      for (const el of root.querySelectorAll('video,audio')) track(el);
      if (deep) deepScan(root);
    }
    dirty.clear();
    if (deep) deepScan(document);
    report();
  }

  function schedule() {
    if (scanTimer) return;
    scanTimer = setTimeout(() => {
      scanTimer = 0;
      rescan(isolated);   // the standby copy has no attachShadow hook, so it walks for open roots instead
    }, 300);
  }

  function hook() {
    const proto = HTMLMediaElement.prototype;
    const nativePlay = proto.play;
    proto.play = {
      play() {
        try { track(this); touched.set(this, Date.now()); } catch {}
        return nativePlay.apply(this, arguments);
      },
    }.play;
    const nativeAttach = Element.prototype.attachShadow;
    Element.prototype.attachShadow = {
      attachShadow() {
        const root = nativeAttach.apply(this, arguments);
        try { roots.set(this, root); watchRoot(root); } catch {}
        return root;
      },
    }.attachShadow;
  }

  function start() {
    if (!isolated) hook();
    watchRoot(document);
    const full = () => rescan(true);
    if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', full, { once: true });
    else full();
    window.addEventListener('load', full, { once: true });
    emit({ t: 'hello' });
  }

  // ---- commands ----------------------------------------------------------------------------------------

  function pick() {
    let best = null;
    let bestScore = -1;
    for (const el of list()) {
      if (!hasSource(el)) continue;
      let score = 0;
      if (!el.paused && !el.ended) score += 1000;
      if (Number.isFinite(el.duration) ? el.duration > 30 : el.readyState > 0) score += 200;   // content, not a sound effect
      if (el.localName === 'video' && el.isConnected) {
        const r = el.getBoundingClientRect();
        const w = Math.min(r.right, innerWidth) - Math.max(r.left, 0);
        const h = Math.min(r.bottom, innerHeight) - Math.max(r.top, 0);
        if (w > 0 && h > 0) score += 300 + Math.min(200, (w * h) / 2500);   // on screen beats hidden or detached
      }
      score += Math.max(0, 50 - (Date.now() - (touched.get(el) || 0)) / 60000);   // recently played wins ties
      if (score > bestScore) { best = el; bestScore = score; }
    }
    return best;
  }

  function clampTime(el, t) {
    if (Number.isFinite(el.duration)) return Math.min(Math.max(0, t), el.duration);
    const s = el.seekable;
    if (s && s.length) return Math.min(Math.max(s.start(0), t), s.end(s.length - 1));
    return Math.max(0, t);
  }

  // What the player the commands act on is doing right now. Reading it changes nothing.
  function snapshot(el) {
    return {
      kind: el.localName,
      paused: el.paused,
      muted: el.muted,
      time: el.currentTime,
      duration: Number.isFinite(el.duration) ? el.duration : null,
      rate: el.playbackRate,
      pip: document.pictureInPictureElement === el || el.webkitPresentationMode === 'picture-in-picture',
      mark: marks.has(el) ? marks.get(el) : null,
    };
  }

  function command(name, value) {
    const el = pick();
    if (!el) return null;
    switch (name) {
      case 'state':
        return snapshot(el);
      case 'seek':
        el.currentTime = clampTime(el, el.currentTime + value);
        return { time: el.currentTime };
      case 'frame':
        if (!el.paused) el.pause();
        el.currentTime = clampTime(el, el.currentTime + value / 30);
        return { time: el.currentTime };
      case 'pause':
        if (el.paused) { const p = el.play(); if (p && p.catch) p.catch(() => {}); return { paused: false }; }
        el.pause();
        return { paused: true };
      case 'mute':
        el.muted = !el.muted;
        return { muted: el.muted };
      case 'mark':
        marks.set(el, el.currentTime);
        return { time: el.currentTime };
      case 'jump': {
        const t = marks.get(el);
        if (t == null) return { time: null };
        el.currentTime = clampTime(el, t);
        return { time: t };
      }
      case 'pip': {
        if (el.localName !== 'video' || typeof el.requestPictureInPicture !== 'function') return null;
        const p = document.pictureInPictureElement === el ? document.exitPictureInPicture() : el.requestPictureInPicture();
        if (p && p.catch) p.catch(() => {});
        return { pip: true };
      }
    }
    return null;
  }

  function isEditable(el) {
    if (!el || el.nodeType !== 1) return false;
    if (el.isContentEditable) return true;
    const tag = el.localName;
    if (tag === 'textarea' || tag === 'select') return true;
    if (tag === 'input') return !/^(button|checkbox|radio|range|submit|reset|color|file|image)$/i.test(el.type);
    const role = el.getAttribute('role');
    return role === 'textbox' || role === 'searchbox' || role === 'combobox';
  }

  // Focus can sit in a text field inside a closed shadow root, which only this world can see into.
  function focusEditable() {
    let el = document.activeElement;
    for (let i = 0; el && i < 20; i++) {
      const sr = el.shadowRoot || roots.get(el);
      const inner = sr && sr.activeElement;
      if (!inner) break;
      el = inner;
    }
    return isEditable(el);
  }

  document.addEventListener(IN, (e) => {
    let m;
    try { m = JSON.parse(e.detail); } catch { return; }
    if (!m) return;
    if (m.t === 'ping') { if (!isolated) emit({ t: 'pong' }); return; }
    if (m.t === 'fallback') { if (isolated && !active) { active = true; start(); } return; }
    if (!active) return;
    if (m.t === 'config') setTarget(m.speed);
    else if (m.t === 'editable?') emit({ t: 'editable', v: focusEditable() });
    else if (m.t === 'cmd') emit({ t: 'did', name: m.name, value: m.value, result: command(m.name, m.value) });
  });

  if (active) start();
})();
