# App Studio: ad-hoc applets — design

**Date:** 2026-07-09
**Status:** approved direction, spec for implementation planning

## Problem

Developing means bouncing between dozens of SaaS tools — each with its own
interface, login, and context switch. Dreamux should let the user *commission*
small bespoke dev tools ("applets") in-place: describe what you need, a Claude
agent builds it, it lands in the project sidebar, and it runs inside the app
with real dev-machine power. Examples that must be expressible: a kanban
board, a component kitchen-sink, an Expo-deployments tracker, and (later,
capability-gated) an e2e visual tester. Long-term this grows into a
marketplace of shareable stub applets; that marketplace is **out of scope
here** but the applet format must be marketplace-ready by construction.

## Concepts

- **Applet** — a self-contained folder: `manifest.json` + `index.html` +
  assets. Buildless static web content rendered in a locked-down WKWebView
  with a `window.dreamux` native bridge. The folder is the artifact: cheap
  for an agent to write, instant to run, shareable by copying.
- **App Studio** — the global applet library, reachable from the outer rail.
  Canonical applets live here.
- **Adoption** — a project takes a copy of a library applet. The copy lands
  in the project, records its lineage (`origin`), and is tailored freely by
  that project's builder agent without touching the canon. Chosen over
  linked references deliberately: the builder agent edits files, and editing
  a shared copy from inside one project would silently mutate every other
  project using it; the marketplace vision is copy-and-tailor stubs, not
  live-linked packages. Cost accepted: library fixes reach adoptions only
  via the deferred sync feature.
- **Local-born applet** — created directly in a project, no `origin`. Can be
  published to App Studio later (copy up; the project copy then gains an
  `origin` pointing at the new library entry).

## On-disk model

- **Library:** `~/Documents/Dreamux/Apps/<slug>/`, overridable via
  `$DREAMUX_APPS_ROOT`. Managed by `AppLibraryStore`, which mirrors
  `ProjectStore`: the folder is the source of truth; `refresh()` reconciles
  the in-memory list against the directory listing, preserving identity
  across renames; a filesystem watcher keeps it live.
- **Project applets:** `<project>/apps/<slug>/` — a visible sibling of
  `docs/` and `repos/`, not hidden in `.dreamux/`. Discovered by scan, same
  pattern as repos/features.
- **Applet data:** `<project>/.dreamux/appdata/<slug>/` holding `kv.json`
  and `files/`. Per-project by construction — the same applet adopted into
  two projects has two independent stores. App Studio previews use a scratch
  data dir under Application Support.
- **Manifest** (`manifest.json`):

  ```json
  {
    "id": "<uuid>",
    "name": "Expo Status",
    "slug": "expo-status",
    "icon": "shippingbox",
    "description": "Tracks EAS deployments across this project's apps.",
    "requiresCapabilities": ["shell", "http"],
    "origin": {
      "id": "<library applet uuid>",
      "hash": "<content hash at adopt time>",
      "adoptedAt": "2026-07-09T12:00:00Z"
    }
  }
  ```

  `icon` is an SF Symbol name. `origin` is present only on adoptions; its
  `hash` — SHA-256 over the applet's files (sorted relative path + content,
  data dir excluded) — is what makes later sync (diff against upstream)
  possible. Slugs are unique within their container (library or project);
  collisions on adopt/publish resolve by suffixing (`-2`, `-3`, …).
  `requiresCapabilities` values in v1: `kv`, `fs`, `http`, `shell`,
  `notify` (`context` is always available). Unknown values are tolerated on
  load and reported as "needs a newer Dreamux" — this is how deferred
  entitled capabilities (e.g. `screen-capture`, `input`) gate cleanly later.

## Runtime

- **Serving:** a `WKURLSchemeHandler` (cloned from `MonacoSchemeHandler`)
  maps `dreamux-applet://<applet-id>/<path>` onto the applet folder. A
  custom scheme (not `file://`) avoids cross-origin restrictions. The
  handler canonicalizes paths and rejects any resolution escaping the applet
  folder (path-traversal guard — tested).
