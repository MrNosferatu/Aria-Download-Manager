/* The connection to Aria Download Manager, shared by the background worker and the
   manager page (manager/index.html).

   runtime.connectNative → aria_download_manager/native_host.py → the manager's Unix
   socket. Not network traffic, so a VPN or proxy in the browser cannot route it
   away — and the manager has no network port for anything else to reach.

   Classic script, everything behind one global, because the manager page's
   app.js shares the global scope and already has its own `api`. */
(function () {
  'use strict';

  const ext = globalThis.browser || globalThis.chrome;

  const NATIVE_HOST = 'aria_download_manager';
  const INSTALL_HINT = 'the native host is not installed — run: '
    + 'python3 -m aria_download_manager --install-native-host';
  const NATIVE_IDLE_MS = 20000;
  const RETRY_MS = 3000;

  /* One port per extension context, shared by every request and the event
     stream. Closed again after a quiet spell with nothing subscribed, so the
     host process does not outlive its use and a Chrome service worker is not
     held awake for nothing. */
  const native = {
    port: null, seq: 0, pending: new Map(), part: '', idle: null,
    subs: new Set(), retry: null,
  };

  function nativePort() {
    if (native.port) return native.port;
    const port = ext.runtime.connectNative(NATIVE_HOST);
    port.onMessage.addListener((message) => {
      // Replies over 1 MiB arrive in parts (Chrome's limit for host messages).
      if (message && typeof message.part === 'string') {
        native.part += message.part;
        if (message.more) return;
        try {
          message = JSON.parse(native.part);
        } catch {
          message = null;
        }
        native.part = '';
      }
      if (!message) return;
      if (message.event !== undefined) {
        nativeFrame(message.event, message.data);
        return;
      }
      const settle = native.pending.get(message.id);
      if (!settle) return;
      native.pending.delete(message.id);
      settle(message);
      nativeIdleCheck();
    });
    port.onDisconnect.addListener((p) => {
      // Firefox reports why on the port, Chrome through runtime.lastError.
      const cause = (p && p.error && p.error.message)
        || (ext.runtime.lastError && ext.runtime.lastError.message) || '';
      const reason = /not found|no such native|not allowed|forbidden/i.test(cause)
        ? INSTALL_HINT
        : `native host exited${cause ? `: ${cause}` : ''}`;
      if (native.port === port) native.port = null;
      native.part = '';
      for (const [id, settle] of native.pending) settle({ id, status: 0, body: { error: reason } });
      native.pending.clear();
      nativeStreamLost(reason);
    });
    native.port = port;
    return port;
  }

  function nativeFrame(kind, data) {
    // The host saw the manager's socket close (a restart, usually). The stream
    // has to be asked for again once there is a manager to ask.
    if (kind === 'disconnected') {
      nativeStreamLost('Aria Download Manager closed the connection');
      return;
    }
    for (const sub of native.subs) sub.onFrame(kind, data);
  }

  function nativeStreamLost(reason) {
    if (!native.subs.size) return;
    for (const sub of native.subs) sub.onError(reason);
    clearTimeout(native.retry);
    native.retry = setTimeout(nativeStartStream, RETRY_MS);
  }

  function nativeStartStream() {
    clearTimeout(native.retry);
    if (!native.subs.size) return;
    nativeSend('SUBSCRIBE', '', undefined, 15000).then((reply) => {
      if (reply.status !== 200) nativeStreamLost(errorText(reply));
    });
  }

  function nativeIdleCheck() {
    clearTimeout(native.idle);
    if (native.pending.size || native.subs.size) return;
    native.idle = setTimeout(() => {
      if (native.pending.size || native.subs.size || !native.port) return;
      native.port.disconnect();
      native.port = null;
    }, NATIVE_IDLE_MS);
  }

  function nativeSend(method, path, body, timeout) {
    return new Promise((resolve) => {
      const id = ++native.seq;
      const timer = setTimeout(() => {
        native.pending.delete(id);
        resolve({ id, status: 0, body: { error: 'request timed out' } });
      }, timeout);
      native.pending.set(id, (reply) => {
        clearTimeout(timer);
        resolve(reply);
      });
      clearTimeout(native.idle);
      try {
        nativePort().postMessage({ id, method, path, body });
      } catch (err) {
        native.pending.delete(id);
        clearTimeout(timer);
        resolve({ id, status: 0, body: { error: `${INSTALL_HINT} (${err.message})` } });
      }
    });
  }

  function nativeSubscribe(sub) {
    native.subs.add(sub);
    nativeStartStream();
    return () => {
      native.subs.delete(sub);
      if (native.subs.size) return;
      clearTimeout(native.retry);
      if (native.port) nativeSend('UNSUBSCRIBE', '', undefined, 5000);
      nativeIdleCheck();
    };
  }

  /* ------------------------------------------------------------- interface */
  function errorText(reply) {
    const body = reply.body;
    const detail = body && typeof body === 'object' && (body.error || body.detail);
    if (typeof detail === 'string') return detail;
    return reply.status ? `HTTP ${reply.status}` : 'Aria Download Manager is not reachable';
  }

  //: One request. Resolves to {status, body}; never rejects — status 0 means
  //: the manager was not reached at all, and body.error says why.
  function call(method, path, body, options = {}) {
    return nativeSend(method, path, body, options.timeout || 60000);
  }

  //: Live frames: sub.onFrame(kind, data) for state/event/backlog/shutdown,
  //: sub.onError(reason) when the stream drops (it comes back by itself).
  //: Returns a function that ends the subscription.
  function subscribe(sub) {
    return nativeSubscribe(sub);
  }

  globalThis.ManagerLink = { call, subscribe, errorText };
})();
