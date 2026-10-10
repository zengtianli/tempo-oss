// Behaviour checks, run as an async function body in the page world of Tests/page.html.
// `pageEngine` is false when the harness leaves the page-world engine out on purpose: ordinary media must
// still work through the standby copy, and the three `needsPageEngine` checks must then fail.
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const results = (window.__tempoResults = []);
const check = (name, ok, detail, needsPageEngine) =>
  results.push({ name, ok: !!ok, detail: detail === undefined ? '' : String(detail), needsPageEngine: !!needsPageEngine });
const near = (a, b, eps = 1e-3) => Math.abs(a - b) < eps;
const key = (code, opts = {}, target = document.body) => {
  const init = Object.assign({ code, bubbles: true, cancelable: true, composed: true }, opts);
  const down = new KeyboardEvent('keydown', init);
  target.dispatchEvent(down);
  target.dispatchEvent(new KeyboardEvent('keyup', init));
  return down;
};
const setStore = (patch) => document.dispatchEvent(new CustomEvent('tempo-test:set', { detail: JSON.stringify(patch) }));
const query = () => {
  let state = null;
  document.addEventListener('tempo-test:state', (e) => { state = JSON.parse(e.detail); }, { once: true });
  document.dispatchEvent(new CustomEvent('tempo-test:query'));
  return state;
};

// A message from the background page to the content script (tabs.sendMessage), and its reply.
let asked = 0;
const tell = (message, wait = 1500) => new Promise((resolve) => {
  const id = ++asked;
  const onReply = (e) => {
    const d = JSON.parse(e.detail);
    if (d.id !== id) return;
    document.removeEventListener('tempo-test:reply', onReply);
    resolve(d.reply);
  };
  document.addEventListener('tempo-test:reply', onReply);
  document.dispatchEvent(new CustomEvent('tempo-test:message', { detail: JSON.stringify({ id, message }) }));
  setTimeout(() => resolve('no reply'), wait);
});
const act = (action) => tell({ t: 'remote', action });

const v = document.getElementById('v');
const { sv, hidden } = window.fixture;

// A view that is never shown does not load media in WebKit, so nothing here depends on decoding: rate,
// keys, discovery and seek arithmetic are checked on the elements themselves.
await sleep(500);

let e = key('KeyD');
check('D speeds up and is swallowed', near(v.playbackRate, 1.1) && e.defaultPrevented, v.playbackRate);
for (let i = 0; i < 4; i++) key('KeyD');
check('repeated D accumulates', near(v.playbackRate, 1.5), v.playbackRate);
key('KeyA');
check('A slows down', near(v.playbackRate, 1.4), v.playbackRate);
check('video in a closed shadow root follows', near(sv.playbackRate, 1.4), sv.playbackRate, true);
key('KeyS');
check('S goes to 1x', near(v.playbackRate, 1), v.playbackRate);
key('KeyS');
check('S returns to the last speed', near(v.playbackRate, 1.4), v.playbackRate);
check('speed is stored', near(query().store.speed, 1.4), JSON.stringify(query().store));

v.playbackRate = 1;
await sleep(200);
check('a reset by the page is undone', near(v.playbackRate, 1.4), v.playbackRate);

const audio = new Audio('fixtures/silence.wav');
audio.muted = true;
await Promise.race([audio.play().catch(() => {}), sleep(1500)]);
await sleep(100);
check('Audio that never enters the DOM follows', near(audio.playbackRate, 1.4), audio.playbackRate, true);
audio.pause();

const text = document.getElementById('text');
text.focus();
e = key('KeyD', {}, text);
check('typing in a text field is left alone', near(v.playbackRate, 1.4) && !e.defaultPrevented, v.playbackRate);
text.blur();
hidden.focus();
e = key('KeyD', {}, document.getElementById('inputHost'));
check('typing inside a closed shadow root is left alone', near(v.playbackRate, 1.4) && !e.defaultPrevented, v.playbackRate, true);
hidden.blur();

v.currentTime = 5;
await sleep(150);
key('KeyX');
check('X seeks forward 10 s', near(v.currentTime, 15, 0.05), v.currentTime);
key('KeyZ');
check('Z seeks back 10 s', near(v.currentTime, 5, 0.05), v.currentTime);
key('KeyX', { shiftKey: true });
check('Shift+X steps one frame and pauses', near(v.currentTime, 5 + 1 / 30, 0.01) && v.paused, v.currentTime);
key('KeyW', { shiftKey: true });
v.currentTime = 20;
key('KeyW');
check('W returns to the remembered position', near(v.currentTime, 5 + 1 / 30, 0.01), v.currentTime);
check('the indicator is on the page', !!document.querySelector('html > div[popover]'));

