# App Studio: Ad-hoc Applets Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the user commission small bespoke dev tools ("applets") — described in a sentence, built by a Claude agent, rendered in a locked-down WKWebView with a `window.dreamux` native bridge — listed in a new APPS sidebar section, adoptable from a global App Studio library.

**Architecture:** An applet is a self-contained folder (`manifest.json` + `index.html` + vendored assets). A global `AppLibraryStore` (`~/Documents/Dreamux/Apps/`) holds canonical applets; a per-project `ProjectAppletStore` (`<project>/apps/`) holds adopted copies (origin-stamped) and local-borns. `AppletSession` owns the preview WKWebView (custom `dreamux-applet://` scheme, cloned from `MonacoSchemeHandler`) plus the promise-based bridge (cloned from `FileEditorTabSession`'s `"bridge"`) and an optional builder-agent terminal (`TabSession` + `ClaudePromptDriver`). Selection is `SidebarMode.app(id)` — the main pane swaps exactly like switching workspaces.

**Tech Stack:** Swift 6 / SwiftPM, SwiftUI, WebKit (WKURLSchemeHandler, WKScriptMessageHandler), CryptoKit, Preact+htm (vendored, buildless), XCTest, e2e harness.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-07-09-app-studio-applets-design.md` (read it first).
- **Buildless, no RunnerManager.** No npm, no dev server, no ports. The folder is the artifact.
- **Capability gating is a consent seam, not a sandbox** — but the *path-traversal guards are real security tests* (scheme handler + `fs.*` must reject escapes).
- Design scale (CLAUDE.md): row labels 15pt, section headers 13pt semibold kern 0.4 uppercase, hover wash `Color.primary.opacity(0.04)` / selected `0.08` on `RoundedRectangle(cornerRadius: 8)`, add-actions as borderless foot rows (plain `plus`, 15pt label), **no dividers under headers**. Header buttons use `.buttonStyle(.soft)` (`SoftButtonStyle.swift`).
- **`OuterRail.swift`/`AppSection.swift` are DEAD CODE** (defined, never mounted). Do NOT wire them. The real outer rail is `ProjectsRail`; App Studio mounts there + its own `Window` scene.
- **WKWebView content is GPU-composited → blank in the in-process e2e screenshot.** Never assert webview pixels; assert bridge side-effects on disk (kv.json).
- Swift 6: stores are `@MainActor @Observable`; pure helpers `nonisolated static` on enums/structs; test them without actors where possible.
- Stage only named files when committing; re-verify HEAD before each commit (parallel sessions may touch main).
- Degrade, never crash: missing/invalid manifest renders a warning row, not a crash.
- Full `swift test` + `swift build` green before every commit.

## Adaptation ground rules

Anchors verified at HEAD (2026-07-09, post-`3382454`). Pure helpers carry complete code + tests; view tasks are anchored sketches, build-gated, verified by e2e (house style — no unit tests for SwiftUI views).

- `Sources/Dreamux/Views/MonacoSchemeHandler.swift` — the WHOLE scheme-handler template (73 lines): `static let scheme`, `init(root:)`, `webView(_:start:)`, pure `relativePath(for:)`/`mimeType(forPathExtension:)`. Tests: `Tests/DreamuxTests/MonacoSchemeHandlerTests.swift`.
- `Sources/Dreamux/Models/FileEditorTabSession.swift:103-113` — lazy `webView` with `config.userContentController.add(Bridge(owner:), name:)`; `:127-132` `jsString(_:)` (safe JS-string encoder — reuse verbatim); `:167-184` the weak-owner `Bridge: NSObject, WKScriptMessageHandler` shape.
- `Sources/Dreamux/Models/ProjectStore.swift:76-94` `projectsRootURL()` (dual default/`$ENV` root); `:138-187` reconciling `refresh()` — the store template. `Models/Project.swift` (`Project.rootPath`).
- `Sources/Dreamux/Models/SidebarLayoutStore.swift` — add `appsExpanded` beside `plansExpanded` (`:14-35`) + `Payload` (`:82-90`) + init default.
- `Sources/Dreamux/Views/ContentView.swift:1069-1075` `enum SidebarMode` (add `case app(UUID)`); `:361-401` `mainPane` switch; `WorkspaceSidebar(...)` call at `:143`.
- `Sources/Dreamux/Views/WorkspaceSidebar.swift:199-279` `content` VStack — insert the Apps section between the tiles VStack (ends `:207`) and `PlansSpecsSection` (`:211`); `:283-309` `addRepositoryRow` foot-row pattern; header pattern `PlansSpecsSection.swift:170-193`; foot row `:199-223`.
- `Sources/Dreamux/Models/WorkspaceSession.swift:257-264` `TabSession(cwd:onActivity:)` construction; `Views/WorkspaceTerminalContainer.swift:117-118` `HostedTerminalView(session:dropTargetEnabled:)` + `.onAppear { tabSession.startIfNeeded() }`.
- `Sources/Dreamux/Shell/ClaudePromptDriver.swift:20-41` `send(_:into:)`.
- `Sources/Dreamux/Models/ProjectSession.swift:19-31` store lets + `:84-121` init — add `applets: ProjectAppletStore` + an `appletSessions` cache here.
- `Sources/Dreamux/Views/ProjectsRail.swift:55-60` New Project foot row (App Studio row mirrors it); `DreamuxApp.swift:41` `WindowGroup("Project", id:"project", for: UUID.self)` / `:62` `Settings` — add a `Window("App Studio", id: "app-studio")` scene beside them.
- `Sources/Dreamux/E2E/E2ECommands.swift:52-120` command dispatch (`case "…"`); `:479-491` `setSidebarMode` mode strings; `Scripts/e2e/driver.py`, `Scripts/e2e/PROTOCOL.md`.
- `Package.swift:43` `resources: [.copy("Resources/Monaco")]` — add `.copy("Resources/AppletScaffold")` to the same array.
- Notifications: check `NotificationManager` for a generic notify; if only `notifyActivity(workspaceName:tabId:tabTitle:message:)` exists, post via `UNUserNotificationCenter` directly in the bridge (small, self-contained).

---

## GROUP 1 — Model & stores (pure, TDD)

### Task 1: Applet manifest, capabilities, content hash, slugs

**Files:**
- Create: `Sources/Dreamux/Models/AppletManifest.swift`
- Test: `Tests/DreamuxTests/AppletManifestTests.swift`

**Interfaces (Produces — later tasks import these exact names):**

```swift
import Foundation
import CryptoKit

/// v1 bridge capabilities. Unknown manifest strings are tolerated on load
/// (a future Dreamux may define them) and surfaced via `unknownCapabilities`.
enum AppletCapability: String, CaseIterable, Sendable {
    case kv, fs, http, shell, notify
}

struct AppletManifest: Codable, Equatable, Sendable {
    var id: UUID
    var name: String
    var slug: String
    /// SF Symbol name for the sidebar row / host header.
    var icon: String
    var description: String
    var requiresCapabilities: [String]
    var origin: Origin?

    struct Origin: Codable, Equatable, Sendable {
        var id: UUID        // library applet id this was adopted from
        var hash: String    // AppletContentHash of the library folder at adopt time
        var adoptedAt: Date
    }

    var grantedCapabilities: Set<AppletCapability> {
        Set(requiresCapabilities.compactMap(AppletCapability.init(rawValue:)))
    }
    var unknownCapabilities: [String] {
        requiresCapabilities.filter { AppletCapability(rawValue: $0) == nil }
    }

    /// Decode `<folder>/manifest.json`; nil when missing/invalid (callers
    /// render a warning state, never crash). ISO-8601 dates.
    static func load(from folderURL: URL) -> AppletManifest?
    /// Write `manifest.json` (pretty, sorted keys, ISO-8601, atomic).
    func write(to folderURL: URL) throws
}

/// One applet on disk: manifest + where it lives. Identity is the manifest id.
struct Applet: Identifiable, Equatable, Sendable {
    let manifest: AppletManifest
    let folderURL: URL
    var id: UUID { manifest.id }
    var slug: String { manifest.slug }
    var isAdopted: Bool { manifest.origin != nil }
}

enum AppletContentHash {
    /// SHA-256 over the folder's regular files: sorted relative path +
    /// "\0" + contents, `.DS_Store` excluded. Deterministic across
    /// enumeration order. Empty/missing folder hashes the empty input.
    static func hash(of folderURL: URL) -> String
}

enum AppletSlug {
    /// "Expo Status!" → "expo-status" (lowercased, non-alphanumerics → "-",
    /// runs collapsed, trimmed; empty input → "applet").
    static func slugify(_ name: String) -> String
    /// First of base, base-2, base-3… not in `existing`.
    static func unique(_ base: String, existing: Set<String>) -> String
}
```

- [ ] **Step 1: Failing tests** — `AppletManifestTests` (no actor needed):

```swift
import XCTest
@testable import Dreamux

final class AppletManifestTests: XCTestCase {
    private func tempDir() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("applet-tests-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testManifestRoundTripsAndToleratesUnknownCapabilities() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        var manifest = AppletManifest(
            id: UUID(), name: "Expo Status", slug: "expo-status",
            icon: "shippingbox", description: "Tracks EAS deployments.",
            requiresCapabilities: ["shell", "http", "screen-capture"], origin: nil)
        try manifest.write(to: dir)
        let loaded = try XCTUnwrap(AppletManifest.load(from: dir))
        XCTAssertEqual(loaded, manifest)
        XCTAssertEqual(loaded.grantedCapabilities, [.shell, .http])
        XCTAssertEqual(loaded.unknownCapabilities, ["screen-capture"])
        // Origin round-trips too.
        manifest.origin = .init(id: UUID(), hash: "abc", adoptedAt: Date(timeIntervalSince1970: 1000))
        try manifest.write(to: dir)
        XCTAssertEqual(AppletManifest.load(from: dir)?.origin, manifest.origin)
    }

    func testLoadReturnsNilForMissingOrInvalidManifest() {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertNil(AppletManifest.load(from: dir))
        try! Data("not json".utf8).write(to: dir.appendingPathComponent("manifest.json"))
        XCTAssertNil(AppletManifest.load(from: dir))
    }

    func testContentHashIsDeterministicAndSensitive() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try Data("aaa".utf8).write(to: dir.appendingPathComponent("index.html"))
        try Data("bbb".utf8).write(to: dir.appendingPathComponent("app.js"))
        try Data("junk".utf8).write(to: dir.appendingPathComponent(".DS_Store"))
        let h1 = AppletContentHash.hash(of: dir)
        XCTAssertEqual(h1, AppletContentHash.hash(of: dir))          // stable
        XCTAssertEqual(h1.count, 64)                                  // hex sha256
        try Data("changed".utf8).write(to: dir.appendingPathComponent("app.js"))
        XCTAssertNotEqual(h1, AppletContentHash.hash(of: dir))        // content-sensitive
    }

    func testSlugs() {
        XCTAssertEqual(AppletSlug.slugify("Expo Status!"), "expo-status")
        XCTAssertEqual(AppletSlug.slugify("  Kanban -- Board "), "kanban-board")
        XCTAssertEqual(AppletSlug.slugify("???"), "applet")
        XCTAssertEqual(AppletSlug.unique("kanban", existing: []), "kanban")
        XCTAssertEqual(AppletSlug.unique("kanban", existing: ["kanban"]), "kanban-2")
        XCTAssertEqual(AppletSlug.unique("kanban", existing: ["kanban", "kanban-2"]), "kanban-3")
    }
}
```

- [ ] **Step 2: Run to verify fail** — `swift test --filter AppletManifestTests` → compile failure (types undefined).
- [ ] **Step 3: Implement** `AppletManifest.swift` per the interface. Hash: `FileManager.enumerator(at:includingPropertiesForKeys:[.isRegularFileKey])`, collect regular files (skip `.DS_Store`), sort by relative path, feed `SHA256` incrementally (`path + "\0" + data`), hex-encode. `load`: `JSONDecoder` with `.iso8601`; `write`: `.prettyPrinted, .sortedKeys` + `.iso8601`, atomic.
- [ ] **Step 4: Green** — `swift test --filter AppletManifestTests`, then full `swift test`.
- [ ] **Step 5: Commit** — `git add Sources/Dreamux/Models/AppletManifest.swift Tests/DreamuxTests/AppletManifestTests.swift && git commit -m "Applets: manifest, capabilities, content hash, slugs"`

### Task 2: Scaffold resources + writer + kickoff prompt

**Files:**
- Create: `Sources/Dreamux/Resources/AppletScaffold/index.html` (template, `{{NAME}}` placeholder)
- Create: `Sources/Dreamux/Resources/AppletScaffold/dreamux.js` (bridge shim)
- Create: `Sources/Dreamux/Resources/AppletScaffold/preact.mjs`, `htm.mjs` (vendored)
- Create: `Sources/Dreamux/Resources/AppletScaffold/APPLET.md` (format + bridge reference)
- Create: `Sources/Dreamux/Models/AppletScaffold.swift`
- Modify: `Package.swift` (add `.copy("Resources/AppletScaffold")` beside `.copy("Resources/Monaco")`)
- Test: `Tests/DreamuxTests/AppletScaffoldTests.swift`

**Interfaces:**

```swift
enum AppletScaffold {
    static var bundledRoot: URL   // Bundle.module.url(forResource: "AppletScaffold", withExtension: nil)!
    /// Write a fresh applet: manifest.json + every scaffold file, with
    /// `{{NAME}}` in index.html replaced by the manifest name.
    static func write(to folderURL: URL, manifest: AppletManifest) throws
    /// The builder agent's first prompt.
    static func kickoffPrompt(appletName: String, description: String) -> String
}
```

**Vendoring:** download pinned, license-permissive builds and commit them:
`curl -fsSL https://unpkg.com/preact@10.19.3/dist/preact.module.js -o Sources/Dreamux/Resources/AppletScaffold/preact.mjs` and
`curl -fsSL https://unpkg.com/htm@3.1.1/dist/htm.module.js -o Sources/Dreamux/Resources/AppletScaffold/htm.mjs`.
If the network is unavailable, STOP and report — don't fake the files.

