# APPLET.md — Dreamux applet format

This folder is a **Dreamux applet**: a small, buildless web tool that
Dreamux renders in a native WKWebView, plus a `window.dreamux` bridge
into the host app. There is no build step, no bundler, no npm install —
everything here is served to the webview exactly as it sits on disk.

Read this file before making changes. It is the complete reference for
the format and the native bridge.

## What's in this folder

```
manifest.json   — identity, icon, description, declared capabilities
index.html      — the applet's UI (entry point Dreamux loads)
dreamux.js      — the bridge shim (window.dreamux) — don't need to edit
preact.mjs      — vendored Preact 10 (ES module)
htm.mjs         — vendored htm (tagged-template JSX-alternative)
APPLET.md       — this file
files/          — created on demand: the applet's private data directory
                  for dreamux.fs (see below)
```

### manifest.json

```json
{
  "id": "…uuid…",
  "name": "Kanban",
  "slug": "kanban",
  "icon": "rectangle.split.3x1",
  "description": "A small kanban board",
  "requiresCapabilities": ["kv", "fs"],
  "origin": null
}
```

| Field | Meaning |
|---|---|
| `id` | Stable UUID identity for this applet. Don't change it by hand. |
| `name` | Display name. Shown in the sidebar, window title, and used to fill `{{NAME}}` at scaffold time. |
| `slug` | URL/path-safe identifier derived from `name`. |
| `icon` | SF Symbol name shown next to the applet in the sidebar and host header. |
| `description` | One-line summary of what the applet does. |
| `requiresCapabilities` | Array of capability strings the applet calls through the bridge. Must exactly match what the code actually calls — see **Capabilities** below. |
| `origin` | `null` for an applet built from scratch; set automatically when an applet is adopted from the shared library (records where it was adopted from and a content hash). Don't hand-edit. |

## Capabilities

The bridge only allows a method if its capability is declared in
`manifest.json`'s `requiresCapabilities`. Valid values:

| Capability | Unlocks |
|---|---|
| `kv` | `dreamux.kv.*` — small persistent key/value store |
| `fs` | `dreamux.fs.*` — the applet's private `files/` directory |
| `http` | `dreamux.http.fetch` — outbound HTTP, no CORS |
| `shell` | `dreamux.shell.exec` — run a shell command |
| `notify` | `dreamux.notify` — native notification |

`dreamux.context()` needs no capability — it's always allowed.

Calling a method whose capability isn't declared rejects the returned
promise with an error message naming the manifest fix, e.g.:

```
Error: "kv" capability not declared — add "kv" to requiresCapabilities in manifest.json
```

**Rule: declare every capability you call, and only those.** Before
shipping, grep your code for `dreamux.` and make sure
`requiresCapabilities` lists exactly the capabilities used — no more,
no less.

## The `window.dreamux` bridge

`dreamux.js` is loaded by `index.html` before your module script and
installs `window.dreamux`. Every method returns a `Promise`; on failure
the promise **rejects** with an `Error` (never throws synchronously,
never resolves with an error payload). Always `await`/`.catch()` calls
that touch the outside world.

### `dreamux.context()`

No capability required.

```js
const ctx = await dreamux.context();
// { projectName: string, projectRoot: string, dataDir: string }
```

Returns identifying info about the Dreamux project the applet is
running inside:

| Field | Meaning |
|---|---|
| `projectName` | The project's display name. |
| `projectRoot` | Absolute path to the project's root directory on disk. |
| `dataDir` | Absolute path to this applet's private data directory (the same directory `dreamux.fs` reads/writes into as `files/`). |

### `dreamux.kv` — key/value store (capability: `kv`)

A small persistent JSON store, private to this applet.

```js
await dreamux.kv.set('lastOpened', { at: Date.now() });   // → undefined
const value = await dreamux.kv.get('lastOpened');          // → the stored value, or null if absent
await dreamux.kv.delete('lastOpened');                     // → undefined
const keys = await dreamux.kv.list();                       // → string[] of all keys currently set
```

