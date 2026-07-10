// Dreamux bridge shim — promise API over window.webkit.messageHandlers.dreamux.
// Native replies via window.__dreamuxReply(id, {result} | {error}).
(() => {
  let seq = 0;
  const pending = new Map();
  window.__dreamuxReply = (id, payload) => {
    const p = pending.get(id);
    if (!p) return;
    pending.delete(id);
    if (payload && payload.error) p.reject(new Error(payload.error));
    else p.resolve(payload ? payload.result : undefined);
  };
  const call = (method, params = {}) => new Promise((resolve, reject) => {
    const id = ++seq;
    pending.set(id, { resolve, reject });
    window.webkit.messageHandlers.dreamux.postMessage({ id, method, params });
  });
  window.dreamux = {
    context: () => call('context'),
    kv: {
      get: (key) => call('kv.get', { key }),
      set: (key, value) => call('kv.set', { key, value }),
      delete: (key) => call('kv.delete', { key }),
      list: () => call('kv.list'),
    },
    fs: {
      read: (path) => call('fs.read', { path }),
      write: (path, text) => call('fs.write', { path, text }),
      list: (path) => call('fs.list', { path: path || '' }),
      delete: (path) => call('fs.delete', { path }),
    },
    http: { fetch: (url, opts) => call('http.fetch', { url, ...(opts || {}) }) },
    shell: { exec: (cmd, opts) => call('shell.exec', { cmd, ...(opts || {}) }) },
    notify: (title, body) => call('notify', { title, body }),
    connections: {
      status: (slot) => call('connections.status', { slot }),
      request: (slot) => call('connections.request', { slot }),
    },
  };
})();