- **WebView:** one locked-down `WKWebView` per open applet. A
  `WKNavigationDelegate` permits only the applet scheme; external links are
  handed to the regular browser tab / `NSWorkspace`. `isInspectable = true`
  for debugging. This is *not* the plain `WebTabSession` browser — that
  surface is unrestricted by design and wrong for hosting applets.
- **Bridge:** `window.dreamux`, a promise-based JS shim (vendored
  `dreamux.js`) over a `WKScriptMessageHandler` named `"dreamux"` — the
  Monaco `"bridge"` pattern upgraded to request/response: JS posts
  `{id, method, params}`, native replies via
  `evaluateJavaScript("window.__dreamuxReply(id, resultJSON)")` using the
  existing safe JS-string encoding. v1 API:

  | Method | Behavior |
  |---|---|
  | `context()` | project name, project root, applet data dir |
  | `kv.get/set/delete/list` | the applet's `kv.json` |
  | `fs.read/write/list/delete` | scoped to the applet's `files/` dir (traversal-guarded) |
  | `http.fetch(url, opts)` | native URLSession; deliberately CORS-free |
  | `shell.exec(cmd, {cwd?, timeout?})` | login shell → `{stdout, stderr, code}`; cwd defaults to project root; default timeout 60s; stdout/stderr capped |
  | `notify(title, body)` | app notification |

- **Capability enforcement:** the bridge checks the manifest's
  `requiresCapabilities` before dispatching; an undeclared call rejects with
  an error naming the missing manifest entry. Framing is honest: this is a
  consent seam and robustness boundary, **not** a security sandbox — v1
  applets are code the user commissioned. When the marketplace arrives,
  this same manifest field becomes the install-time consent prompt.
