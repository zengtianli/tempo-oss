// Stand-in for the extension API as the background page sees it. Tests/remote.js plays Safari: it connects
// and closes ports the way content scripts do, answers the parked native messages the way the app extension
// does, and answers tabs.sendMessage the way the frames of a tab do.
(() => {
  'use strict';
  const B = (globalThis.__bg = {
    native: [],            // every runtime.sendNativeMessage call: { app, message, resolve, reject }
    asked: [],             // every tabs.sendMessage call: { tabId, message, options }
    frames: null,          // (tabId, message, options) => the reply of the frames of that tab
    active: { id: 7 },     // the active tab of the window used last; null = no window
    tabs: [{ id: 7 }, { id: 8 }],
    onConnect: [],
  });

  globalThis.browser = {
    runtime: {
      id: 'tempo-bg-test',
      onMessage: { addListener() {} },
      onConnect: { addListener: (f) => B.onConnect.push(f) },
      sendNativeMessage: (app, message) => new Promise((resolve, reject) => B.native.push({ app, message, resolve, reject })),
    },
    tabs: {
      query: (q) => Promise.resolve(q && q.active ? (B.active ? [B.active] : []) : B.tabs),
      sendMessage: (tabId, message, options) => {
        B.asked.push({ tabId, message, options });
        return Promise.resolve(B.frames ? B.frames(tabId, message, options) : undefined);
      },
      onRemoved: { addListener() {} },
    },
    action: { setBadgeText() {}, setBadgeBackgroundColor() {} },
  };

  // A content script opening a port; close() is that frame going away.
  B.connect = (name = 'media') => {
    const gone = [];
    const port = { name, posted: [], onDisconnect: { addListener: (f) => gone.push(f) }, postMessage: (m) => port.posted.push(m) };
    port.close = () => { for (const f of gone) f(port); };
    for (const f of B.onConnect) f(port);
    return port;
  };
})();