**`dreamux.js` (complete file):**

```js
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
  };
})();
```

**`index.html` (complete template):**

```html
<!doctype html>
<html>
<head>
<meta charset="utf-8">
<title>{{NAME}}</title>
<style>
  :root { color-scheme: dark; }
  body { margin: 0; font: 14px/1.5 -apple-system, sans-serif;
         background: #1b1c20; color: #e8e8ea; }
  main { padding: 24px; max-width: 720px; }
  h1 { font-size: 20px; margin: 0 0 8px; }
  p.hint { color: #9a9aa2; }
</style>
</head>
<body>
<div id="app"></div>
<script src="./dreamux.js"></script>
<script type="module">
import { h, render } from './preact.mjs';
import htm from './htm.mjs';
const html = htm.bind(h);

function App() {
  return html`<main>
    <h1>{{NAME}}</h1>
    <p class="hint">Scaffolded applet — tell the builder agent what to make of it.</p>
  </main>`;
}
render(html`<${App} />`, document.getElementById('app'));
</script>
</body>
</html>
```

**`APPLET.md`:** write a complete reference: what an applet is (buildless folder, `manifest.json` fields incl. `requiresCapabilities` values `kv|fs|http|shell|notify`), the full `window.dreamux` API (each method, params, return shape, errors — mirror the table in the spec), the vendored Preact+htm idiom, hot reload ("the preview reloads on save"), and the rules (edit only this folder; declare every capability you call; keep it buildless — no npm/build steps; data lives in the bridge, not localStorage).

