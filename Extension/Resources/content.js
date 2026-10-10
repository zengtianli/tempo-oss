// Tempo content script (isolated world, every frame): owns settings, hotkeys and the on-page indicator,
// and tells the media engine which speed to hold.
(() => {
  'use strict';
  const api = globalThis.browser || globalThis.chrome;
  const T = globalThis.Tempo;
  if (!T || !api || !api.runtime || !api.runtime.id || window.__tempoContent) return;
  window.__tempoContent = true;

  const IN = 'tempo:to-engine';
  const OUT = 'tempo:from-engine';
  const REPEATABLE = new Set(['slower', 'faster', 'rewind', 'forward', 'framePrev', 'frameNext']);
  const isTop = window === window.top;
  const host = T.hostKey(topHost());

  let cfg = T.normalize({});
  let ready = false;
  let lookup = {};
  let localHas = false;        // this frame has media
  let tabHas = false;          // some frame of this tab has media
  let enginePresent = false;
  let engineEditable = false;
  let lastBadge = null;
  let answer = null;           // the engine's reply to the command just sent; it replies before toEngine returns
  let link = null;             // port to the background page, held while the `tempo` command may reach this frame
  const swallowed = new Set();

  function topHost() {
    if (isTop) return location.hostname;
    try {
      const chain = location.ancestorOrigins;
      if (chain && chain.length) return new URL(chain[chain.length - 1]).hostname;
    } catch {}
    try { return new URL(document.referrer).hostname; } catch {}
    return location.hostname;
  }

  const toEngine = (m) => document.dispatchEvent(new CustomEvent(IN, { detail: JSON.stringify(m) }));

  function send(m, onReply) {
    try {
      const p = api.runtime.sendMessage(m);
      if (p && p.then) p.then((r) => onReply && onReply(r), () => {});
    } catch {}
  }

  // ---- settings ----------------------------------------------------------------------------------------

  function push() {
    const s = T.state(cfg, host);
    toEngine({ t: 'config', speed: s.off ? null : s.speed });
    relink();
    if (!isTop) return;
    const text = s.off || Math.abs(s.speed - 1) < 1e-6 ? '' : String(T.round(s.speed));
    if (text !== lastBadge) send({ t: 'badge', text: (lastBadge = text) });
  }

  function adopt(raw) {
    cfg = T.normalize(raw);
    lookup = {};
    for (const [action] of T.ACTIONS) if (cfg.keys[action]) lookup[cfg.keys[action]] = action;
  }

  // While a key is held, each press builds on the local value. Echoes of our own writes arrive late and
  // would roll it back, so they are skipped and storage is read once more after the burst.
  let quietUntil = 0;
  let resyncTimer = 0;

  function save(patch) {
    adopt(Object.assign({}, cfg, patch));
    push();
    quietUntil = Date.now() + 300;
    clearTimeout(resyncTimer);
    resyncTimer = setTimeout(resync, 350);
    try {
      const p = api.storage.local.set(patch);
      if (p && p.catch) p.catch(() => {});
    } catch {}
  }

  function resync() {
    api.storage.local.get(null).then((raw) => { adopt(raw); push(); }, () => {});
  }

  // The `tempo` command writes the same store from outside Safari, and such a write raises no change
  // event. So the settings are read once more whenever this page comes back into view or gets the focus.
  function reread() {
    if (ready && Date.now() >= quietUntil && (isTop || localHas || tabHas)) resync();
  }
  document.addEventListener('visibilitychange', () => { if (!document.hidden) reread(); });
  window.addEventListener('focus', reread);

  function wakeEngine() {
    toEngine({ t: 'ping' });
    if (!enginePresent) toEngine({ t: 'fallback' });
    push();
  }

  api.storage.local.get(null).then((raw) => {
    adopt(raw);
    ready = true;
    toEngine({ t: 'ping' });
    push();
    // The page-world engine may be injected after this script; only fall back once the document has parsed.
    if (!enginePresent) {
      if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', wakeEngine, { once: true });
      else setTimeout(wakeEngine, 0);
    }
    send({ t: 'hello' }, (r) => { if (r && typeof r.has === 'boolean') tabHas = r.has; });
  }, () => {});

  api.storage.onChanged.addListener((changes, area) => {
    if (area !== 'local' || Date.now() < quietUntil) return;
    const next = Object.assign({}, cfg);
    for (const k of Object.keys(changes)) next[k] = changes[k].newValue;
    adopt(next);
    if (ready) push();
  });

  // ---- engine and tab messages -------------------------------------------------------------------------

  document.addEventListener(OUT, (e) => {
    let m;
    try { m = JSON.parse(e.detail); } catch { return; }
    if (!m) return;
    if (m.t === 'pong') enginePresent = true;
    else if (m.t === 'hello') { enginePresent = true; if (ready) push(); }
    else if (m.t === 'editable') engineEditable = !!m.v;
    else if (m.t === 'media') { localHas = m.n > 0; send({ t: 'media', has: localHas }); relink(); }
    else if (m.t === 'did') { answer = m; describe(m); }
  });

  api.runtime.onMessage.addListener((m, sender, sendResponse) => {
    if (!m) return;
    if (m.t === 'cmd') { if (localHas) toEngine(m); }
    else if (m.t === 'indicate') { if (isTop) show(m.text); }
    else if (m.t === 'tabmedia') tabHas = !!m.has;
    else if (m.t === 'rollcall') { if (localHas) send({ t: 'media', has: true }); }
    else if (m.t === 'reread') { if (ready) resync(); }
    else if (m.t === 'remote') return remote(m, sendResponse);
  });

  window.addEventListener('pagehide', () => { if (localHas) send({ t: 'media', has: false }); unlink(); });
  window.addEventListener('pageshow', relink);

  // ---- hotkeys -----------------------------------------------------------------------------------------

  function isEditable(el) {
    if (!el || el.nodeType !== 1) return false;
    if (el.isContentEditable) return true;
    const tag = el.localName;
    if (tag === 'textarea' || tag === 'select') return true;
    if (tag === 'input') return !/^(button|checkbox|radio|range|submit|reset|color|file|image)$/i.test(el.type);
    const role = el.getAttribute('role');
    return role === 'textbox' || role === 'searchbox' || role === 'combobox';
  }

  function typing(e) {
    const path = e.composedPath ? e.composedPath() : [];
    if (isEditable(path[0] || e.target)) return true;
    let el = document.activeElement;
    while (el && el.shadowRoot && el.shadowRoot.activeElement) el = el.shadowRoot.activeElement;
    if (isEditable(el) || document.designMode === 'on') return true;
    engineEditable = false;
    toEngine({ t: 'editable?' });   // answered synchronously; covers closed shadow roots
    return engineEditable;
  }

  function stop(e) {
    e.preventDefault();
    e.stopImmediatePropagation();
  }

  function onKeyDown(e) {
    if (!ready || e.isComposing || e.keyCode === 229) return;
    const action = lookup[T.combo(e)];
    if (!action || T.blocked(cfg, host, action, localHas || tabHas)) return;
    if (typing(e)) return;
    stop(e);
    swallowed.add(e.code);
    if (e.repeat && !REPEATABLE.has(action)) return;
    run(action);
  }

  window.addEventListener('keydown', onKeyDown, true);
  window.addEventListener('keypress', (e) => { if (swallowed.has(e.code)) stop(e); }, true);
  window.addEventListener('keyup', (e) => { if (swallowed.delete(e.code)) stop(e); }, true);
  window.addEventListener('blur', () => swallowed.clear());

  function setSpeed(v) {
    const speed = T.clamp(v);
    save(T.speedPatch(cfg, host, speed));
    indicate(T.fmt(speed));
  }

  // Hands back the engine's answer when the media is in this frame; a frame without media passes the
  // command on to the frames that have some and learns nothing.
  function media(name, value) {
    if (!localHas) return void send({ t: 'relay', name, value });
    answer = null;
    toEngine({ t: 'cmd', name, value });
    return answer && answer.result;
  }

  // One action, whoever asked for it: a key press (onKeyDown) or the `tempo` command (remote).
  function run(action) {
    switch (action) {
      case 'slower': case 'faster': case 'reset': return setSpeed(T.target(cfg, host, action));
      case 'toggle':
        save({ enabled: !cfg.enabled });
        return indicate(cfg.enabled ? T.fmt(T.state(cfg, host).speed) : '已关闭');
      case 'rewind': return media('seek', -cfg.seek);
      case 'forward': return media('seek', cfg.seek);
      case 'framePrev': return media('frame', -1);
      case 'frameNext': return media('frame', 1);
      default: return media(action);
    }
  }

  function clock(t) {
    const s = Math.max(0, Math.floor(t));
    const pad = (n) => String(n).padStart(2, '0');
    const h = Math.floor(s / 3600);
    return (h ? h + ':' + pad(Math.floor(s / 60) % 60) : Math.floor(s / 60)) + ':' + pad(s % 60);
  }

  function describe(m) {
    const r = m.result;
    if (!r) return;
    switch (m.name) {
      case 'seek': return show((m.value > 0 ? '» ' : '« ') + Math.abs(m.value) + ' 秒');
      case 'frame': return show(m.value > 0 ? '下一帧' : '上一帧');
      case 'pause': return show(r.paused ? '暂停' : '播放');
      case 'mute': return show(r.muted ? '静音' : '取消静音');
      case 'mark': return show('已记下 ' + clock(r.time));
      case 'jump': return show(r.time == null ? '还没有记下位置' : '回到 ' + clock(r.time));
    }
  }

  // ---- the `tempo` command -----------------------------------------------------------------------------

  // With "remote" on, a frame that has media keeps one port to the background page open. The port is what
  // keeps that page loaded and waiting for the command line; with the setting off, or no media anywhere,
  // nothing is kept awake. A port that drops is not reopened on a timer: the next settings read or media
  // event brings it back.
  function relink() {
    const want = ready && cfg.remote && localHas;
    if (want && !link) {
      try {
        const port = api.runtime.connect({ name: 'media' });
        port.onDisconnect.addListener(() => { if (link === port) link = null; });
        link = port;
      } catch { link = null; }
    } else if (!want && link) unlink();
  }

  function unlink() {
    if (!link) return;
    try { link.disconnect(); } catch {}
    link = null;
  }

  // An action asked for by `tempo do`, or the page's own description for `tempo page`. It goes through
  // blocked() and run() exactly as a key press does; only the "is someone typing" check is left out,
  // because nobody pressed a key. The top frame answers for the page. When the media sits in another frame
  // it says so (`relay`), the background page asks every frame (`m.frame`), and the frames with media
  // answer. The reply is sent a moment later, so that it carries what the player really did.
  function remote(m, reply) {
    const mine = localHas;
    if (m.frame ? !mine : !isTop) return;
    const page = () => T.pageView(cfg, host, localHas || tabHas);
    const look = () => (mine ? media('state') : null);
    if (!ready) return void reply({ error: 'not_ready', page: page() });
    if (m.action === 'page') {
      if (!m.frame && !mine && tabHas) return void reply({ relay: true, page: page() });
      return void reply({ page: page(), media: look() || null });
    }
    if (!T.ACTIONS.some(([a]) => a === m.action)) return void reply({ error: 'unknown_action', page: page() });
    const why = T.blocked(cfg, host, m.action, localHas || tabHas);
    if (why) return void reply({ error: why, page: page() });
    const onMedia = T.MEDIA_ACTIONS.includes(m.action);
    if (onMedia && !mine) return void reply({ relay: true, page: page() });
    const before = look();
    const result = run(m.action);
    setTimeout(() => {
      const after = look();
      reply({ action: m.action, page: page(), before: before || null, result: onMedia ? result || null : null, media: after || null,
              error: T.outcome(m.action, before, result, after) || undefined });
    }, m.action === 'pip' ? 700 : 150);
    return true;   // the reply comes later
  }

  // ---- indicator ---------------------------------------------------------------------------------------

  let box = null;
  let pill = null;
  let hideTimer = 0;

  function indicate(text) {
    if (isTop || localHas || document.fullscreenElement) show(text);
    else send({ t: 'indicate', text });
  }

  function show(text) {
    if (!cfg.indicator || !document.documentElement) return;
    if (!box) {
      box = document.createElement('div');
      box.setAttribute('popover', 'manual');   // top layer, so it stays above a fullscreen player
      box.style.cssText = 'all:initial;display:block;position:fixed;inset:14px auto auto 14px;margin:0;padding:0;border:0;'
        + 'background:none;overflow:visible;pointer-events:none;z-index:2147483647;';
      pill = document.createElement('div');
      pill.style.cssText = 'font:600 20px/1 -apple-system,BlinkMacSystemFont,system-ui,sans-serif;font-variant-numeric:tabular-nums;'
        + 'color:#fff;background:rgba(22,22,24,.78);-webkit-backdrop-filter:blur(14px) saturate(1.5);backdrop-filter:blur(14px) saturate(1.5);'
        + 'padding:9px 13px;border-radius:10px;box-shadow:0 2px 12px rgba(0,0,0,.28);white-space:nowrap;';
      box.attachShadow({ mode: 'closed' }).appendChild(pill);
    }
    pill.textContent = text;
    document.documentElement.appendChild(box);
    try {
      if (box.matches(':popover-open')) box.hidePopover();
      box.showPopover();
    } catch {}
    clearTimeout(hideTimer);
    hideTimer = setTimeout(() => {
      try { box.hidePopover(); } catch {}
      box.remove();
    }, 1200);
  }
})();