| Method | Params | Returns |
|---|---|---|
| `kv.get(key)` | `key: string` | the stored value (any JSON-serializable type), or `null` if not set |
| `kv.set(key, value)` | `key: string`, `value: any` (JSON-serializable) | `undefined` on success |
| `kv.delete(key)` | `key: string` | `undefined` on success (no error if the key didn't exist) |
| `kv.list()` | — | `string[]` of all keys currently in the store |

Use `kv` for small structured state (settings, board contents, counters).
For larger blobs or file-shaped data, use `fs` instead.

### `dreamux.fs` — private file storage (capability: `fs`)

Read/write files inside this applet's private `files/` directory. Paths
are relative to that directory — you can't escape it, and you never see
an absolute path.

```js
await dreamux.fs.write('notes/todo.txt', 'buy milk\n');   // → undefined
const text = await dreamux.fs.read('notes/todo.txt');      // → string contents
const entries = await dreamux.fs.list('notes');             // → string[] of names in that subdirectory
await dreamux.fs.delete('notes/todo.txt');                  // → undefined
```

| Method | Params | Returns |
|---|---|---|
| `fs.read(path)` | `path: string` | file contents as a UTF-8 `string` |
| `fs.write(path, text)` | `path: string`, `text: string` | `undefined` on success; creates parent directories as needed |
| `fs.list(path)` | `path?: string` (defaults to the root of `files/`) | `string[]` of entry names directly inside `path` |
| `fs.delete(path)` | `path: string` | `undefined` on success |

Reading a missing file, or any path that would resolve outside the
applet's `files/` directory, rejects the promise.

### `dreamux.http.fetch` — outbound HTTP (capability: `http`)

A native fetch that runs outside the webview, so it isn't subject to
CORS. Prefer this over the browser's built-in `fetch` for talking to
external services.

```js
const res = await dreamux.http.fetch('https://api.example.com/things', {
  method: 'POST',                        // default 'GET'
  headers: { 'content-type': 'application/json' },
  body: JSON.stringify({ q: 'hi' }),
});
// { status: number, headers: Record<string, string>, text: string }
```

| Param | Meaning |
|---|---|
| `url` | absolute URL (required) |
| `opts.method` | HTTP method, default `'GET'` |
| `opts.headers` | request headers object |
| `opts.body` | request body (string) |

Resolves with `{ status, headers, text }` — `text` is the raw response
body (`JSON.parse` it yourself for JSON APIs). Network failures reject
the promise; non-2xx responses still *resolve* (check `status`
yourself).

### `dreamux.shell.exec` — run a shell command (capability: `shell`)

```js
const res = await dreamux.shell.exec('ls -la', {
  cwd: undefined,     // default: the project root
  timeout: undefined, // default: 60 seconds
});
// { stdout: string, stderr: string, code: number }
```

| Param | Meaning |
|---|---|
| `cmd` | shell command string (required) |
| `opts.cwd` | working directory; defaults to the project's root |
| `opts.timeout` | seconds before the process is killed; default 60 |

Resolves with `{ stdout, stderr, code }` even for a non-zero exit code
— check `code` yourself. A timed-out or unstartable process rejects the
promise.

### `dreamux.notify(title, body)` — native notification (capability: `notify`)

```js
await dreamux.notify('Build finished', 'All tasks passed.');  // → undefined
```

| Param | Meaning |
|---|---|
| `title` | notification title (required) |
| `body` | notification body text |

## UI: vendored Preact + htm

There's no JSX/build step, so UI is written with
[Preact](https://preactjs.com) (a small `h`/`render` implementation)
plus [htm](https://github.com/developit/htm) (tagged-template literals
that give you JSX-like syntax with plain `.mjs` — no compiler needed):

```js
import { h, render } from './preact.mjs';
import htm from './htm.mjs';
const html = htm.bind(h);

function App() {
  return html`<main>
    <h1>Hello</h1>
  </main>`;
}
render(html`<${App} />`, document.getElementById('app'));
```

Both files are vendored locally in this folder — don't fetch them from
a CDN, and don't add a `package.json`/bundler. Import other ES modules
the same way, by relative path, if you need more code than fits in
`index.html`.

## Hot reload

The preview reloads on save: edit `index.html`, `dreamux.js`, or any
module you add in this folder, save the file, and Dreamux refreshes the
webview automatically. No server restart, no build step.

## Rules

- **Edit only this folder.** The applet's whole world is its own
  directory; don't reach outside it or assume access to the rest of the
  project's source.
- **Declare every capability you call — and only those.** Keep
  `requiresCapabilities` in `manifest.json` in sync with the
  `dreamux.*` calls actually present in your code.
- **Keep it buildless.** Plain ES modules only. No npm install, no
  bundler, no transpilation step — Preact and htm are already vendored
  here for you.
- **Data lives in the bridge, not `localStorage`.** Use `dreamux.kv`
  for structured state and `dreamux.fs` for file-shaped data; the
  webview's `localStorage`/`indexedDB` are not persisted by Dreamux and
  may be cleared at any time.
