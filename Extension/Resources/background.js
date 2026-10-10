// Tempo background page: relays between the frames of one tab, keeps the toolbar badge, and, when the
// "remote" setting is on, hands the `tempo` command's requests to the page in the current tab.
// Speed itself never passes through here; frames read and write storage directly, so the core keeps
// working while this page is unloaded.
const api = globalThis.browser || globalThis.chrome;

const mediaFrames = new Map();   // tabId -> Set<frameId>; rebuilt by roll call after this page restarts

function cast(tabId, msg) {
  try {
    const p = api.tabs.sendMessage(tabId, msg);
    if (p && p.catch) p.catch(() => {});
  } catch {}
}

function badge(tabId, text) {
  try {
    api.action.setBadgeText({ tabId, text });
    if (api.action.setBadgeBackgroundColor) api.action.setBadgeBackgroundColor({ tabId, color: '#D9480F' });
  } catch {}
}

api.runtime.onMessage.addListener((m, sender, sendResponse) => {
  const tabId = sender && sender.tab && sender.tab.id;
  if (!m || tabId == null) return;
  const frameId = sender.frameId || 0;
  let frames = mediaFrames.get(tabId);
  const unknown = !frames;
  if (unknown) mediaFrames.set(tabId, (frames = new Set()));

  switch (m.t) {
    case 'hello':
      if (frameId === 0) frames.clear();   // a new top document: earlier frames are gone
      if (unknown) cast(tabId, { t: 'rollcall' });
      sendResponse({ has: frames.size > 0 });
      break;
    case 'media':
      if (m.has) frames.add(frameId);
      else frames.delete(frameId);
      cast(tabId, { t: 'tabmedia', has: frames.size > 0 });
      if (unknown) cast(tabId, { t: 'rollcall' });
      break;
    case 'relay':
      cast(tabId, { t: 'cmd', name: m.name, value: m.value });
      break;
    case 'indicate':
      cast(tabId, { t: 'indicate', text: m.text });
      break;
    case 'badge':
      badge(tabId, m.text || '');
      break;
  }
});

api.tabs.onRemoved.addListener((tabId) => mediaFrames.delete(tabId));

// ---- the `tempo` command -------------------------------------------------------------------------------
//
// The command line cannot call into Safari, and Safari wakes this page only for its own events. So the
// request travels the other way round: while some frame holds a 'media' port open (content.js does when
// "remote" is on and the frame has media), this page keeps one native message parked in the app extension.
// The extension answers it when the command line leaves a request, or after a while with nothing; either
// way the answer comes back here, the open ports are touched (Safari keeps a page with open, recently used
// ports loaded) and the next message is parked. Nothing here runs on a timer, and with no port open nothing
// is parked: the page unloads as before and the app extension has nothing left to wait for.
const APP = 'cyou.tianli.tempo';   // Safari sends native messages to the containing app's extension whatever this says
const links = new Set();
let parked = false;

function native(message) {
  try { return Promise.resolve(api.runtime.sendNativeMessage(APP, message)); } catch (e) { return Promise.reject(e); }
}

function park(done) {
  if (parked || !links.size) {
    // Nothing to park (a message already is, or no frame is listening any more): a reply still goes out.
    if (done) native({ t: 'done', done }).catch(() => {});
    return;
  }
  parked = true;
  const since = Date.now();
  native(done ? { t: 'next', done } : { t: 'next' }).then((m) => {
    parked = false;
    for (const port of links) { try { port.postMessage({ t: 'alive' }); } catch {} }
    if (m && m.t === 'cmd') answer(m).then((reply) => park({ id: m.id, reply }));
    else park();
  }, () => {
    parked = false;
    // A refusal that comes straight back (no permission, no extension process) is not asked again until a
    // frame connects; one that comes after a long wait is Safari giving up on that wait, so park again.
    if (Date.now() - since > 5000) park();
  });
}

function ask(tabId, message, options) {
  try { return Promise.resolve(api.tabs.sendMessage(tabId, message, options)).catch(() => undefined); } catch { return Promise.resolve(undefined); }
}

// One request from the command line. 'reread' goes to every tab; everything else goes to the tab the
// toolbar popup would describe: the active tab of the window used last.
async function answer(cmd) {
  try {
    if (cmd.action === 'reread') {
      const tabs = await api.tabs.query({});
      for (const tab of tabs) cast(tab.id, { t: 'reread' });
      return { reread: tabs.length };
    }
    const [tab] = await api.tabs.query({ active: true, lastFocusedWindow: true });
    if (!tab) return { error: 'no_tab' };
    const top = await ask(tab.id, { t: 'remote', action: cmd.action }, { frameId: 0 });
    if (!top) return { error: 'no_page' };
    if (!top.relay) return top;
    // The media is in another frame of that tab: every frame is asked, the ones with media answer.
    const inner = await ask(tab.id, { t: 'remote', action: cmd.action, frame: true });
    return inner ? Object.assign({}, inner, { page: top.page }) : { error: 'no_media', page: top.page };
  } catch (e) {
    return { error: 'failed', detail: String(e && e.message || e) };
  }
}

api.runtime.onConnect.addListener((port) => {
  if (port.name !== 'media') return;
  links.add(port);
  port.onDisconnect.addListener(() => {
    links.delete(port);
    if (!links.size) native({ t: 'bye' }).catch(() => {});   // lets the parked message go
  });
  park();
});