- **Capability layers (architecture):** `shell`/`http`/`fs` are general
  primitives baked into Dreamux — everything composable from CLIs and APIs
  (eas, gh, docker, osascript, …) needs no Dreamux change, which is what
  makes applet capability effectively per-user. Entitled OS powers (screen
  capture via ScreenCaptureKit, input record/replay via CGEventTap — the
  e2e visual tester's heavy tiers) require native modules + TCC permission
  prompts and therefore ship as deliberate Dreamux releases, gated by new
  `requiresCapabilities` values. Note: TCC grants key on code signature, so
  entitled capabilities effectively also depend on the Developer-ID signing
  roadmap (see the update/distribution note).
- **Hot reload:** a filesystem watcher on the applet folder debounces into
  `webView.reload()`. This is what makes the build loop live.

## Authoring stack

Buildless. The scaffold a new applet starts from contains:

- `manifest.json`, `index.html`
- vendored `preact.mjs` + `htm.mjs` (~13KB, React-feel without JSX/build)
- vendored `dreamux.js` (the bridge shim)
- `APPLET.md` — the applet-format + bridge reference the builder agent is
  primed with (doubles as marketplace stub documentation later)

No npm, no bundler, no dev server, no `RunnerManager` involvement. A real
React/Vite applet type can be added later as an opt-in without disturbing
this design.

## UI

### Sidebar (project window)

- New top-level **APPS** section above Workspaces — inserted between the
  pinned tiles and `PlansSpecsSection` in `WorkspaceSidebar.content`; a new
  `appsExpanded` flag joins `SidebarLayoutStore` and its payload.
- House style: 13pt semibold header with kern, 15pt rows, per-applet SF
  Symbol in a fixed-width glyph frame, shared hover wash
  (`primary.opacity(0.04)` hover / `0.08` selected, radius 8), **"+ New
  app" as a borderless foot row** (plain `plus`, 15pt label) — no header
  icons, no dividers.
- Adopted applets show a subtle adopted mark on the row; lineage detail
  lives in the host view header, not the rail.
- Row context menu: Remove from project (confirm; deletes `apps/<slug>/`
  **and** `.dreamux/appdata/<slug>/`, and says so), Publish to App Studio
  (local-born only), Reveal in Finder.

### Navigation

- `SidebarMode` gains `.app(id)`; `ContentView.mainPane` gains the matching
  branch. Selecting an applet swaps the main pane exactly like switching
  workspaces — applets are first-class project content, not a separate
  destination.
- **App Studio** hangs off the outer rail as a v1-minimal library surface:
  list of canonical applets (icon, name, description), open/preview, create
  new, delete. Opening a library applet uses the same `AppletHostView` —
  including the Edit/builder-agent loop — operating on the library folder
  with scratch data. Adoption *into* a project happens from the project
  sidebar's "+ New app" flow, where the target project is unambiguous.

### Host view & build loop

- `AppletHostView`: slim header (icon, name, "Adopted from App Studio"
  note when `origin` present, Edit / Reload / Reveal buttons) over the
  full-bleed preview WebView.
- **Edit** splits the pane: preview beside a **builder agent** — a Claude
  session in a plain terminal cwd'd in the applet folder, spawned and
  prompted via the existing `PTYShellSession` + `ClaudePromptDriver`
  machinery, primed with `APPLET.md` and the user's description. Hot reload
  keeps the preview current on every file the agent writes, so the applet
  visibly assembles itself; feedback and course-correction are just typing
  in the agent pane, exactly like a run. Closing Edit hides the agent pane
  and the applet becomes a tool.
- **"+ New app" sheet:** two paths — *Adopt from App Studio* (picker over
  the library) or *Create new* (name + description → scaffold written
  natively so the preview renders immediately → builder agent starts on the
  description).

## Error handling

- Bridge rejections are structured; the undeclared-capability error names
  the manifest key to add.
- `shell.exec`: 60s default timeout (overridable per call), output caps.
- Applet JS errors: injected `window.onerror`/`onunhandledrejection`
  forward to the app's signal log; the host header shows an error badge;
  Reload recovers.
- Invalid or missing manifest: the sidebar row renders a warning state and
  the host view explains, rather than crashing the section.
- Scheme handler and `fs.*` reject escaped paths outright.

## Testing

- **Unit:** manifest decode (with unknown capabilities tolerated),
  `AppLibraryStore`/project-applet `refresh()` reconciliation, capability
  gating, kv store ops, scheme-handler path resolution incl. traversal
  attempts, `fs.*` scoping, bridge request/response dispatch.
- **E2E (existing driver):** create an applet → row appears in the APPS
  section → open → a fixture applet performs a `kv` round-trip through the
  real bridge and renders the result → screenshot. Adopt-from-library and
  remove flows exercised the same way.

## Deferred (designed-for, not built)

Each item names the seam that makes it buildable later without rework:

1. **Marketplace** — the applet folder is already the shareable unit;
   `requiresCapabilities` becomes the install consent prompt.
2. **Sync (pull library updates into an adoption / push improvements up)**
   — enabled by `origin.id` + `origin.hash` recorded at adopt time.
3. **`spawn` sidecars** (applet-owned backend processes) — add as a new
   bridge method + capability; `shell.exec` covers v1 needs.
4. **Entitled capabilities** for the e2e visual tester — ScreenCaptureKit
   capture, CGEventTap record, CGEvent replay; new `requiresCapabilities`
   values (`screen-capture`, `input`) gate them; requires TCC prompts and
   stable code signing.
5. **Applets as workspace tabs** ("kanban beside my code") — the
   `AppletTabSession` five-edit pattern in `WorkspaceSession` is the seam.
6. **React/Vite applet type** (build toolchain, dev server) — an opt-in
   applet kind; port/preview machinery exists in `RunnerManager`.
7. **User-registered named capabilities** (a capability backed by a
   user-authored sidecar script) — would make even custom Layer-1
   capability formally per-user.

## Key integration seams (from codebase exploration)

- Sidebar insertion: `WorkspaceSidebar.content` between pinned tiles and
  `PlansSpecsSection`; `SidebarLayoutStore` payload.
- Mode: `SidebarMode` + `ContentView.mainPane` switch.
- Scheme handler template: `MonacoSchemeHandler`.
- Bridge template: `FileEditorTabSession`'s `"bridge"`
  `WKScriptMessageHandler` + its `jsString` encoder.
- Store template: `ProjectStore` (dual default/`$ENV` root, folder as
  source of truth, reconciling `refresh()`).
- Agent loop: `PTYShellSession`, `ClaudePromptDriver`, the
  agent-plus-live-preview split pattern from plan runs.
