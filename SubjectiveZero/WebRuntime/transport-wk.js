// transport-wk.js: the one file that knows it lives inside WKWebView. Defines window.sz, the only
// door between the page and the app: messages arrive through window.__szDispatch (the app calls it
// with a JSON string), and the page posts back through the "sz" script-message handler. The runtime
// never touches window.webkit, so an exported page or a browser-live transport swaps this file only.
(() => {
  "use strict";
  if (window.sz) { return; }
  const handlers = [];
  window.__szDispatch = (payload) => {
    let msg;
    try { msg = JSON.parse(payload); } catch (e) { console.error("sz: bad push", e); return; }
    for (const fn of handlers) { try { fn(msg); } catch (e) { console.error("sz: handler failed", e); } }
  };
  window.sz = Object.freeze({
    onMessage: (fn) => { handlers.push(fn); },
    post: (msg) => {
      const h = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.sz;
      if (h) { h.postMessage(msg); }
    },
    boot: null,
  });
})();
