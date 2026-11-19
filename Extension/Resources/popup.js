// Tempo popup: the same settings the content script reads, edited through storage.
(() => {
  'use strict';
  const api = globalThis.browser || globalThis.chrome;
  const T = globalThis.Tempo;
  const $ = (id) => document.getElementById(id);
  const message = (key, substitutions) => api.i18n.getMessage(key, substitutions);

  function localize() {
    document.documentElement.lang = api.i18n.getUILanguage();
    for (const el of document.querySelectorAll('[data-i18n]')) el.textContent = message(el.dataset.i18n);
    for (const attr of ['title', 'placeholder', 'aria-label']) {
      for (const el of document.querySelectorAll(`[data-i18n-${attr}]`)) {
        el.setAttribute(attr, message(el.getAttribute(`data-i18n-${attr}`)));
      }
    }
  }

  // Keep shared.js key names unchanged: the CLI consumes that same formatter.
  function keyLabel(combo) {
    return T.label(combo).replace(T.label('Space'), message('key_space'))
      .replace(T.label('Numpad'), message('key_numpad') + ' ');
  }

  let cfg = T.normalize({});
  let host = '';
  let listening = null;     // action whose key is being re-bound
  let confirmReset = 0;

  const note = (text) => { $('note').textContent = text || ''; };

  function save(patch) {
    cfg = T.normalize(Object.assign({}, cfg, patch));
    render();
    return api.storage.local.set(patch);
  }

  const setSpeed = (v) => save(T.speedPatch(cfg, host, v));

  function render() {
    const s = T.state(cfg, host);
    document.body.classList.toggle('off', s.off);
    $('enabled').checked = cfg.enabled;
    $('speed').textContent = T.fmt(s.speed);
    for (const b of $('presets').children) b.classList.toggle('on', Math.abs(Number(b.dataset.v) - s.speed) < 1e-6);

    $('site').hidden = !host;
    if (host) {
      $('host').textContent = s.rule ? message('site_custom_speed', [s.rule[0], T.fmt(s.rule[1])]) : message('site_global_speed', host);
      $('host').title = $('host').textContent;
      $('siteRule').checked = !!s.rule;
      $('siteOff').checked = s.siteOff;
    }

    for (const b of $('keys').querySelectorAll('button')) {
      const on = listening === b.dataset.action;
      b.classList.toggle('listening', on);
      b.textContent = on ? message('shortcut_listening') : keyLabel(cfg.keys[b.dataset.action]);
    }
    if (document.activeElement !== $('step')) $('step').value = cfg.step;
    if (document.activeElement !== $('seek')) $('seek').value = cfg.seek;
    $('indicator').checked = cfg.indicator;
    $('remote').checked = cfg.remote;
  }

  function build() {
    for (const v of T.PRESETS) {
      const b = document.createElement('button');
      b.dataset.v = v;
      b.textContent = String(v);
      b.addEventListener('click', () => setSpeed(v));
      $('presets').appendChild(b);
    }
    for (const [action] of T.ACTIONS) {
      const span = document.createElement('span');
      span.textContent = message('action_' + action);
      const b = document.createElement('button');
      b.dataset.action = action;
      b.setAttribute('aria-label', message('shortcut_for_action', span.textContent));
      b.addEventListener('click', () => { listening = listening === action ? null : action; render(); });
      $('keys').append(span, b);
    }
  }

  function bind(action, combo) {
    const { patch, freed } = T.bindPatch(cfg, action, combo);
    listening = null;
    save(patch);
    note(freed ? message('shortcut_reassigned', [keyLabel(combo), message('action_' + freed)]) : '');
  }

  function onKeyDown(e) {
    if (listening) {
      e.preventDefault();
      if (e.code === 'Escape') { listening = null; return render(); }
      if (e.code === 'Backspace' || e.code === 'Delete') return bind(listening, '');
      const combo = T.combo(e);
      if (combo) bind(listening, combo);
      return;
    }
    if (/^(INPUT|TEXTAREA)$/.test(e.target.tagName) && e.target.type !== 'checkbox') return;
    const action = Object.keys(cfg.keys).find((a) => cfg.keys[a] && cfg.keys[a] === T.combo(e));
    if (action === 'slower' || action === 'faster' || action === 'reset') setSpeed(T.target(cfg, host, action));
    else if (action === 'toggle') save({ enabled: !cfg.enabled });
    else return;
    e.preventDefault();
  }

  function wire() {
    $('enabled').addEventListener('change', (e) => save({ enabled: e.target.checked }));
    $('slower').addEventListener('click', () => setSpeed(T.target(cfg, host, 'slower')));
    $('faster').addEventListener('click', () => setSpeed(T.target(cfg, host, 'faster')));
    $('speed').addEventListener('click', () => setSpeed(T.target(cfg, host, 'reset')));
    $('siteRule').addEventListener('change', (e) => save(T.rulePatch(cfg, host, e.target.checked)));
    $('siteOff').addEventListener('change', (e) => save(T.offPatch(cfg, host, e.target.checked)));
    $('step').addEventListener('change', (e) => save({ step: Number(e.target.value) }));
    $('seek').addEventListener('change', (e) => save({ seek: Number(e.target.value) }));
    $('indicator').addEventListener('change', (e) => save({ indicator: e.target.checked }));
    $('remote').addEventListener('change', (e) => save({ remote: e.target.checked }));

    $('export').addEventListener('click', async () => {
      const text = JSON.stringify(cfg, null, 2);
      $('io').hidden = false;
      $('io').value = text;
      $('io').select();
      try { await navigator.clipboard.writeText(text); note(message('export_copied')); }
      catch { note(message('export_copy_manually')); }
    });
    $('import').addEventListener('click', async () => {
      if ($('io').hidden || !$('io').value.trim()) {
        $('io').hidden = false;
        $('io').value = '';
        $('io').focus();
        return note(message('import_prompt'));
      }
      let raw;
      try { raw = JSON.parse($('io').value); } catch { return note(message('import_invalid')); }
      if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return note(message('import_invalid'));
      await save(T.normalize(raw));
      note(message('import_done'));
    });
    $('defaults').addEventListener('click', async () => {
      if (Date.now() - confirmReset > 4000) {
        confirmReset = Date.now();
        return note(message('defaults_confirm'));
      }
      confirmReset = 0;
      await api.storage.local.clear();
      cfg = T.normalize({});
      render();
      note(message('defaults_done'));
    });
    document.addEventListener('keydown', onKeyDown, true);
  }

  async function init() {
    localize();
    build();
    wire();
    try { cfg = T.normalize(await api.storage.local.get(null)); } catch {}
    try {
      const [tab] = await api.tabs.query({ active: true, currentWindow: true });
      if (tab && /^https?:/.test(tab.url || '')) host = T.hostKey(new URL(tab.url).hostname);
    } catch {}
    render();
    api.storage.onChanged.addListener((changes, area) => {
      if (area !== 'local') return;
      const next = Object.assign({}, cfg);
      for (const k of Object.keys(changes)) next[k] = changes[k].newValue;
      cfg = T.normalize(next);
      render();
    });
  }

  init();
})();