**`kickoffPrompt` (exact string):**

```swift
static func kickoffPrompt(appletName: String, description: String) -> String {
    """
    You are building a Dreamux applet named "\(appletName)" — a small, buildless \
    web tool rendered inside the Dreamux app. Read APPLET.md in this folder FIRST: \
    it documents the applet format and the window.dreamux native bridge.
    Rules: edit files in THIS folder only. Keep it buildless (plain ES modules; \
    preact + htm are vendored here). Update manifest.json's requiresCapabilities \
    to exactly the capabilities you call. The preview hot-reloads on every save.
    The user wants: \(description)
    Build it now.
    """
}
```

- [ ] **Step 1: Failing test:**

```swift
import XCTest
@testable import Dreamux

final class AppletScaffoldTests: XCTestCase {
    func testBundledScaffoldAssetsExist() {
        let root = AppletScaffold.bundledRoot
        for file in ["index.html", "dreamux.js", "preact.mjs", "htm.mjs", "APPLET.md"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(file).path),
                          "missing scaffold asset \(file)")
        }
    }

    func testWriteScaffoldsFolderWithSubstitutedName() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("scaffold-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let manifest = AppletManifest(id: UUID(), name: "Kanban", slug: "kanban",
                                      icon: "rectangle.split.3x1", description: "d",
                                      requiresCapabilities: ["kv"], origin: nil)
        try AppletScaffold.write(to: dir, manifest: manifest)
        XCTAssertEqual(AppletManifest.load(from: dir), manifest)
        let html = try String(contentsOf: dir.appendingPathComponent("index.html"), encoding: .utf8)
        XCTAssertTrue(html.contains("<title>Kanban</title>"))
        XCTAssertFalse(html.contains("{{NAME}}"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("dreamux.js").path))
        XCTAssertTrue(AppletScaffold.kickoffPrompt(appletName: "Kanban", description: "a board")
            .contains("a board"))
    }
}
```

- [ ] **Step 2: Verify fail.**  - [ ] **Step 3: Implement** (`write`: createDirectory, copy each bundled file, substitute `{{NAME}}` in index.html, then `manifest.write(to:)`; vendor via the curl commands; Package.swift resource line).  - [ ] **Step 4: Green + full suite** (`testVendoredAssetsArePresentInBundle`-style bundle checks require `swift build` picking up Package.swift — run full `swift test`).  - [ ] **Step 5: Commit** — stage the 5 resource files + `AppletScaffold.swift` + `Package.swift` + test: `git commit -m "Applets: buildless scaffold (preact+htm+bridge shim) and kickoff prompt"`

### Task 3: AppLibraryStore (global library) + ProjectStore reserved-name guard

**Files:**
- Create: `Sources/Dreamux/Models/AppLibraryStore.swift`
- Modify: `Sources/Dreamux/Models/ProjectStore.swift` (skip reserved folder in `refresh()`)
- Test: `Tests/DreamuxTests/AppLibraryStoreTests.swift`

**Why the ProjectStore change:** the library lives at `~/Documents/Dreamux/Apps/` — *inside projectsRoot* — and `ProjectStore.refresh()` (`ProjectStore.swift:138-187`) treats every subdirectory as a project. Without a guard, a phantom "Apps" project appears.

**Interfaces:**

```swift
@MainActor
@Observable
final class AppLibraryStore {
    private(set) var applets: [Applet] = []
    let root: URL

    /// `$DREAMUX_APPS_ROOT` when set (e2e/tests), else
    /// `ProjectStore.projectsRootURL()/Apps`. Created on demand.
    nonisolated static func appsRootURL() -> URL

    init(root: URL = AppLibraryStore.appsRootURL())   // calls refresh()

    /// Folder is source of truth: every subdirectory with a loadable
    /// manifest becomes an Applet (sorted by name); invalid ones are
    /// skipped (never crash).
    func refresh()

    /// Scaffold a new canonical applet (slug uniqued against current
    /// library slugs), refresh, return it.
    @discardableResult
    func createApplet(name: String, description: String, icon: String) throws -> Applet

    /// Trash the applet folder (recoverable), refresh.
    func delete(_ applet: Applet) throws

    func applet(id: UUID) -> Applet?
}

// ProjectStore addition:
extension ProjectStore {
    /// Folder names under projectsRoot that are NOT projects ("Apps" is
    /// the applet library). Pure so it's testable without env plumbing.
    nonisolated static func isReservedProjectFolderName(_ name: String) -> Bool // name == "Apps"
}
// …and in refresh()'s directory loop, before the isDirectory check's use:
// guard !Self.isReservedProjectFolderName(standardized.lastPathComponent) else { continue }
```

- [ ] **Step 1: Failing tests:**

```swift
import XCTest
@testable import Dreamux

@MainActor
final class AppLibraryStoreTests: XCTestCase {
    private func tempRoot() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("app-library-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testCreateScaffoldsDiscoverableApplet() throws {
        let root = tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let store = AppLibraryStore(root: root)
        let applet = try store.createApplet(name: "Expo Status", description: "d", icon: "shippingbox")
        XCTAssertEqual(applet.slug, "expo-status")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("expo-status/index.html").path))
        // A second store over the same root discovers it by scan.
        XCTAssertEqual(AppLibraryStore(root: root).applets.map(\.slug), ["expo-status"])
        // Same name again → suffixed slug.
        XCTAssertEqual(try store.createApplet(name: "Expo Status", description: "d", icon: "s").slug,
                       "expo-status-2")
    }

    func testRefreshSkipsInvalidFolders() throws {
        let root = tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("broken"), withIntermediateDirectories: true)
        XCTAssertEqual(AppLibraryStore(root: root).applets, [])
    }

    func testDeleteRemovesFolder() throws {
        let root = tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let store = AppLibraryStore(root: root)
        let applet = try store.createApplet(name: "Kanban", description: "d", icon: "s")
        try store.delete(applet)
        XCTAssertFalse(FileManager.default.fileExists(atPath: applet.folderURL.path))
        XCTAssertEqual(store.applets, [])
    }

    func testAppsFolderIsReservedProjectName() {
        XCTAssertTrue(ProjectStore.isReservedProjectFolderName("Apps"))
        XCTAssertFalse(ProjectStore.isReservedProjectFolderName("apps-thing"))
        XCTAssertFalse(ProjectStore.isReservedProjectFolderName("MyProject"))
    }
}
```

- [ ] **Step 2: Verify fail.**  - [ ] **Step 3: Implement** (mirror `ProjectStore`: scan + sort by name; `createApplet` builds `AppletManifest(id: UUID(), name:…, slug: AppletSlug.unique(AppletSlug.slugify(name), existing: Set(applets.map(\.slug))), …, requiresCapabilities: [], origin: nil)` then `AppletScaffold.write`; `delete` via `fm.trashItem`; the one-line guard in `ProjectStore.refresh()`).  - [ ] **Step 4: Green + full suite.**  - [ ] **Step 5: Commit** — `git commit -m "Applets: global App Studio library store; reserve Apps folder name"`

### Task 4: ProjectAppletStore (adopt / local-born / remove / publish)

**Files:**
- Create: `Sources/Dreamux/Models/ProjectAppletStore.swift`
- Test: `Tests/DreamuxTests/ProjectAppletStoreTests.swift`

