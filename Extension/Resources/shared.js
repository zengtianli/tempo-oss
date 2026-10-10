// Shared by the content script and the popup: defaults, validation, speed rules, key names.
(() => {
  'use strict';

  const ACTIONS = [
    ['slower', '减速'],
    ['faster', '加速'],
    ['reset', '1× / 上次速度'],
    ['rewind', '快退'],
    ['forward', '快进'],
    ['framePrev', '上一帧'],
    ['frameNext', '下一帧'],
    ['mark', '记下当前位置'],
    ['jump', '回到记下的位置'],
    ['pause', '播放 / 暂停'],
    ['mute', '静音'],
    ['pip', '画中画'],
    ['toggle', '开 / 关 Tempo'],
  ];

  const DEFAULTS = {
    enabled: true,
    speed: 1,          // speed for every site without its own rule
    last: 1.5,         // what "reset" switches back to from 1×
    step: 0.1,
    seek: 10,
    indicator: true,
    remote: false,     // let the `tempo` command act on the page in the current tab (see background.js)
    rules: {},         // host -> speed
    off: {},           // host -> true
    keys: {
      slower: 'KeyA', faster: 'KeyD', reset: 'KeyS',
      rewind: 'KeyZ', forward: 'KeyX',
      framePrev: 'Shift+KeyZ', frameNext: 'Shift+KeyX',
      mark: 'Shift+KeyW', jump: 'KeyW',
      pause: '', mute: '', pip: '', toggle: '',
    },
  };

  const PRESETS = [0.25, 0.5, 0.75, 1, 1.25, 1.5, 1.75, 2, 2.5, 3, 4, 5];
  const MIN = 0.1;
  const MAX = 16;

  const round = (v) => Math.round(v * 100) / 100;
  const clamp = (v) => Math.min(MAX, Math.max(MIN, round(Number(v) || 1)));
  const fmt = (v) => String(round(v)) + '×';
  const plain = (o) => (o && typeof o === 'object' && !Array.isArray(o) ? Object.assign({}, o) : {});
  const own = (o, k) => Object.prototype.hasOwnProperty.call(o, k);

  function normalize(raw) {
    const c = Object.assign({}, DEFAULTS, plain(raw));
    c.enabled = c.enabled !== false;
    c.speed = clamp(c.speed);
    c.last = clamp(c.last);
    c.step = Math.min(1, Math.max(0.01, round(Number(c.step) || DEFAULTS.step)));
    c.seek = Math.min(600, Math.max(1, Math.round(Number(c.seek) || DEFAULTS.seek)));
    c.indicator = c.indicator !== false;
    c.remote = c.remote === true;
    c.rules = plain(c.rules);
    for (const k of Object.keys(c.rules)) c.rules[k] = clamp(c.rules[k]);
    c.off = plain(c.off);
    const keys = plain(c.keys);
    c.keys = {};
    for (const [a] of ACTIONS) c.keys[a] = typeof keys[a] === 'string' ? keys[a] : DEFAULTS.keys[a];
    return c;
  }

  const hostKey = (h) => String(h || '').toLowerCase().replace(/^www\./, '');

  // A rule for example.com also covers its subdomains.
  function match(map, host) {
    if (!host) return null;
    if (own(map, host)) return [host, map[host]];
    for (const k of Object.keys(map)) if (host.endsWith('.' + k)) return [k, map[k]];
    return null;
  }

  function state(cfg, host) {
    const rule = match(cfg.rules, host);
    const siteOff = !!match(cfg.off, host);
    return { off: !cfg.enabled || siteOff, siteOff, rule, speed: rule ? rule[1] : cfg.speed };
  }

  // The storage change that sets the speed: a site with its own rule keeps its own number.
  function speedPatch(cfg, host, value) {
    const v = clamp(value);
    const rule = match(cfg.rules, host);
    const patch = rule ? { rules: Object.assign({}, cfg.rules, { [rule[0]]: v }) } : { speed: v };
    if (Math.abs(v - 1) > 1e-6) patch.last = v;
    return patch;
  }

  // The speed a "slower", "faster" or "reset" press leads to.
  function target(cfg, host, action) {
    const speed = state(cfg, host).speed;
    if (action === 'slower') return clamp(speed - cfg.step);
    if (action === 'faster') return clamp(speed + cfg.step);
    return Math.abs(speed - 1) > 1e-6 ? 1 : cfg.last;
  }

  // The remaining settings changes, as storage patches. The popup and the `tempo` command both go through
  // these, so the two cannot drift apart.
  function without(map, host) {
    const next = Object.assign({}, map);
    const hit = match(next, host);
    if (hit) delete next[hit[0]];
    return next;
  }

  // "Remember a speed for this site": on keeps `value` (the speed the site plays at now when left out).
  function rulePatch(cfg, host, on, value) {
    const rules = without(cfg.rules, host);
    if (on) rules[host] = clamp(value === undefined ? state(cfg, host).speed : value);
    return { rules };
  }

  function offPatch(cfg, host, on) {
    const off = without(cfg.off, host);
    if (on) off[host] = true;
    return { off };
  }

  // A combination belongs to one action: binding it here clears it wherever it was (`freed`).
  function bindPatch(cfg, action, combo) {
    const keys = Object.assign({}, cfg.keys);
    let freed = '';
    if (combo) for (const [other] of ACTIONS) if (other !== action && keys[other] === combo) { keys[other] = ''; freed = other; }
    keys[action] = combo;
    return { patch: { keys }, freed };
  }

  // The actions that work on the media itself; the rest change settings.
  const MEDIA_ACTIONS = ['rewind', 'forward', 'framePrev', 'frameNext', 'mark', 'jump', 'pause', 'mute', 'pip'];

  // Why an action cannot run on a page right now, as a short code; '' when it can. A key press and the
  // `tempo` command are let through, or not, by this one rule.
  function blocked(cfg, host, action, hasMedia) {
    if (!hasMedia) return 'no_media';
    const s = state(cfg, host);
    if (s.siteOff) return 'site_off';
    if (s.off && action !== 'toggle') return 'tempo_off';
    return '';
  }

  // What a page says about itself to `tempo page`: the facts the popup's site line and the badge show.
  function pageView(cfg, host, hasMedia) {
    const s = state(cfg, host);
    return { host, speed: s.speed, off: s.off, site_off: s.siteOff, rule: s.rule ? { host: s.rule[0], speed: s.rule[1] } : null, has_media: !!hasMedia };
  }

  // Whether a media action really happened, judged from what the player said before and after: `result` is
  // the engine's answer, `before` and `after` its state. Pages may refuse to start playing, and Safari may
  // refuse picture in picture, when no real key press stands behind the request.
  function outcome(action, before, result, after) {
    if (!MEDIA_ACTIONS.includes(action)) return '';
    if (action === 'pip' && before && before.kind !== 'video') return 'not_video';
    if (action === 'pip' && before && !result) return 'unsupported';
    if (!result || !after) return 'no_media';
    if (action === 'jump' && result.time == null) return 'no_mark';
    if (action === 'pause' && result.paused !== after.paused) return 'not_allowed';
    if (action === 'pip' && before && before.pip === after.pip) return 'not_allowed';
    return '';
  }

  function combo(e) {
    const code = e.code;
    if (!code || /^(Shift|Control|Alt|Meta|OS)(Left|Right)?$/.test(code)) return '';
    return (e.ctrlKey ? 'Ctrl+' : '') + (e.altKey ? 'Alt+' : '') + (e.shiftKey ? 'Shift+' : '') + (e.metaKey ? 'Meta+' : '') + code;
  }

  const CODE_LABELS = {
    ArrowLeft: '←', ArrowRight: '→', ArrowUp: '↑', ArrowDown: '↓', Space: '空格', Enter: '↩', Tab: '⇥',
    Comma: ',', Period: '.', Slash: '/', Semicolon: ';', Quote: "'", BracketLeft: '[', BracketRight: ']',
    Backslash: '\\', Minus: '-', Equal: '=', Backquote: '`',
  };
  const MOD_LABELS = { Ctrl: '⌃', Alt: '⌥', Shift: '⇧', Meta: '⌘' };

  function label(c) {
    if (!c) return '—';
    const parts = c.split('+');
    const code = parts.pop();
    const key = CODE_LABELS[code] || code.replace(/^Key|^Digit/, '').replace(/^Numpad/, '小键盘 ');
    return parts.map((m) => MOD_LABELS[m] || m).join('') + key;
  }

  globalThis.Tempo = { ACTIONS, MEDIA_ACTIONS, DEFAULTS, PRESETS, MIN, MAX, round, clamp, fmt, normalize, hostKey, match, state, speedPatch, target, rulePatch, offPatch, bindPatch, blocked, pageView, outcome, combo, label };
})();
