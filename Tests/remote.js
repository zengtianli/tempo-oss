// The background page's side of the `tempo` command (Extension/Resources/background.js), run as an async
// function body in a world where Tests/bgshim.js stands in for the extension API.
const B = globalThis.__bg;
const results = [];
const check = (name, ok, detail) => results.push({ name: 'background: ' + name, ok: !!ok, detail: detail === undefined ? '' : JSON.stringify(detail) });
const tick = (ms = 30) => new Promise((r) => setTimeout(r, ms));
const last = () => B.native[B.native.length - 1];
// The app extension answering the parked message with a request from the command line.
const request = async (id, action) => { last().resolve({ t: 'cmd', id, action }); await tick(); return last().message.done; };

check('nothing is parked while no frame is listening', B.native.length === 0);
B.connect('something-else');
await tick();
check('a port with another name parks nothing', B.native.length === 0);
const one = B.connect();
await tick();
check('a media port parks one native message with the app extension', B.native.length === 1 && last().message.t === 'next'
  && !last().message.done && last().app === 'cyou.tianli.tempo', B.native.map((n) => n.message));
const two = B.connect();
await tick();
check('a second frame does not park a second one', B.native.length === 1);

last().resolve({ t: 'idle' });
await tick();
check('an empty answer touches the open ports and parks the next message', one.posted.length === 1 && two.posted.length === 1
  && B.native.length === 2 && last().message.t === 'next', B.native.map((n) => n.message));

B.frames = (tabId, m, o) => (o && o.frameId === 0 ? { page: { host: 'example.com' }, media: { paused: true } } : undefined);
let done = await request('A1', 'page');
let asked = B.asked[B.asked.length - 1];
check('a request goes to the top frame of the active tab', asked.tabId === 7 && asked.message.t === 'remote' && asked.message.action === 'page'
  && !asked.message.frame && asked.options.frameId === 0, asked);
check('its answer rides on the next parked message', B.native.length === 3 && last().message.t === 'next' && done.id === 'A1'
  && done.reply.page.host === 'example.com' && done.reply.media.paused === true, last().message);

B.frames = (tabId, m, o) => (o && o.frameId === 0 ? { relay: true, page: { host: 'example.com' } }
  : m.frame ? { action: m.action, result: { time: 15 }, media: { time: 15 }, page: { host: 'player.example.net' } } : undefined);
done = await request('A2', 'forward');
asked = B.asked[B.asked.length - 1];
check('media in another frame: every frame is asked, and the page line stays the top frame\'s', asked.message.frame === true && asked.options === undefined
  && done.id === 'A2' && done.reply.result.time === 15 && done.reply.page.host === 'example.com', done);

B.frames = (tabId, m, o) => (o && o.frameId === 0 ? { relay: true, page: { host: 'example.com' } } : undefined);
done = await request('A3', 'forward');
check('no frame with media answers: no_media', done.reply.error === 'no_media' && done.reply.page.host === 'example.com', done);
B.frames = () => undefined;
done = await request('A4', 'page');
check('a tab without the content script: no_page', done.reply.error === 'no_page', done);
B.active = null;
done = await request('A5', 'page');
check('no window: no_tab', done.reply.error === 'no_tab', done);
B.active = { id: 7 };

const before = B.asked.length;
done = await request('A6', 'reread');
const told = B.asked.slice(before);
check('reread goes to every tab', done.reply.reread === 2 && told.length === 2 && told.every((a) => a.message.t === 'reread')
  && told.map((a) => a.tabId).join() === '7,8', told);

// A frame connects while a request is still with the page: the new message is parked at once, and the
// answer still goes out, on its own.
let release;
B.frames = (tabId, m, o) => (o && o.frameId === 0 ? new Promise((r) => { release = () => r({ page: { host: 'slow.example' } }); }) : undefined);
last().resolve({ t: 'cmd', id: 'A7', action: 'page' });
await tick();
const count = B.native.length;
const three = B.connect();
await tick();
check('a frame that connects meanwhile gets a message parked', B.native.length === count + 1 && last().message.t === 'next' && !last().message.done);
release();
await tick();
check('and the answer still goes out', B.native.length === count + 2 && last().message.t === 'done' && last().message.done.id === 'A7'
  && last().message.done.reply.page.host === 'slow.example', last().message);

// The app extension (or Safari) refusing straight away must not turn into a loop.
const parked = B.native[count];
parked.reject(new Error('refused'));
await tick();
check('a refusal that comes straight back is not asked again', B.native.length === count + 2);
const four = B.connect();
await tick();
check('until a frame connects', B.native.length === count + 3 && last().message.t === 'next');

const waiting = last();
for (const port of [one, two, three, four]) port.close();
await tick();
check('when the last frame lets go, the app extension is told to release the parked message', last().message.t === 'bye', last().message);
waiting.resolve({ t: 'idle' });
await tick();
check('and nothing is parked afterwards', last().message.t === 'bye' && B.native.length === count + 4);

return JSON.stringify(results);