**Interfaces:**

```swift
@MainActor
@Observable
final class ProjectAppletStore {
    private(set) var applets: [Applet] = []
    /// Folder names under apps/ whose manifest failed to load — the
    /// sidebar renders these as warning rows (spec: degrade visibly,
    /// never crash or silently hide).
    private(set) var invalidFolders: [String] = []
    let appsDir: URL          // <project>/apps
    let stateDir: URL         // <project>/.dreamux

    init(project: Project)    // appsDir = rootPath/apps; refresh()
    /// Test seam: same shape, explicit roots.
    init(appsDir: URL, stateDir: URL)

    func refresh()            // scan appsDir subfolders: loadable manifests → applets
                              // (sorted by name), the rest → invalidFolders
    func applet(id: UUID) -> Applet?

    /// Copy a library applet into this project. The copy gets a NEW id,
    /// a slug uniqued against this project, and `origin` stamped with the
    /// library id + AppletContentHash of the library folder + now.
    @discardableResult
    func adopt(_ library: Applet) throws -> Applet

    /// Scaffold a local-born applet (no origin).
    @discardableResult
    func createLocal(name: String, description: String, icon: String) throws -> Applet

    /// Delete the applet folder AND its data dir. Not trash — the confirm
    /// dialog (Task 8) is the safety net, and appdata under .dreamux is
    /// runtime state.
    func remove(_ applet: Applet) throws

    /// Copy a local-born applet up to the library (new library id, slug
    /// uniqued there), then stamp THIS copy's origin to point at it.
    @discardableResult
    func publish(_ applet: Applet, to library: AppLibraryStore) throws -> Applet

    /// <project>/.dreamux/appdata/<slug>/ — created on demand
    /// (via DreamuxStateDir.ensure so .dreamux stays gitignored).
    func dataDir(for applet: Applet) -> URL
}
```

- [ ] **Step 1: Failing tests:**

```swift
import XCTest
@testable import Dreamux

@MainActor
final class ProjectAppletStoreTests: XCTestCase {
    private var projectDir: URL!
    private var libraryRoot: URL!

    override func setUp() {
        super.setUp()
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("proj-applets-\(UUID().uuidString)", isDirectory: true)
        projectDir = base.appendingPathComponent("proj", isDirectory: true)
        libraryRoot = base.appendingPathComponent("library", isDirectory: true)
        try! FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        try! FileManager.default.createDirectory(at: libraryRoot, withIntermediateDirectories: true)
    }
    override func tearDown() {
        try? FileManager.default.removeItem(at: projectDir.deletingLastPathComponent())
        super.tearDown()
    }
    private func makeStore() -> ProjectAppletStore {
        ProjectAppletStore(appsDir: projectDir.appendingPathComponent("apps"),
                           stateDir: projectDir.appendingPathComponent(".dreamux"))
    }

    func testAdoptCopiesWithNewIdentityAndOrigin() throws {
        let library = AppLibraryStore(root: libraryRoot)
        let canon = try library.createApplet(name: "Kanban", description: "d", icon: "s")
        let store = makeStore()
        let adopted = try store.adopt(canon)
        XCTAssertNotEqual(adopted.id, canon.id)                       // its own identity
        XCTAssertEqual(adopted.manifest.origin?.id, canon.id)          // lineage
        XCTAssertEqual(adopted.manifest.origin?.hash, AppletContentHash.hash(of: canon.folderURL))
        XCTAssertTrue(adopted.isAdopted)
        XCTAssertTrue(adopted.folderURL.path.hasSuffix("apps/kanban"))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: adopted.folderURL.appendingPathComponent("index.html").path))
        // Adopting again → suffixed slug, both discoverable.
        XCTAssertEqual(try store.adopt(canon).slug, "kanban-2")
        XCTAssertEqual(store.applets.count, 2)
    }

    func testCreateLocalHasNoOrigin() throws {
        let store = makeStore()
        let applet = try store.createLocal(name: "Sink", description: "d", icon: "s")
        XCTAssertNil(applet.manifest.origin)
        XCTAssertEqual(store.applets.map(\.slug), ["sink"])
    }

    func testRemoveDeletesFolderAndData() throws {
        let store = makeStore()
        let applet = try store.createLocal(name: "Sink", description: "d", icon: "s")
        let data = store.dataDir(for: applet)
        try Data("{}".utf8).write(to: data.appendingPathComponent("kv.json"))
        try store.remove(applet)
        XCTAssertFalse(FileManager.default.fileExists(atPath: applet.folderURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: data.path))
        XCTAssertEqual(store.applets, [])
    }

    func testPublishStampsOriginAndLandsInLibrary() throws {
        let library = AppLibraryStore(root: libraryRoot)
        let store = makeStore()
        let local = try store.createLocal(name: "Sink", description: "d", icon: "s")
        let published = try store.publish(local, to: library)
        XCTAssertEqual(library.applets.map(\.slug), ["sink"])
        XCTAssertNotEqual(published.id, local.id)
        // The project copy now records its lineage.
        let refreshed = try XCTUnwrap(store.applets.first)
        XCTAssertEqual(refreshed.manifest.origin?.id, published.id)
    }

    func testDataDirIsUnderDreamuxAppdata() throws {
        let store = makeStore()
        let applet = try store.createLocal(name: "Sink", description: "d", icon: "s")
        XCTAssertTrue(store.dataDir(for: applet).path.hasSuffix(".dreamux/appdata/sink"))
    }

    func testBrokenFolderSurfacesAsInvalidNotCrash() throws {
        let store = makeStore()
        try FileManager.default.createDirectory(
            at: store.appsDir.appendingPathComponent("broken"), withIntermediateDirectories: true)
        store.refresh()
        XCTAssertEqual(store.applets, [])
        XCTAssertEqual(store.invalidFolders, ["broken"])
    }
}
```

- [ ] **Step 2: Verify fail.**  - [ ] **Step 3: Implement.** Copy = `fm.copyItem(at:to:)` then rewrite the copy's manifest (new `id: UUID()`, uniqued slug, origin stamp). `dataDir` uses `DreamuxStateDir.ensure(containing:)` on a file inside it. `Project`-based init: `self.init(appsDir: project.rootPath.appendingPathComponent("apps"), stateDir: project.rootPath.appendingPathComponent(".dreamux"))`.  - [ ] **Step 4: Green + full suite.**  - [ ] **Step 5: Commit** — `git commit -m "Applets: per-project store — adopt, local-born, remove, publish"`

---

## GROUP 2 — Runtime (scheme, data, bridge)

### Task 5: AppletSchemeHandler with a real traversal guard

**Files:**
- Create: `Sources/Dreamux/Views/Applets/AppletSchemeHandler.swift`
- Test: `Tests/DreamuxTests/AppletSchemeHandlerTests.swift`

**Interfaces:**

```swift
/// Serves an applet folder to its WKWebView over `dreamux-applet://`.
/// URL shape: `dreamux-applet://<applet-id>/<path>`; bare host → index.html.
/// Clone of MonacoSchemeHandler PLUS a traversal guard: the resolved file
/// must stay inside the root.
final class AppletSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "dreamux-applet"
    init(root: URL)
    // WKURLSchemeHandler start/stop — as MonacoSchemeHandler, but resolve
    // through resolvedFileURL and 404 (URLError(.fileDoesNotExist)) on nil.

    /// nil for foreign schemes, absolute-escaping paths, or any resolution
    /// (symlinks included) landing outside `root`. "" → index.html.
    static func resolvedFileURL(for url: URL, root: URL) -> URL?
    static func mimeType(forPathExtension ext: String) -> String  // Monaco's + "mjs" → text/javascript, "md" → text/markdown
}
```

- [ ] **Step 1: Failing tests:**

```swift
import XCTest
@testable import Dreamux

