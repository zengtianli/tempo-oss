// Tempo popup: the same settings the content script reads, edited through storage.
(() => {
  'use strict';
  const api = globalThis.browser || globalThis.chrome;
  const T = globalThis.Tempo;
  const $ = (id) => document.getElementById(id);

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
      $('host').textContent = s.rule ? `${s.rule[0]} · 单独速度 ${T.fmt(s.rule[1])}` : `${host} · 跟随全局速度`;
      $('siteRule').checked = !!s.rule;
      $('siteOff').checked = s.siteOff;
    }

    for (const b of $('keys').querySelectorAll('button')) {
      const on = listening === b.dataset.action;
      b.classList.toggle('listening', on);
      b.textContent = on ? '按下按键…' : T.label(cfg.keys[b.dataset.action]);
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
    for (const [action, name] of T.ACTIONS) {
      const span = document.createElement('span');
      span.textContent = name;
      const b = document.createElement('button');
      b.dataset.action = action;
      b.addEventListener('click', () => { listening = listening === action ? null : action; render(); });
      $('keys').append(span, b);
    }
  }

  function bind(action, combo) {
    const { patch, freed } = T.bindPatch(cfg, action, combo);
    listening = null;
    save(patch);
    const name = freed && T.ACTIONS.find(([a]) => a === freed)[1];
    note(freed ? `${T.label(combo)} 原来用于“${name}”，已改到这里。` : '');
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
      try { await navigator.clipboard.writeText(text); note('配置已复制到剪贴板，也显示在上面。'); }
      catch { note('配置显示在上面，全选后复制保存。'); }
    });
    $('import').addEventListener('click', async () => {
      if ($('io').hidden || !$('io').value.trim()) {
        $('io').hidden = false;
        $('io').value = '';
        $('io').focus();
        return note('粘贴配置后再点一次“导入配置”。');
      }
      let raw;
      try { raw = JSON.parse($('io').value); } catch { return note('这段内容不是有效的配置，原配置没有改动。'); }
      if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return note('这段内容不是有效的配置，原配置没有改动。');
      await save(T.normalize(raw));
      note('已导入。');
    });
    $('defaults').addEventListener('click', async () => {
      if (Date.now() - confirmReset > 4000) {
        confirmReset = Date.now();
        return note('再点一次“恢复默认”确认：速度、网站规则和快捷键都会回到初始值。');
      }
      confirmReset = 0;
      await api.storage.local.clear();
      cfg = T.normalize({});
      render();
      note('已恢复默认。');
    });
    document.addEventListener('keydown', onKeyDown, true);
  }

  async function init() {
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