await sleep(450);
setStore({ enabled: false });
await sleep(50);
check('switching off restores 1x', near(v.playbackRate, 1), v.playbackRate);
e = key('KeyD');
check('keys pass through while off', near(v.playbackRate, 1) && !e.defaultPrevented, v.playbackRate);
setStore({ enabled: true, speed: 2 });
await sleep(50);
check('a change from the popup applies', near(v.playbackRate, 2), v.playbackRate);

// The `tempo` command writes the store from outside Safari, which raises no change event.
document.dispatchEvent(new CustomEvent('tempo-test:set-silently', { detail: JSON.stringify({ speed: 3 }) }));
await sleep(100);
check('a write from outside Safari waits for the page to come back', near(v.playbackRate, 2), v.playbackRate);
window.dispatchEvent(new Event('focus'));
await sleep(100);
check('the page reads the settings again when it gets the focus', near(v.playbackRate, 3), v.playbackRate);

// The `tempo` command. Its requests arrive as messages from the background page and go through the same
// run() as the keys above; the reply says what the player really did.
await sleep(450);
check('no port to the background page while the command channel is off', query().ports.length === 0, JSON.stringify(query().ports));
setStore({ remote: true });
await sleep(50);
check('switching the channel on opens one port from the frame that has media', JSON.stringify(query().ports) === '["media"]', JSON.stringify(query().ports));

let r = await act('page');
check('page: the site line and the state of the player', r && r.page && r.page.speed === 3 && r.page.off === false && r.page.has_media === true
  && r.media && r.media.kind === 'video' && near(r.media.time, v.currentTime, 0.01) && near(r.media.rate, 3) && r.media.paused === v.paused
  && r.media.muted === true && near(r.media.mark, 5 + 1 / 30, 0.01), JSON.stringify(r));

v.currentTime = 5;
await sleep(150);
r = await act('forward');
check('do forward: the same seek as X, and the reply carries the new time', near(v.currentTime, 15, 0.05) && r.action === 'forward'
  && near(r.result.time, 15, 0.05) && near(r.media.time, 15, 0.05) && near(r.before.time, 5, 0.05) && !r.error, JSON.stringify(r));
r = await act('rewind');
check('do rewind', near(v.currentTime, 5, 0.05) && near(r.result.time, 5, 0.05) && !r.error, JSON.stringify(r));
r = await act('frameNext');
check('do frameNext', near(v.currentTime, 5 + 1 / 30, 0.01) && v.paused && r.media.paused === true && !r.error, JSON.stringify(r));
r = await act('mark');
v.currentTime = 20;
await sleep(150);
r = await act('jump');
check('do mark, then do jump returns there', near(v.currentTime, 5 + 1 / 30, 0.01) && near(r.result.time, 5 + 1 / 30, 0.01) && !r.error, JSON.stringify(r));
r = await act('mute');
check('do mute: the reply says what the player says', v.muted === false && r.before.muted === true && r.result.muted === false && r.media.muted === false && !r.error, JSON.stringify(r));
await act('mute');
check('do mute again puts it back', v.muted === true);

r = await act('pause');
check('do pause: started, or refused and said so', r.error ? r.error === 'not_allowed' && v.paused : r.media.paused === false && !v.paused, JSON.stringify(r));
if (!v.paused) {
  r = await act('pause');
  check('do pause again stops it', v.paused && r.result.paused === true && r.media.paused === true && !r.error, JSON.stringify(r));
}
r = await act('pip');
check('do pip without a real key press is reported as not done', (r.error === 'not_allowed' || r.error === 'unsupported') && r.media.pip === false, JSON.stringify(r));

r = await act('faster');
check('do faster: the same step as D, stored and applied', near(r.page.speed, 3.1) && near(v.playbackRate, 3.1) && near(query().store.speed, 3.1) && r.result === null && !r.error, JSON.stringify(r));
r = await act('fly');
check('an action nobody knows is refused', r.error === 'unknown_action', JSON.stringify(r));
r = await tell({ t: 'remote', action: 'page', frame: true });
check('asked as one of the frames, the frame with the media answers', r && r.media && r.media.kind === 'video', JSON.stringify(r));

await sleep(450);
setStore({ enabled: false });
await sleep(50);
const held = v.currentTime;
r = await act('forward');
check('while Tempo is off an action is refused, as its key is', r.error === 'tempo_off' && near(v.currentTime, held, 0.01), JSON.stringify(r));
r = await act('toggle');
check('do toggle switches Tempo back on', query().store.enabled === true && r.page.off === false && !r.error, JSON.stringify(r));

await sleep(450);
document.dispatchEvent(new CustomEvent('tempo-test:set-silently', { detail: JSON.stringify({ speed: 2.5 }) }));
r = await tell({ t: 'reread' }, 300);
await sleep(100);
check('told to read the settings again, the page applies a write from outside at once', near(v.playbackRate, 2.5) && r === null, v.playbackRate);

setStore({ remote: false });
await sleep(50);
check('switching the channel off closes the port', query().ports.length === 0, JSON.stringify(query().ports));

return JSON.stringify(results);