final class AppletSchemeHandlerTests: XCTestCase {
    private func makeRoot() -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("applet-scheme-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(
            at: root.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try! Data("hi".utf8).write(to: root.appendingPathComponent("index.html"))
        try! Data("x".utf8).write(to: root.appendingPathComponent("sub/a.js"))
        // A secret OUTSIDE the root that escapes must never reach.
        try! Data("secret".utf8).write(
            to: root.deletingLastPathComponent().appendingPathComponent("secret-\(root.lastPathComponent).txt"))
        return root
    }

    func testResolvesNormalAndNestedPaths() {
        let root = makeRoot(); defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(
            AppletSchemeHandler.resolvedFileURL(
                for: URL(string: "dreamux-applet://abc/index.html")!, root: root)?.lastPathComponent,
            "index.html")
        XCTAssertEqual(
            AppletSchemeHandler.resolvedFileURL(
                for: URL(string: "dreamux-applet://abc/sub/a.js")!, root: root)?.lastPathComponent,
            "a.js")
        // Bare host → index.html.
        XCTAssertEqual(
            AppletSchemeHandler.resolvedFileURL(
                for: URL(string: "dreamux-applet://abc")!, root: root)?.lastPathComponent,
            "index.html")
    }

    func testRejectsTraversalAndForeignSchemes() {
        let root = makeRoot(); defer { try? FileManager.default.removeItem(at: root) }
        for bad in [
            "dreamux-applet://abc/../escape.txt",
            "dreamux-applet://abc/sub/../../escape.txt",
            "dreamux-applet://abc/%2e%2e/escape.txt",
            "https://example.com/x",
        ] {
            XCTAssertNil(AppletSchemeHandler.resolvedFileURL(for: URL(string: bad)!, root: root),
                         "should reject \(bad)")
        }
    }

    func testRejectsSymlinkEscape() throws {
        let root = makeRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let outside = root.deletingLastPathComponent().appendingPathComponent("outside-\(UUID()).txt")
        try Data("secret".utf8).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("link.txt"), withDestinationURL: outside)
        XCTAssertNil(AppletSchemeHandler.resolvedFileURL(
            for: URL(string: "dreamux-applet://abc/link.txt")!, root: root))
    }
}
```

- [ ] **Step 2: Verify fail.**  - [ ] **Step 3: Implement.** Guard shape: percent-decode the URL path, reject if empty→index.html else append to root, then `standardizedFileURL.resolvingSymlinksInPath()` on BOTH candidate and root and require `candidate.path == root.path || candidate.path.hasPrefix(root.path + "/")`.  - [ ] **Step 4: Green + full suite.**  - [ ] **Step 5: Commit** — `git commit -m "Applets: custom-scheme asset serving with traversal guard"`

### Task 6: AppletDataStore (kv + scoped fs) and bridge request parsing/gating

**Files:**
- Create: `Sources/Dreamux/Models/AppletDataStore.swift`
- Create: `Sources/Dreamux/Views/Applets/AppletBridgeCore.swift` (the pure half of the bridge)
- Test: `Tests/DreamuxTests/AppletDataStoreTests.swift`, `Tests/DreamuxTests/AppletBridgeCoreTests.swift`

**Interfaces:**

```swift
/// The applet's persistent state: kv.json + files/, both under its data
/// dir. All ops are synchronous file IO (values are small); every path is
/// traversal-guarded.
struct AppletDataStore: Sendable {
    let dataDir: URL
    init(dataDir: URL)                       // creates dataDir + files/ on demand

    func kvGet(_ key: String) -> Any?        // JSON value or nil
    func kvSet(_ key: String, value: Any) throws
    func kvDelete(_ key: String) throws
    func kvList() -> [String: Any]           // whole map (empty when absent)

    /// files/<relative>, nil when the resolution escapes files/.
    func scopedFileURL(_ relative: String) -> URL?
    func fsRead(_ relative: String) throws -> String       // throws on escape/missing
    func fsWrite(_ relative: String, text: String) throws  // creates intermediate dirs
    func fsList(_ relative: String) throws -> [String]     // names, sorted
    func fsDelete(_ relative: String) throws
}

enum AppletBridgeError: Error, LocalizedError {
    case unknownMethod(String)
    case capabilityNotDeclared(method: String, capability: AppletCapability)
    case badParams(String)
    case pathEscapesSandbox(String)
    var errorDescription: String? { /* the undeclared case MUST name the fix:
        "…add \"<capability>\" to requiresCapabilities in manifest.json" */ }
}

/// One parsed JS→native request.
struct BridgeRequest: Sendable {
    let id: Int
    let method: String
    let params: [String: Any]
    static func parse(_ body: Any) -> BridgeRequest?   // nil unless {id: Int, method: String}
}

enum AppletBridgeCore {
    /// The capability a method needs; nil = always allowed ("context").
    /// Unknown methods are a thrown unknownMethod at dispatch, not here.
    static func capability(forMethod method: String) -> AppletCapability?
    static let knownMethods: Set<String>
    // ["context", "kv.get","kv.set","kv.delete","kv.list",
    //  "fs.read","fs.write","fs.list","fs.delete",
    //  "http.fetch", "shell.exec", "notify"]

    /// Gate: throws unknownMethod / capabilityNotDeclared.
    static func checkAllowed(method: String, granted: Set<AppletCapability>) throws
}
```

- [ ] **Step 1: Failing tests:**

```swift
import XCTest
@testable import Dreamux

final class AppletDataStoreTests: XCTestCase {
    private func makeStore() -> (AppletDataStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("appdata-\(UUID().uuidString)", isDirectory: true)
        return (AppletDataStore(dataDir: dir), dir)
    }

    func testKvRoundTrip() throws {
        let (store, dir) = makeStore(); defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertNil(store.kvGet("missing"))
        try store.kvSet("board", value: ["cols": [["name": "todo"]]])
        let value = try XCTUnwrap(store.kvGet("board") as? [String: Any])
        XCTAssertNotNil(value["cols"])
        XCTAssertEqual(store.kvList().count, 1)
        try store.kvDelete("board")
        XCTAssertNil(store.kvGet("board"))
    }

    func testFsScopingAndOps() throws {
        let (store, dir) = makeStore(); defer { try? FileManager.default.removeItem(at: dir) }
        try store.fsWrite("notes/a.txt", text: "hello")
        XCTAssertEqual(try store.fsRead("notes/a.txt"), "hello")
        XCTAssertEqual(try store.fsList("notes"), ["a.txt"])
        try store.fsDelete("notes/a.txt")
        XCTAssertThrowsError(try store.fsRead("notes/a.txt"))
        // Escapes rejected.
        XCTAssertNil(store.scopedFileURL("../kv.json"))
        XCTAssertNil(store.scopedFileURL("a/../../outside"))
        XCTAssertThrowsError(try store.fsRead("../kv.json"))
    }
}

final class AppletBridgeCoreTests: XCTestCase {
    func testParse() {
        let req = BridgeRequest.parse(["id": 3, "method": "kv.get", "params": ["key": "k"]])
        XCTAssertEqual(req?.id, 3)
        XCTAssertEqual(req?.method, "kv.get")
        XCTAssertEqual(req?.params["key"] as? String, "k")
        XCTAssertNil(BridgeRequest.parse(["method": "kv.get"]))       // no id
        XCTAssertNil(BridgeRequest.parse("nonsense"))
    }

