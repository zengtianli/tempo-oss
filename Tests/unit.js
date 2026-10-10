// Rule and key-name checks for shared.js, run as a function body where `Tempo` is defined.
const T = globalThis.Tempo;
const results = [];
const check = (name, ok, detail) => results.push({ name, ok: !!ok, detail: detail === undefined ? '' : JSON.stringify(detail) });

const d = T.normalize({});
check('defaults', d.enabled && d.speed === 1 && d.step === 0.1 && d.keys.faster === 'KeyD', d);
check('speed is clamped', T.normalize({ speed: 99 }).speed === 16 && T.normalize({ speed: -3 }).speed === 0.1);
const partial = T.normalize({ keys: { slower: '' } });
check('a cleared key stays cleared, missing keys get defaults', partial.keys.slower === '' && partial.keys.faster === 'KeyD', partial.keys);
check('bad shapes fall back', T.normalize({ rules: [1], keys: 'x', step: 'abc' }).step === 0.1);

const rules = { 'bilibili.com': 2 };
check('rule matches the host', T.match(rules, 'bilibili.com')[1] === 2);
check('rule matches a subdomain', T.match(rules, 'live.bilibili.com')[0] === 'bilibili.com');
check('rule does not match a lookalike', T.match(rules, 'notbilibili.com') === null);
check('no host, no rule', T.match(rules, '') === null);
check('www is dropped', T.hostKey('WWW.YouTube.com') === 'youtube.com');

const cfg = T.normalize({ speed: 1.5, rules, off: { 'example.com': true } });
check('site rule wins over global', T.state(cfg, 'bilibili.com').speed === 2 && T.state(cfg, 'other.com').speed === 1.5);
check('site off', T.state(cfg, 'a.example.com').off && T.state(cfg, 'a.example.com').siteOff && !T.state(cfg, 'other.com').off);
check('global off', T.state(T.normalize({ enabled: false }), 'other.com').off);

const sitePatch = T.speedPatch(cfg, 'live.bilibili.com', 3);
check('speed on a ruled site edits the rule', sitePatch.rules['bilibili.com'] === 3 && !('speed' in sitePatch) && sitePatch.last === 3, sitePatch);
const globalPatch = T.speedPatch(cfg, 'other.com', 1);
check('speed elsewhere edits the global value, 1x is not remembered as last', globalPatch.speed === 1 && !('last' in globalPatch), globalPatch);

check('target', T.target(cfg, 'other.com', 'faster') === 1.6 && T.target(cfg, 'bilibili.com', 'slower') === 1.9
  && T.target(cfg, 'other.com', 'reset') === 1 && T.target(T.normalize({ last: 2.5 }), '', 'reset') === 2.5);
const ruled = T.rulePatch(cfg, 'other.com', true);
check('rule patch keeps the current speed, and removes the rule that covers a subdomain',
  ruled.rules['other.com'] === 1.5 && ruled.rules['bilibili.com'] === 2 && !('bilibili.com' in T.rulePatch(cfg, 'live.bilibili.com', false).rules), ruled);
check('off patch', T.offPatch(cfg, 'other.com', true).off['other.com'] === true && !('example.com' in T.offPatch(cfg, 'a.example.com', false).off));
const bound = T.bindPatch(d, 'pause', 'KeyS');
check('binding a taken combination frees it', bound.patch.keys.pause === 'KeyS' && bound.patch.keys.reset === '' && bound.freed === 'reset'
  && T.bindPatch(d, 'pause', '').freed === '' && d.keys.reset === 'KeyS', bound);

check('the command channel is off unless it is switched on', d.remote === false && T.normalize({ remote: true }).remote === true && T.normalize({ remote: 'yes' }).remote === false);
check('blocked: the one rule for a key press and the command', T.blocked(cfg, 'other.com', 'forward', false) === 'no_media'
  && T.blocked(cfg, 'a.example.com', 'toggle', true) === 'site_off' && T.blocked(T.normalize({ enabled: false }), 'other.com', 'forward', true) === 'tempo_off'
  && T.blocked(T.normalize({ enabled: false }), 'other.com', 'toggle', true) === '' && T.blocked(cfg, 'other.com', 'forward', true) === '');
const seen = T.pageView(cfg, 'live.bilibili.com', true);
check('page view', seen.host === 'live.bilibili.com' && seen.speed === 2 && seen.rule.host === 'bilibili.com' && !seen.off && seen.has_media === true
  && T.pageView(cfg, 'a.example.com', false).site_off === true, seen);
const playing = { kind: 'video', paused: false, pip: false };
const stopped = { kind: 'video', paused: true, pip: false };
check('outcome: what the player did decides, not what was asked', T.outcome('pause', stopped, { paused: false }, playing) === ''
  && T.outcome('pause', stopped, { paused: false }, stopped) === 'not_allowed'
  && T.outcome('pip', playing, { pip: true }, playing) === 'not_allowed' && T.outcome('pip', playing, { pip: true }, { kind: 'video', pip: true }) === ''
  && T.outcome('pip', { kind: 'audio' }, null, { kind: 'audio' }) === 'not_video' && T.outcome('pip', playing, null, playing) === 'unsupported'
  && T.outcome('jump', playing, { time: null }, playing) === 'no_mark' && T.outcome('forward', null, null, null) === 'no_media'
  && T.outcome('forward', playing, { time: 15 }, playing) === '' && T.outcome('faster', null, undefined, null) === '');

check('combo', T.combo({ code: 'KeyZ', shiftKey: true }) === 'Shift+KeyZ' && T.combo({ code: 'ShiftLeft', shiftKey: true }) === '');
check('label', T.label('Shift+KeyZ') === '⇧Z' && T.label('') === '—' && T.label('Meta+ArrowLeft') === '⌘←');
check('fmt', T.fmt(1.5) === '1.5×' && T.fmt(2) === '2×' && T.fmt(1.2500001) === '1.25×');

return JSON.stringify(results);
