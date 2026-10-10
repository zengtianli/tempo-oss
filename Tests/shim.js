// Stand-in for the extension API inside the test harness's isolated world. The page-world test drives it
// with DOM events, which cross worlds the same way they do in Safari.
(() => {
  'use strict';
  const store = {};
  const changeListeners = [];
  const messageListeners = [];
  const sent = [];
  const ports = [];

  function apply(patch) {
    const changes = {};
    for (const k of Object.keys(patch)) {
      changes[k] = { oldValue: store[k], newValue: patch[k] };
      store[k] = JSON.parse(JSON.stringify(patch[k]));
    }
    for (const f of changeListeners) f(changes, 'local');
  }

  globalThis.browser = {
    runtime: {
      id: 'tempo-test',
      sendMessage: (m) => { sent.push(m); return Promise.resolve(m.t === 'hello' ? { has: false } : undefined); },
      onMessage: { addListener: (f) => messageListeners.push(f) },
      connect: (info) => {
        const port = { name: info && info.name, open: true, onDisconnect: { addListener() {} }, onMessage: { addListener() {} },
                       postMessage() {}, disconnect() { port.open = false; } };
        ports.push(port);
        return port;
      },
    },
    tabs: { query: () => Promise.resolve([{ url: 'https://www.bilibili.com/video/demo' }]) },
    storage: {
      local: {
        get: () => Promise.resolve(JSON.parse(JSON.stringify(store))),
        set: (patch) => { apply(patch); return Promise.resolve(); },
        clear: () => { for (const k of Object.keys(store)) delete store[k]; return Promise.resolve(); },
      },
      onChanged: { addListener: (f) => changeListeners.push(f) },
    },
  };

  document.addEventListener('tempo-test:set', (e) => apply(JSON.parse(e.detail)));
  // A write that raises no change event, the way one made from outside Safari (the `tempo` command) arrives.
  document.addEventListener('tempo-test:set-silently', (e) => Object.assign(store, JSON.parse(e.detail)));
  document.addEventListener('tempo-test:query', () => {
    const open = ports.filter((p) => p.open).map((p) => p.name);
    document.dispatchEvent(new CustomEvent('tempo-test:state', { detail: JSON.stringify({ store, sent, ports: open }) }));
  });
  // A message from the background page to this frame's content script, the way tabs.sendMessage delivers
  // it. The reply (or `null` when no listener wants to answer) comes back as tempo-test:reply.
  document.addEventListener('tempo-test:message', (e) => {
    const { id, message } = JSON.parse(e.detail);
    let answered = false;
    const reply = (value) => {
      if (answered) return;
      answered = true;
      document.dispatchEvent(new CustomEvent('tempo-test:reply', { detail: JSON.stringify({ id, reply: value === undefined ? null : value }) }));
    };
    let later = false;
    for (const f of messageListeners) if (f(message, { tab: { id: 1 }, frameId: 0 }, reply) === true) later = true;
    if (!later) reply(null);
  });
})();