    func testCapabilityMappingAndGate() throws {
        XCTAssertNil(AppletBridgeCore.capability(forMethod: "context"))
        XCTAssertEqual(AppletBridgeCore.capability(forMethod: "kv.set"), .kv)
        XCTAssertEqual(AppletBridgeCore.capability(forMethod: "fs.read"), .fs)
        XCTAssertEqual(AppletBridgeCore.capability(forMethod: "http.fetch"), .http)
        XCTAssertEqual(AppletBridgeCore.capability(forMethod: "shell.exec"), .shell)
        XCTAssertEqual(AppletBridgeCore.capability(forMethod: "notify"), .notify)
        XCTAssertNoThrow(try AppletBridgeCore.checkAllowed(method: "context", granted: []))
        XCTAssertNoThrow(try AppletBridgeCore.checkAllowed(method: "kv.get", granted: [.kv]))
        XCTAssertThrowsError(try AppletBridgeCore.checkAllowed(method: "shell.exec", granted: [.kv])) {
            // The error message names the manifest fix.
            XCTAssertTrue("\($0.localizedDescription)".contains("requiresCapabilities"))
        }
        XCTAssertThrowsError(try AppletBridgeCore.checkAllowed(method: "bogus", granted: [.kv]))
    }
}
```

- [ ] **Step 2: Verify fail.**  - [ ] **Step 3: Implement.** kv.json via `JSONSerialization` (read dict, mutate, atomic write). Scoping guard = same standardize+symlink-resolve+prefix check as Task 5 (extract nothing — keep each local and tested; they're 6 lines).  - [ ] **Step 4: Green + full suite.**  - [ ] **Step 5: Commit** — `git commit -m "Applets: data store (kv + scoped fs) and bridge core (parse + capability gate)"`

### Task 7: AppletSession — webview, live bridge, shell/http, hot reload

**Files:**
- Create: `Sources/Dreamux/Models/AppletSession.swift`
- Create: `Sources/Dreamux/Views/Applets/AppletBridge.swift` (the WKScriptMessageHandler half)
- Create: `Sources/Dreamux/Shell/AppletShell.swift`
- Test: `Tests/DreamuxTests/AppletShellTests.swift`

**Interfaces:**

```swift
/// Everything live behind one open applet: preview WKWebView (lazy, custom
/// scheme + bridge + nav lockdown), the optional builder-agent terminal,
/// and a folder poller for hot reload. Held per-applet by ProjectSession
/// (and by AppStudioView), NOT rebuilt per render.
@MainActor
@Observable
final class AppletSession: Identifiable {
    private(set) var applet: Applet
    let dataStore: AppletDataStore
    let projectRoot: URL
    var id: UUID { applet.id }

    /// Header error badge: last window.onerror / unhandledrejection text.
    var lastJSError: String?
    var isEditing = false
    private(set) var agentTab: TabSession?

    init(applet: Applet, dataDir: URL, projectRoot: URL)

    var webView: WKWebView   // lazy; see wiring below
    func reload()            // re-reads manifest from disk (capabilities may
                             // have changed), clears lastJSError, webView.reload()

    /// Open (or reveal) the builder agent terminal cwd'd in the applet
    /// folder. `kickoff` non-nil types the first prompt (create flow);
    /// nil just opens claude in the folder (edit flow) with a short
    /// "read APPLET.md; the user will direct you" prompt.
    func beginEditing(kickoff: String?)
    func endEditing()        // isEditing = false (terminal session kept; re-entry is instant)
    func stopAgent()         // agentTab?.stop(); agentTab = nil — call when the applet closes
}

enum AppletShell {
    /// /bin/sh -lc in `cwd`, own process group (killed wholesale on
    /// timeout — see Foundation.Process group-kill behavior), stdout/stderr
    /// capped at 1 MB each.
    static func exec(cmd: String, cwd: URL, timeout: TimeInterval = 60)
        async -> (stdout: String, stderr: String, code: Int32)
}
```

**webView wiring (in `AppletSession`):**
- `WKWebViewConfiguration` + `setURLSchemeHandler(AppletSchemeHandler(root: applet.folderURL), forURLScheme: AppletSchemeHandler.scheme)`.
- `config.userContentController.add(AppletBridge(owner: self), name: "dreamux")` — `AppletBridge` mirrors `FileEditorTabSession.Bridge` (`NSObject`, **weak** owner).
- Inject error forwarding as a `WKUserScript` (`.atDocumentStart`, main frame):
  `window.onerror = (m,s,l) => webkit.messageHandlers.dreamux.postMessage({method:'__error', text: m + ' (' + s + ':' + l + ')'}); window.onunhandledrejection = e => webkit.messageHandlers.dreamux.postMessage({method:'__error', text: String(e.reason)});`
- `navigationDelegate` = an `AppletNavigationPolicy: NSObject, WKNavigationDelegate` (held strongly by the session — `webView.navigationDelegate` is weak): allow `dreamux-applet:` and `about:`; for `http(s)` **`.cancel` + `NSWorkspace.shared.open(url)`**; cancel everything else.
- `isInspectable = true`; load `dreamux-applet://<id>/index.html`.
- Hot reload: a 1-second `Timer` (only while `_webView != nil`) compares the max `contentModificationDate` across the folder's regular files; on change → `reload()`. (Directory kqueue misses child-content edits; polling a ≤20-file folder is honest and cheap. Invalidate the timer in `stopAgent`.)

**`AppletBridge` dispatch (in `AppletBridge.swift`):** on `userContentController(_:didReceive:)` — `MainActor.assumeIsolated`, handle `{method:'__error'}` (no id) by setting `owner.lastJSError`; else `BridgeRequest.parse`, `AppletBridgeCore.checkAllowed(method:granted: owner.applet.manifest.grantedCapabilities)`, then dispatch:

| method | native |
|---|---|
| `context` | `["projectName": projectRoot.lastPathComponent, "projectRoot": projectRoot.path, "dataDir": dataStore.dataDir.path]` |
| `kv.*` / `fs.*` | `dataStore` calls (params: `key`/`value`/`path`/`text`) |
| `http.fetch` | `Task { URLSession.shared.data(for:) }` — method/headers/body from params; reply `["status": Int, "headers": [String:String], "text": String]` |
| `shell.exec` | `Task { await AppletShell.exec(cmd:, cwd: params["cwd"].map(URL.init(fileURLWithPath:)) ?? projectRoot, timeout: params["timeout"] as? Double ?? 60) }` → `["stdout":…, "stderr":…, "code":…]` |
| `notify` | `UNUserNotificationCenter` content(title:body:) — or `NotificationManager` if it exposes a generic entry (check first) |

Reply: `evaluateJavaScript("window.__dreamuxReply(\(id), \(json))")` where `json` is `JSONSerialization` of `["result": value]` / `["error": message]` — reuse `FileEditorTabSession.jsString` for any raw-string interpolation. Errors NEVER crash: every throw becomes an `{error}` reply.

- [ ] **Step 1: Failing test** (the testable non-UI part):

```swift
import XCTest
@testable import Dreamux

final class AppletShellTests: XCTestCase {
    func testExecCapturesOutputAndExitCode() async {
        let cwd = FileManager.default.temporaryDirectory
        let ok = await AppletShell.exec(cmd: "echo hi; echo err 1>&2", cwd: cwd, timeout: 10)
        XCTAssertEqual(ok.stdout, "hi\n")
        XCTAssertEqual(ok.stderr, "err\n")
        XCTAssertEqual(ok.code, 0)
        let fail = await AppletShell.exec(cmd: "exit 3", cwd: cwd, timeout: 10)
        XCTAssertEqual(fail.code, 3)
    }

    func testExecTimesOut() async {
        let start = Date()
        let result = await AppletShell.exec(
            cmd: "sleep 30", cwd: FileManager.default.temporaryDirectory, timeout: 1)
        XCTAssertLessThan(Date().timeIntervalSince(start), 10)
        XCTAssertNotEqual(result.code, 0)
    }

    func testExecRunsInCwd() async {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("shell-cwd-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let result = await AppletShell.exec(cmd: "pwd", cwd: dir, timeout: 10)
        XCTAssertEqual(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines),
                       dir.resolvingSymlinksInPath().path)
    }
}
```

- [ ] **Step 2: Verify fail.**  - [ ] **Step 3: Implement** `AppletShell` (Process, `/bin/sh -lc`, pipes drained off-main, timeout via a detached watchdog task calling `terminate()` — Process group-kills its children), then `AppletSession` + `AppletBridge` per the wiring above. `beginEditing`: if `agentTab == nil`, `agentTab = TabSession(cwd: applet.folderURL.path, onActivity: { _ in })`, then `ClaudePromptDriver.send(kickoff ?? editPrompt, into: agentTab!)`; `isEditing = true`.
- [ ] **Step 4: Green + full suite + `swift build`.**  - [ ] **Step 5: Commit** — `git commit -m "Applets: live session — locked-down webview, native bridge, shell/http, hot reload"`

---

## GROUP 3 — UI

### Task 8: APPS sidebar section + SidebarMode.app + host view

**Files:**
- Create: `Sources/Dreamux/Views/Applets/AppsSection.swift`
- Create: `Sources/Dreamux/Views/Applets/AppletHostView.swift`
- Create: `Sources/Dreamux/Views/Applets/NewAppSheet.swift`
- Modify: `Sources/Dreamux/Models/SidebarLayoutStore.swift` (add `appsExpanded`, default `true`, + `Payload.appsExpanded: Bool?`)
- Modify: `Sources/Dreamux/Models/ProjectSession.swift` (add `let applets: ProjectAppletStore`, `let appLibrary: AppLibraryStore`, `private var appletSessions: [UUID: AppletSession] = [:]`, `func appletSession(for applet: Applet) -> AppletSession` — creates with `dataDir: applets.dataDir(for:)`, `projectRoot: project.rootPath`, caches; also `func closeAppletSession(id: UUID)` calling `stopAgent()`)
- Modify: `Sources/Dreamux/Views/ContentView.swift` (`SidebarMode` gains `case app(UUID)`; `mainPane` gains the branch; pass-throughs to `WorkspaceSidebar`)
- Modify: `Sources/Dreamux/Views/WorkspaceSidebar.swift` (mount `AppsSection` between tiles and `PlansSpecsSection`; new params)

**Interfaces:**

```swift
/// The APPS sidebar section. House style: 13pt header w/ chevron collapse
/// (persisted via layout.appsExpanded), 15pt rows, "+ New app" foot row.
struct AppsSection: View {
    @Bindable var applets: ProjectAppletStore
    @Bindable var layout: SidebarLayoutStore
    @Binding var sidebarMode: SidebarMode
    let onOpenApplet: (Applet) -> Void      // sets sidebarMode = .app(id)
    let onNewApp: () -> Void                // opens NewAppSheet
    let onRemove: (Applet) -> Void          // confirm + store.remove (+ closeAppletSession)
    let onPublish: (Applet) -> Void         // local-born only
}

struct AppletHostView: View {
    @Bindable var session: AppletSession
}

/// Two paths: Create new (name + description) | Adopt from App Studio.
/// `onAdopt` is optional so App Studio (Task 9) can reuse the sheet
/// create-only — nil hides the Adopt path entirely.
struct NewAppSheet: View {
    let library: [Applet]                   // appLibrary.applets (refreshed on appear by caller)
    let onCreate: (String, String) -> Void  // (name, description)
    let onAdopt: ((Applet) -> Void)?
    let onCancel: () -> Void
}
```

Semantics (build-gated; e2e in Task 10):
1. **Row:** `Image(systemName: manifest.icon)` 15pt in a 28pt-wide frame, name 15pt medium, and — when `isAdopted` — a trailing `square.on.square` 11pt `.tertiary` glyph (`.help("Adopted from App Studio")`). Selected wash 0.08 when `sidebarMode == .app(applet.id)`, hover 0.04, cornerRadius 8. After the applet rows, each `applets.invalidFolders` name renders a non-clickable 15pt `.secondary` row with `exclamationmark.triangle` and `.help("apps/<name>/manifest.json is missing or invalid")` (degrade visibly, never crash).
2. **Context menu:** Remove from project… (SwiftUI `confirmationDialog`: "Deletes the app folder and its data. This can't be undone."), Publish to App Studio (only `origin == nil`), Reveal in Finder.
3. **Header:** chevron + "Apps", identical construction to `PlansSpecsSection.header` (`PlansSpecsSection.swift:170-193`), toggling `layout.appsExpanded`.
4. **Foot row:** "+ New app" — copy `newWorkspaceRow` (`:199-223`) verbatim shape.
5. **`AppletHostView`:** slim header bar (`.padding(.horizontal, 12).padding(.vertical, 8)`, `.background(.bar)` like `WebTabView`'s bar): icon + name (15pt semibold), `"Adopted from App Studio"` 12pt `.secondary` when adopted, `lastJSError.map { badge }` (`exclamationmark.triangle.fill` orange + `.help(error)`), `Spacer`, buttons **Edit/Done** (toggles `beginEditing(kickoff: nil)` / `endEditing()`), **Reload**, **Reveal** — all `.buttonStyle(.soft)`. Below: `if session.isEditing { HSplitView { preview; HostedTerminalView(session: session.agentTab!, dropTargetEnabled: false).onAppear { session.agentTab?.startIfNeeded() }.frame(minWidth: 320) } } else { preview }` where `preview = AppletWebViewRepresentable(webView: session.webView)` (a 4-line `NSViewRepresentable`, same as `WebViewRepresentable`).
6. **ContentView:** `case .app(let id): if let applet = session.applets.applet(id: id) { AppletHostView(session: session.appletSession(for: applet)) } else { missing-state text + the section auto-heals on refresh }`. New-app create flow: `store.createLocal` → `appletSession(for:)` → `beginEditing(kickoff: AppletScaffold.kickoffPrompt(appletName:description:))` → `sidebarMode = .app(id)`. Adopt flow: `store.adopt(libraryApplet)` → `sidebarMode = .app(id)` (no agent).
7. `ProjectAppletStore.refresh()` on `AppsSection.onAppear` (folder is source of truth; a full watcher is deferred).

- [ ] **Step 1: Implement** everything above.
- [ ] **Step 2: `swift build` + full `swift test`** (existing suite unchanged; `SidebarLayoutStore` default check: add one assertion to `SidebarLayoutStoreTests` that a fresh store has `appsExpanded == true` — follow that file's construction idiom).
- [ ] **Step 3: Manual smoke** — `./Scripts/make-app.sh debug && open ./Dreamux.app`: APPS section shows, + New app creates + opens with agent kickoff typing, preview renders scaffold, Edit splits, Reload works.
- [ ] **Step 4: Commit** — `git commit -m "Applets: APPS sidebar section, app mode in main pane, host view with builder agent"`

### Task 9: App Studio — rail entry + window + library surface

**Files:**
- Create: `Sources/Dreamux/Views/Applets/AppStudioView.swift`
- Modify: `Sources/Dreamux/DreamuxApp.swift` (add scene: `Window("App Studio", id: "app-studio") { AppStudioView() }` beside the `Settings` scene)
- Modify: `Sources/Dreamux/Views/ProjectsRail.swift` (pinned "App Studio" row above New Project — `Label("App Studio", systemImage: "shippingbox")`, same row construction as New Project; `@Environment(\.openWindow)` → `openWindow(id: "app-studio")`)
- Modify: `Sources/Dreamux/Views/ContentView.swift` (`collapsedRailStub`: a 34×34 `shippingbox` tile button above the New Project tile, same shape, `.help("App Studio")`)

Semantics (build-gated; v1-minimal per spec):
1. `AppStudioView` owns `@State private var library = AppLibraryStore()` and `@State private var sessions: [UUID: AppletSession] = [:]`, `@State private var selectedID: UUID?`.
2. Layout: `HSplitView` — left (min 240): header "App Studio" (13pt semibold uppercase kern 0.4) + rows (icon 15pt/28pt frame, name 15pt, description 13pt `.secondary` lineLimit 1; wash 0.04/0.08) + "+ New app" foot row (same `NewAppSheet`, create-only — hide the Adopt path when `onAdopt` is nil; make `NewAppSheet.onAdopt` optional `((Applet) -> Void)?` in Task 8 to support this); right: `AppletHostView(session:)` for the selection, else a `shippingbox` empty state ("Canonical applets live here; projects adopt copies.").
3. Library sessions get **scratch data**: `dataDir = <Application Support>/Dreamux/AppStudioData/<slug>` (reuse the `DREAMUX_STATE_DIR`-aware app-support resolution — extract `ProjectStore`'s appDir lookup (`ProjectStore.swift:50-62`) into `nonisolated static func stateRootURL() -> URL` on `ProjectStore` and call it from both places); `projectRoot = applet.folderURL` (shell cwd = the applet folder; there is no project here).
4. Row context menu: Delete… (`confirmationDialog`; `library.delete` — trash, so recoverable), Reveal in Finder.
5. `library.refresh()` on `onAppear`, plus a Refresh `.soft` button in the left column's header row (the simple, deterministic choice — no window-notification plumbing).
6. Editing in App Studio edits the CANON (spec: same host view, library folder, scratch data) — the builder agent cwd is the library applet folder.

- [ ] **Step 1: Implement.**  - [ ] **Step 2: `swift build` + full `swift test`.**  - [ ] **Step 3: Manual smoke** — rail row opens the window; create/select/preview/edit/delete work; adopting from a project's NewAppSheet sees the library entry.
- [ ] **Step 4: Commit** — `git commit -m "App Studio: outer-rail entry, library window, canonical applet editing"`

---

## GROUP 4 — E2E

### Task 10: e2e commands + scenario with a real bridge round-trip

**Files:**
- Modify: `Sources/Dreamux/E2E/E2ECommands.swift` (+ the e2e bridge/registry plumbing those commands need — mirror `dequeuePlan`/`setSidebarMode`)
- Modify: `Scripts/e2e/driver.py`
- Modify: `Scripts/e2e/PROTOCOL.md`

**Commands (mirror the existing `case` shapes at `E2ECommands.swift:52-120`):**
- `createApplet` `{name, description}` → `session.applets.createLocal(name:description:icon: "shippingbox")` — **no agent kickoff** (deterministic; the builder agent is not e2e-testable). Returns `{slug, id}`.
- `openApplet` `{slug}` → resolve in `session.applets`, drive `sidebarMode = .app(id)` through the same pending-channel `setSidebarMode` uses. Error string when the slug is unknown.
- `adoptApplet` `{slug}` → resolve in a fresh `AppLibraryStore()` (honors `$DREAMUX_APPS_ROOT`), `session.applets.adopt(_:)`. Returns the adopted `{slug, id}`.
- `removeApplet` `{slug}` → resolve in `session.applets`, `remove(_:)` + `session.closeAppletSession(id:)`.
- `appletsState` → `{projectApplets: [{slug, name, adopted: Bool}], libraryApplets: [{slug, name}]}`.

**Driver scenario `scenario_applets` (in `driver.py`, following the existing scenario functions):**
1. Standard sandboxed launch (existing fixtures; `DREAMUX_APPS_ROOT` → a temp dir so the real library is never touched — export it in the launch env beside the existing `DREAMUX_*` vars).
2. `createApplet {name: "Probe", description: "e2e probe"}` → expect slug `probe`; `appletsState` lists it, `adopted == false`.
3. **Overwrite** `<project>/apps/probe/index.html` from the driver with a probe page (keep `dreamux.js`!) and rewrite `manifest.json`'s `requiresCapabilities` to `["kv"]`:

```html
<!doctype html><html><head><meta charset="utf-8"><title>Probe</title></head>
<body><div id="out">waiting</div>
<script src="./dreamux.js"></script>
<script type="module">
  await window.dreamux.kv.set('probe', 'hello-from-applet');
  document.getElementById('out').textContent = await window.dreamux.kv.get('probe');
</script></body></html>
```

4. `openApplet {slug: "probe"}`, then **poll (≤15s)** `<project>/.dreamux/appdata/probe/kv.json` until it contains `"hello-from-applet"` — this asserts the full chain: scheme handler served the page → JS ran → bridge gated `kv` → data store wrote. (Webview pixels are NOT capturable in-process; the disk probe is the assertion.)
5. Screenshot the window (APPS section row + host chrome visible; webview area blank is expected — note it in the scenario docstring).
6. **Negative gate check:** rewrite the probe page's module script to

   ```js
   try {
     await window.dreamux.shell.exec('echo x');
     await window.dreamux.kv.set('gate', 'LEAKED');
   } catch {
     await window.dreamux.kv.set('gate', 'denied');
   }
   ```

   with `manifest.json` still declaring only `["kv"]`, `openApplet` again, and poll kv.json until `"gate"` appears — assert its value is `"denied"` (the undeclared `shell` call was rejected; `kv` still works).
7. **Adopt/remove flows** (spec §Testing): the driver writes a minimal library applet (`manifest.json` + `index.html` + `dreamux.js` copied from the scaffold) into `$DREAMUX_APPS_ROOT/lib-probe/`; `adoptApplet {slug: "lib-probe"}` → `appletsState` shows it in `projectApplets` with `adopted == true`; then `removeApplet {slug: "lib-probe"}` → gone from `appletsState`, folder and `appdata` dir absent on disk (poll ≤5s).
8. `PROTOCOL.md`: document all five commands + the blank-webview caveat.

- [ ] **Step 1: Implement commands + scenario.**
- [ ] **Step 2: Run** — `python3 Scripts/e2e/driver.py applets` (match the existing invocation convention in `driver.py`'s `__main__`). Expect PASS; grep the real summary line, never trust a piped exit code.
- [ ] **Step 3: Full `swift test` + `swift build`.**
- [ ] **Step 4: Commit** — `git commit -m "Applets e2e: createApplet/openApplet/appletsState + bridge round-trip scenario"`

---

## Final gate (whole-feature)

- [ ] Full `swift test` green; `python3 Scripts/e2e/driver.py applets` green; one existing scenario (e.g. `overview`) re-run green (no regression from the SidebarMode/Sidebar changes).
- [ ] `./Scripts/make-app.sh debug && open ./Dreamux.app` — manual pass: create → agent builds with live preview → feedback in agent pane → Done → applet is a tool; adopt from App Studio; remove; publish.
- [ ] README: add a short "Applets & App Studio" section (what they are, where they live on disk, the bridge capabilities list).
- [ ] Push to main only after the user has eyeballed the UI.

## Deferred (spec §Deferred — do NOT build)

Marketplace; adoption sync (pull/push via `origin.hash`); `spawn` sidecars; entitled capabilities (`screen-capture`/`input` — ScreenCaptureKit/CGEventTap + TCC); applets as workspace tabs; React/Vite applet type; user-registered capabilities. Each has its seam named in the spec.
