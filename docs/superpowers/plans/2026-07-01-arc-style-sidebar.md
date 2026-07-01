# Arc-style project sidebar Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restyle the project sidebar Arc-style — Signals + a new Web Browser tile in a drag-reorderable pinned grid, Features as flat drag-reorderable tabs with "Add Feature" on top, an editable address bar inside web tabs, and per-project order persistence.

**Architecture:** New model types (`SidebarTile`, `SidebarLayoutStore`) own the pinned-tile set and persist tile+feature order to `‹project›/.dreamux/sidebar.json`. A reusable `ReorderDropDelegate` (mirroring Bonsplit's `TabDropDelegate`) drives live drag-reorder for both the grid and the feature list. `WebTabSession` gains navigation state so the existing web-tab header becomes a working browser bar. Wiring flows `ProjectWindow → ContentView → WorkspaceSidebar`.

**Tech Stack:** Swift, SwiftUI, SwiftPM, XCTest, WebKit (`WKWebView`), the vendored Bonsplit tabbed-split library. macOS app (`@MainActor @Observable` stores).

## Global Constraints

- Product name is **Dreamux**. Module/target is `Dreamux`; tests target is `DreamuxTests`.
- Tests use **XCTest** (`import XCTest` + `@testable import Dreamux`), classes `final class NameTests: XCTestCase`, methods `func testX()`.
- Run tests with `swift test`; a single class with `swift test --filter <ClassName>`.
- Filesystem tests MUST route through `TestSandbox` (`Tests/DreamuxTests/Support/TestSandbox.swift`); never touch real `~/Documents` / Application Support. Get a temp-rooted `Project` from `try sandbox.makeProject(named:)`.
- Stores are `@MainActor @Observable`; tests exercising them mark the test method `@MainActor`.
- Per-project JSON is written like `ProjectStore.save()`: `JSONEncoder` with `.prettyPrinted, .sortedKeys`, `.write(to:options:.atomic)`, creating `‹project›/.dreamux/` first with `withIntermediateDirectories: true`.
- Per-project state dir is `‹project›/.dreamux/` (already holds `run.toml`). New file: `‹project›/.dreamux/sidebar.json`.
- Browser homepage is hardcoded to `https://www.google.com`.
- Drag-reorder mirrors `vendor/bonsplit/.../TabBarView.swift`: `.onDrag { NSItemProvider(object: <string> as NSString) }`, `.onDrop(of: [.text], delegate:)`, `DropProposal(operation: .move)`. Requires `import UniformTypeIdentifiers` in views using `.text`.
- SwiftUI views are verified by `swift build` + manual run (this codebase has no view-test infrastructure); only pure logic gets XCTest.

---

### Task 1: `SidebarTile` model

**Files:**
- Create: `Sources/Dreamux/Models/SidebarTile.swift`
- Test: `Tests/DreamuxTests/SidebarTileTests.swift`

**Interfaces:**
- Produces: `enum SidebarTile: String, Codable, CaseIterable, Identifiable` with cases `.signals`, `.browser`; `var id: String`; `var symbol: String`; `var tint: Color`; `var label: String`. Canonical `allCases` order is `[.signals, .browser]`.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/DreamuxTests/SidebarTileTests.swift
import XCTest
import SwiftUI
@testable import Dreamux

final class SidebarTileTests: XCTestCase {
    func testCanonicalOrder() {
        XCTAssertEqual(SidebarTile.allCases, [.signals, .browser])
    }

    func testRawValuesAreStableForPersistence() {
        XCTAssertEqual(SidebarTile.signals.rawValue, "signals")
        XCTAssertEqual(SidebarTile.browser.rawValue, "browser")
        XCTAssertEqual(SidebarTile.signals.id, "signals")
    }

    func testDisplayMetadata() {
        XCTAssertEqual(SidebarTile.signals.symbol, "waveform.path.ecg")
        XCTAssertEqual(SidebarTile.signals.label, "Signals")
        XCTAssertEqual(SidebarTile.browser.symbol, "globe")
        XCTAssertEqual(SidebarTile.browser.label, "Browser")
    }

    func testCodableRoundTrip() throws {
        let data = try JSONEncoder().encode([SidebarTile.browser, .signals])
        let decoded = try JSONDecoder().decode([SidebarTile].self, from: data)
        XCTAssertEqual(decoded, [.browser, .signals])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter SidebarTileTests`
Expected: FAIL — `cannot find 'SidebarTile' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
// Sources/Dreamux/Models/SidebarTile.swift
import SwiftUI

/// A pinned tile in the project sidebar's Arc-style grid. Built-in and
/// enumerable — reorder is persisted by raw value in `sidebar.json`.
enum SidebarTile: String, Codable, CaseIterable, Identifiable {
    case signals
    case browser

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .signals: return "waveform.path.ecg"
        case .browser: return "globe"
        }
    }

    var tint: Color {
        switch self {
        case .signals: return .purple
        case .browser: return .blue
        }
    }

    var label: String {
        switch self {
        case .signals: return "Signals"
        case .browser: return "Browser"
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter SidebarTileTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/Dreamux/Models/SidebarTile.swift Tests/DreamuxTests/SidebarTileTests.swift
git commit -m "Add SidebarTile model for the pinned sidebar grid"
```

---

### Task 2: Reorder helper + drop delegate

**Files:**
- Create: `Sources/Dreamux/Views/ReorderSupport.swift`
- Test: `Tests/DreamuxTests/ReorderTests.swift`

**Interfaces:**
- Produces:
  - `enum Reorder { static func moved<Item: Identifiable>(_ items: [Item], draggingID: Item.ID, overID: Item.ID) -> [Item] }` — returns `items` with the dragged item moved to the hovered item's slot (SwiftUI `Array.move` semantics); returns `items` unchanged when ids match or aren't found.
  - `struct ReorderDropDelegate<Item: Identifiable>: DropDelegate` with members `let item: Item`, `@Binding var items: [Item]`, `@Binding var dragging: Item?`, `var onReorder: () -> Void`. Live-reorders on `dropEntered`; clears `dragging` and calls `onReorder()` on `performDrop`.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/DreamuxTests/ReorderTests.swift
import XCTest
@testable import Dreamux

private struct Item: Identifiable, Equatable { let id: String }

final class ReorderTests: XCTestCase {
    private let items = [Item(id: "A"), Item(id: "B"), Item(id: "C")]

    func testMoveFirstOntoLast() {
        let out = Reorder.moved(items, draggingID: "A", overID: "C").map(\.id)
        XCTAssertEqual(out, ["B", "C", "A"])
    }

    func testMoveLastOntoFirst() {
        let out = Reorder.moved(items, draggingID: "C", overID: "A").map(\.id)
        XCTAssertEqual(out, ["C", "A", "B"])
    }

    func testMoveAdjacentSwaps() {
        let out = Reorder.moved(items, draggingID: "A", overID: "B").map(\.id)
        XCTAssertEqual(out, ["B", "A", "C"])
    }

    func testSameItemIsNoOp() {
        XCTAssertEqual(Reorder.moved(items, draggingID: "B", overID: "B"), items)
    }

    func testUnknownIdIsNoOp() {
        XCTAssertEqual(Reorder.moved(items, draggingID: "Z", overID: "A"), items)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ReorderTests`
Expected: FAIL — `cannot find 'Reorder' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
// Sources/Dreamux/Views/ReorderSupport.swift
import SwiftUI

/// Pure array-move used by `ReorderDropDelegate` (and unit-tested on its
/// own). Moves the dragged item into the hovered item's slot using
/// SwiftUI's `Array.move(fromOffsets:toOffset:)` semantics.
enum Reorder {
    static func moved<Item: Identifiable>(
        _ items: [Item],
        draggingID: Item.ID,
        overID: Item.ID
    ) -> [Item] {
        guard draggingID != overID,
              let from = items.firstIndex(where: { $0.id == draggingID }),
              let to = items.firstIndex(where: { $0.id == overID })
        else { return items }
        var copy = items
        copy.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        return copy
    }
}

/// Reusable live drag-reorder delegate — mirrors Bonsplit's
/// `TabDropDelegate`. Attach one per row/tile: as a drag hovers a
/// sibling, the array reorders under an animation ("stuff moves around
/// as you move it"); `onReorder` fires once on drop to persist.
struct ReorderDropDelegate<Item: Identifiable>: DropDelegate {
    let item: Item
    @Binding var items: [Item]
    @Binding var dragging: Item?
    var onReorder: () -> Void = {}

    func dropEntered(info: DropInfo) {
        guard let dragging else { return }
        let reordered = Reorder.moved(items, draggingID: dragging.id, overID: item.id)
        guard !reordered.map(\.id).elementsEqual(items.map(\.id)) else { return }
        withAnimation(.easeInOut(duration: 0.18)) { items = reordered }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        onReorder()
        return true
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter ReorderTests`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/Dreamux/Views/ReorderSupport.swift Tests/DreamuxTests/ReorderTests.swift
git commit -m "Add reusable Reorder helper and ReorderDropDelegate"
```

---

### Task 3: `SidebarLayoutStore` persistence + ordering

**Files:**
- Create: `Sources/Dreamux/Models/SidebarLayoutStore.swift`
- Test: `Tests/DreamuxTests/SidebarLayoutStoreTests.swift`

**Interfaces:**
- Consumes: `SidebarTile` (Task 1); `Project`, `Workspace` (existing).
- Produces: `@MainActor @Observable final class SidebarLayoutStore`
  - `init(project: Project)` — loads `‹project›/.dreamux/sidebar.json` or defaults.
  - `var tiles: [SidebarTile]` — reconciled so every `SidebarTile.allCases` value is present (missing ones appended in canonical order).
  - `private(set) var featureOrder: [String]`
  - `func ordered(_ discovered: [Workspace]) -> [Workspace]` — known names first in saved order, unknown names appended alphabetically; rewrites `featureOrder` to the result and saves.
  - `func setFeatureOrder(_ names: [String])` — saves if changed.
  - `func persistTiles()` — saves current `tiles`.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/DreamuxTests/SidebarLayoutStoreTests.swift
import XCTest
import SwiftUI
@testable import Dreamux

final class SidebarLayoutStoreTests: XCTestCase {
    private var sandbox: TestSandbox!
    private var project: Project!

    override func setUpWithError() throws {
        sandbox = try TestSandbox()
        project = try sandbox.makeProject(named: "proj")
    }

    override func tearDown() {
        sandbox?.destroy()
        sandbox = nil
        project = nil
    }

    private func feature(_ name: String) -> Workspace {
        Workspace(name: name, symbol: "s", tint: .blue, workingDirectory: nil, linkedRepoIDs: ["r"])
    }

    @MainActor func testDefaultsWhenNoFile() {
        let store = SidebarLayoutStore(project: project)
        XCTAssertEqual(store.tiles, SidebarTile.allCases)
        XCTAssertEqual(store.featureOrder, [])
    }

    @MainActor func testOrderedAppliesSavedOrderThenAppendsNewAlphabetically() {
        let store = SidebarLayoutStore(project: project)
        store.setFeatureOrder(["b", "a"])
        let out = store.ordered([feature("a"), feature("b"), feature("c")])
        XCTAssertEqual(out.map(\.name), ["b", "a", "c"])
        XCTAssertEqual(store.featureOrder, ["b", "a", "c"])
    }

    @MainActor func testOrderedDropsVanishedNames() {
        let store = SidebarLayoutStore(project: project)
        store.setFeatureOrder(["a", "b", "gone"])
        let out = store.ordered([feature("a"), feature("b")])
        XCTAssertEqual(out.map(\.name), ["a", "b"])
        XCTAssertEqual(store.featureOrder, ["a", "b"])
    }

    @MainActor func testFeatureOrderPersistsAcrossReload() {
        let first = SidebarLayoutStore(project: project)
        first.setFeatureOrder(["x", "y"])
        let reloaded = SidebarLayoutStore(project: project)
        XCTAssertEqual(reloaded.featureOrder, ["x", "y"])
    }

    @MainActor func testTileOrderPersistsAcrossReload() {
        let first = SidebarLayoutStore(project: project)
        first.tiles = [.browser, .signals]
        first.persistTiles()
        let reloaded = SidebarLayoutStore(project: project)
        XCTAssertEqual(reloaded.tiles, [.browser, .signals])
    }

    @MainActor func testMissingTilesAreReconciledOnLoad() {
        // Simulate an old file that only pinned Signals.
        let dir = project.rootPath.appendingPathComponent(".dreamux", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let json = #"{"features":[],"tiles":["signals"]}"#
        try? json.write(to: dir.appendingPathComponent("sidebar.json"), atomically: true, encoding: .utf8)

        let store = SidebarLayoutStore(project: project)
        XCTAssertEqual(store.tiles, [.signals, .browser])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter SidebarLayoutStoreTests`
Expected: FAIL — `cannot find 'SidebarLayoutStore' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
// Sources/Dreamux/Models/SidebarLayoutStore.swift
import Foundation
import Observation

/// Per-project sidebar arrangement — the pinned-tile order and the
/// feature (Work Item) order — persisted to `‹project›/.dreamux/
/// sidebar.json` next to `run.toml`. Mirrors the JSON-atomic-write
/// pattern used by `ProjectStore`.
@MainActor
@Observable
final class SidebarLayoutStore {
    var tiles: [SidebarTile]
    private(set) var featureOrder: [String]

    @ObservationIgnored private let configURL: URL

    init(project: Project) {
        configURL = project.rootPath
            .appendingPathComponent(".dreamux", isDirectory: true)
            .appendingPathComponent("sidebar.json")
        let loaded = Self.load(from: configURL)
        tiles = Self.reconcile(loaded?.tiles ?? SidebarTile.allCases)
        featureOrder = loaded?.features ?? []
    }

    /// Order discovered features by the saved list: known names first in
    /// saved order, unknown names appended alphabetically. Records the
    /// resulting order so freshly-discovered features stick next launch.
    func ordered(_ discovered: [Workspace]) -> [Workspace] {
        var rank: [String: Int] = [:]
        for (i, name) in featureOrder.enumerated() { rank[name] = i }
        let known = discovered
            .filter { rank[$0.name] != nil }
            .sorted { rank[$0.name]! < rank[$1.name]! }
        let unknown = discovered
            .filter { rank[$0.name] == nil }
            .sorted { $0.name < $1.name }
        let result = known + unknown
        setFeatureOrder(result.map(\.name))
        return result
    }

    func setFeatureOrder(_ names: [String]) {
        guard names != featureOrder else { return }
        featureOrder = names
        save()
    }

    func persistTiles() {
        save()
    }

    // MARK: - Persistence

    private struct Payload: Codable {
        var tiles: [SidebarTile]
        var features: [String]
    }

    /// Keep saved tile order but guarantee every built-in tile is present
    /// (a tile added in a later app version won't be in an old file).
    private static func reconcile(_ saved: [SidebarTile]) -> [SidebarTile] {
        var result = saved
        for tile in SidebarTile.allCases where !result.contains(tile) {
            result.append(tile)
        }
        return result
    }

    private static func load(from url: URL) -> Payload? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Payload.self, from: data)
    }

    private func save() {
        let payload = Payload(tiles: tiles, features: featureOrder)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(payload) else { return }
        try? FileManager.default.createDirectory(
            at: configURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: configURL, options: .atomic)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter SidebarLayoutStoreTests`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/Dreamux/Models/SidebarLayoutStore.swift Tests/DreamuxTests/SidebarLayoutStoreTests.swift
git commit -m "Add SidebarLayoutStore for per-project tile and feature order"
```

---

### Task 4: `WorkspaceStore` ordering integration

**Files:**
- Modify: `Sources/Dreamux/Models/WorkspaceStore.swift` (add `layout` property ~line 8; edit `reloadFeatures` ~lines 149-151; add `persistFeatureOrder`)
- Test: `Tests/DreamuxTests/WorkspaceOrderingTests.swift`

**Interfaces:**
- Consumes: `SidebarLayoutStore` (Task 3).
- Produces on `WorkspaceStore`:
  - `var layout: SidebarLayoutStore?` — set by the window at startup.
  - `func persistFeatureOrder()` — writes the current linked-feature order (orphans excluded) via `layout`.
  - `reloadFeatures` orders discovered features through `layout?.ordered(_:)` when a layout is set.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/DreamuxTests/WorkspaceOrderingTests.swift
import XCTest
import SwiftUI
@testable import Dreamux

final class WorkspaceOrderingTests: XCTestCase {
    private var sandbox: TestSandbox!
    private var project: Project!

    override func setUpWithError() throws {
        sandbox = try TestSandbox()
        project = try sandbox.makeProject(named: "proj")
    }

    override func tearDown() {
        sandbox?.destroy(); sandbox = nil; project = nil
    }

    private func feature(_ name: String) -> Workspace {
        Workspace(name: name, symbol: "s", tint: .blue, workingDirectory: nil, linkedRepoIDs: ["r"])
    }

    private func orphan(_ name: String) -> Workspace {
        Workspace(name: name, symbol: "s", tint: .blue, workingDirectory: nil, linkedRepoIDs: [])
    }

    @MainActor func testPersistFeatureOrderRecordsLinkedNamesOnly() {
        let store = WorkspaceStore()
        store.layout = SidebarLayoutStore(project: project)
        store.workspaces = [feature("a"), feature("b"), orphan("scratch")]

        store.persistFeatureOrder()

        XCTAssertEqual(store.layout?.featureOrder, ["a", "b"])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter WorkspaceOrderingTests`
Expected: FAIL — `value of type 'WorkspaceStore' has no member 'layout'`.

- [ ] **Step 3: Write minimal implementation**

In `Sources/Dreamux/Models/WorkspaceStore.swift`, add the property just below `var workspaces: [Workspace]` (line 8):

```swift
    var workspaces: [Workspace]
    /// Per-project sidebar arrangement. Set by the window at startup;
    /// drives feature ordering on reload and persistence on drag-reorder.
    var layout: SidebarLayoutStore?
```

In `reloadFeatures`, replace the merge (currently lines 149-151):

```swift
        // Keep orphan workspaces (no linked repos) — they're transient
        // shells the user opened that don't correspond to any worktree.
        let orphans = workspaces.filter { $0.linkedRepoIDs.isEmpty }
        let merged = discovered + orphans
        workspaces = merged
```

with:

```swift
        // Keep orphan workspaces (no linked repos) — they're transient
        // shells the user opened that don't correspond to any worktree.
        let orphans = workspaces.filter { $0.linkedRepoIDs.isEmpty }
        let ordered = layout?.ordered(discovered) ?? discovered
        let merged = ordered + orphans
        workspaces = merged
```

Add this method (place it right after `reloadFeatures`, before `addWorkspace`):

```swift
    /// Persist the current feature order after a drag-reorder. Only
    /// linked features are recorded; orphan shells stay session-only and
    /// always render after the linked features.
    func persistFeatureOrder() {
        layout?.setFeatureOrder(workspaces.filter { !$0.linkedRepoIDs.isEmpty }.map(\.name))
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter WorkspaceOrderingTests`
Expected: PASS (1 test).

- [ ] **Step 5: Commit**

```bash
git add Sources/Dreamux/Models/WorkspaceStore.swift Tests/DreamuxTests/WorkspaceOrderingTests.swift
git commit -m "Order and persist features via SidebarLayoutStore in WorkspaceStore"
```

---

### Task 5: `WebTabSession` navigation

**Files:**
- Modify: `Sources/Dreamux/Models/WebTabSession.swift`
- Test: `Tests/DreamuxTests/WebTabNavigationTests.swift`

**Interfaces:**
- Produces on `WebTabSession`:
  - `nonisolated static func resolveNavigation(_ input: String) -> URL?` — `http(s)` URL passes through; host-like input (no spaces, contains ".") gets `https://`; empty → nil; else Google search.
  - `var currentURL: URL`, `var canGoBack: Bool`, `var canGoForward: Bool` (observed from the web view).
  - `func navigate(to input: String)`, `func goBack()`, `func goForward()`.
  - `url` stays the immutable identity/dedup key; `openExternally()` now opens `currentURL`.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/DreamuxTests/WebTabNavigationTests.swift
import XCTest
@testable import Dreamux

final class WebTabNavigationTests: XCTestCase {
    func testSchemeURLPassesThrough() {
        XCTAssertEqual(
            WebTabSession.resolveNavigation("https://reddit.com/r/swift")?.absoluteString,
            "https://reddit.com/r/swift"
        )
    }

    func testHostLikeInputGetsHTTPS() {
        XCTAssertEqual(
            WebTabSession.resolveNavigation("reddit.com")?.absoluteString,
            "https://reddit.com"
        )
    }

    func testFreeTextBecomesGoogleSearch() {
        let url = WebTabSession.resolveNavigation("claude code")
        XCTAssertEqual(url?.host, "www.google.com")
        XCTAssertEqual(url?.path, "/search")
        XCTAssertEqual(url?.query?.contains("claude"), true)
    }

    func testEmptyInputReturnsNil() {
        XCTAssertNil(WebTabSession.resolveNavigation("   "))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter WebTabNavigationTests`
Expected: FAIL — `type 'WebTabSession' has no member 'resolveNavigation'`.

- [ ] **Step 3: Write minimal implementation**

Replace the whole body of `Sources/Dreamux/Models/WebTabSession.swift` with:

```swift
import AppKit
import Foundation
import Observation
import WebKit

/// State behind one in-app browser tab. Runners' `open` URLs land here
/// (instead of bouncing the user out to an external browser) so each
/// worktree's running app lives as a tab inside its own workspace,
/// right next to the terminals working on it. The header (see
/// `WebTabView`) is a working browser bar driven by this session.
@MainActor
@Observable
final class WebTabSession: Identifiable {
    let id = UUID()
    /// URL this tab was opened for. Also the dedup key: pressing play
    /// again re-selects the existing tab rather than stacking a new one.
    let url: URL

    /// The live location, kept in sync with the web view as the user
    /// navigates. Drives the address bar.
    var currentURL: URL
    var canGoBack = false
    var canGoForward = false

    @ObservationIgnored private var _webView: WKWebView?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []

    var webView: WKWebView {
        if let _webView { return _webView }
        let configuration = WKWebViewConfiguration()
        let view = WKWebView(frame: .zero, configuration: configuration)
        // Safari's Web Inspector (Develop menu) — a dev tool pointed at
        // the user's own dev server; inspectability is the point.
        view.isInspectable = true
        observeNavigation(view)
        view.load(URLRequest(url: url))
        _webView = view
        return view
    }

    init(url: URL) {
        self.url = url
        self.currentURL = url
    }

    func reload() { _webView?.reload() }
    func goBack() { _webView?.goBack() }
    func goForward() { _webView?.goForward() }

    /// Navigate to a typed address: a real URL, a bare host, or (as a
    /// fallback) a Google search — Chrome/Arc omnibox behavior.
    func navigate(to input: String) {
        guard let target = Self.resolveNavigation(input) else { return }
        webView.load(URLRequest(url: target))
    }

    /// Escape hatch to a real browser — the current page, external
    /// default handler.
    func openExternally() {
        NSWorkspace.shared.open(currentURL)
    }

    nonisolated static func resolveNavigation(_ input: String) -> URL? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let url = URL(string: trimmed), let scheme = url.scheme,
           scheme == "http" || scheme == "https" {
            return url
        }
        if !trimmed.contains(" "), trimmed.contains("."),
           let url = URL(string: "https://\(trimmed)") {
            return url
        }
        var comps = URLComponents(string: "https://www.google.com/search")!
        comps.queryItems = [URLQueryItem(name: "q", value: trimmed)]
        return comps.url
    }

    // MARK: - Navigation observation

    private func observeNavigation(_ view: WKWebView) {
        observations = [
            view.observe(\.url, options: [.new]) { [weak self] webView, _ in
                let url = webView.url
                let back = webView.canGoBack
                let forward = webView.canGoForward
                Task { @MainActor in self?.apply(url: url, back: back, forward: forward) }
            },
            view.observe(\.canGoBack, options: [.new]) { [weak self] webView, _ in
                let back = webView.canGoBack
                Task { @MainActor in self?.canGoBack = back }
            },
            view.observe(\.canGoForward, options: [.new]) { [weak self] webView, _ in
                let forward = webView.canGoForward
                Task { @MainActor in self?.canGoForward = forward }
            },
        ]
    }

    private func apply(url: URL?, back: Bool, forward: Bool) {
        if let url { currentURL = url }
        canGoBack = back
        canGoForward = forward
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter WebTabNavigationTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/Dreamux/Models/WebTabSession.swift Tests/DreamuxTests/WebTabNavigationTests.swift
git commit -m "Give WebTabSession navigation state and address resolution"
```

---

### Task 6: Web tab browser bar (`WebTabView`)

**Files:**
- Modify: `Sources/Dreamux/Views/WorkspaceTerminalContainer.swift` (the `WebTabView` struct, lines 69-113)

**Interfaces:**
- Consumes: `WebTabSession` navigation API (Task 5).
- Produces: no new public API — a view change. Verified by build + manual run.

- [ ] **Step 1: Replace the `WebTabView` struct**

Replace the `WebTabView` struct (lines 69-113) with:

```swift
/// An in-app browser tab: a working browser bar (back/forward, reload,
/// editable address field, escape hatch to the external browser) over a
/// WKWebView. Hosts the `open` target of a running worktree so the
/// app-under-development lives next to the terminals working on it.
private struct WebTabView: View {
    @Bindable var session: WebTabSession
    @State private var address: String = ""
    @FocusState private var addressFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                navButton("chevron.left", enabled: session.canGoBack) { session.goBack() }
                    .help("Back")
                navButton("chevron.right", enabled: session.canGoForward) { session.goForward() }
                    .help("Forward")
                navButton("arrow.clockwise", enabled: true) { session.reload() }
                    .help("Reload")

                Image(systemName: "globe")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                TextField("Search or enter address", text: $address)
                    .textFieldStyle(.plain)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.primary)
                    .focused($addressFocused)
                    .onSubmit {
                        session.navigate(to: address)
                        addressFocused = false
                    }

                Button {
                    session.openExternally()
                } label: {
                    Image(systemName: "safari")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Open in external browser")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.bar)

            Divider()

            WebViewRepresentable(webView: session.webView)
        }
        .onAppear { address = session.currentURL.absoluteString }
        .onChange(of: session.currentURL) { _, newURL in
            // Track the live page, but don't fight the user mid-edit.
            if !addressFocused { address = newURL.absoluteString }
        }
    }

    private func navButton(
        _ symbol: String,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? .secondary : .tertiary)
        .disabled(!enabled)
    }
}
```

- [ ] **Step 2: Build**

Run: `swift build`
Expected: builds with no errors.

- [ ] **Step 3: Manual check (deferred to Task 10's run)**

The browser bar is exercised in the end-to-end manual run at the end of the plan. No standalone run needed here.

- [ ] **Step 4: Commit**

```bash
git add Sources/Dreamux/Views/WorkspaceTerminalContainer.swift
git commit -m "Turn the web tab header into an editable browser bar"
```

---

### Task 7: `PinnedTileGrid` view

**Files:**
- Create: `Sources/Dreamux/Views/PinnedTileGrid.swift`

**Interfaces:**
- Consumes: `SidebarTile` (Task 1), `ReorderDropDelegate` (Task 2).
- Produces: `struct PinnedTileGrid: View` with initializer parameters
  `tiles: Binding<[SidebarTile]>`, `isSelected: @escaping (SidebarTile) -> Bool`,
  `isEnabled: @escaping (SidebarTile) -> Bool`, `onTap: @escaping (SidebarTile) -> Void`,
  `onReorder: @escaping () -> Void`.

- [ ] **Step 1: Write the implementation**

```swift
// Sources/Dreamux/Views/PinnedTileGrid.swift
import SwiftUI
import UniformTypeIdentifiers

/// Arc-style pinned tiles at the top of the project sidebar: a 2-column
/// grid of square icon buttons, drag-reorderable. Currently holds
/// Signals + Web Browser; grows to a full 2×2+ as more tiles are pinned.
struct PinnedTileGrid: View {
    @Binding var tiles: [SidebarTile]
    let isSelected: (SidebarTile) -> Bool
    let isEnabled: (SidebarTile) -> Bool
    let onTap: (SidebarTile) -> Void
    let onReorder: () -> Void

    @State private var dragging: SidebarTile?

    private let columns = [
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8),
    ]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 8) {
            ForEach(tiles) { tile in
                tileButton(tile)
                    .opacity(dragging == tile ? 0.4 : 1)
                    .onDrag {
                        dragging = tile
                        return NSItemProvider(object: tile.rawValue as NSString)
                    }
                    .onDrop(of: [.text], delegate: ReorderDropDelegate(
                        item: tile,
                        items: $tiles,
                        dragging: $dragging,
                        onReorder: onReorder
                    ))
            }
        }
    }

    private func tileButton(_ tile: SidebarTile) -> some View {
        let selected = isSelected(tile)
        let enabled = isEnabled(tile)
        return Button {
            onTap(tile)
        } label: {
            VStack {
                Image(systemName: tile.symbol)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(tile.tint)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(selected ? tile.tint.opacity(0.18) : Color.primary.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(
                        selected ? tile.tint.opacity(0.5) : Color.primary.opacity(0.06),
                        lineWidth: 1
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .help(tile.label)
    }
}
```

- [ ] **Step 2: Build**

Run: `swift build`
Expected: builds with no errors.

- [ ] **Step 3: Commit**

```bash
git add Sources/Dreamux/Views/PinnedTileGrid.swift
git commit -m "Add PinnedTileGrid — the Arc-style pinned sidebar tiles"
```

---

### Task 8: Inject `SidebarLayoutStore` through the window

**Files:**
- Modify: `Sources/Dreamux/Views/ProjectWindow.swift` (`ProjectWindowContents`)
- Modify: `Sources/Dreamux/Views/ContentView.swift` (add `layout` param, forward it)

**Interfaces:**
- Consumes: `SidebarLayoutStore` (Task 3), `WorkspaceStore.layout` (Task 4).
- Produces: `ContentView.init` gains `layout: SidebarLayoutStore`; `WorkspaceSidebar` receives `layout:` (added in Task 9). `store.layout` is set before `reloadFeatures` runs.

- [ ] **Step 1: Add the store to `ProjectWindowContents`**

In `Sources/Dreamux/Views/ProjectWindow.swift`, add a `@State` property after `repoStore` (line 36):

```swift
    @State private var store: WorkspaceStore
    @State private var repoStore: RepoStore
    @State private var layout: SidebarLayoutStore
```

In its `init`, after the `_repoStore` line (line 49):

```swift
        _repoStore = State(initialValue: RepoStore(project: project))
        _layout = State(initialValue: SidebarLayoutStore(project: project))
```

Pass `layout` into `ContentView` in `body` (after `repoStore: repoStore,` at line 55):

```swift
        ContentView(
            store: store,
            repoStore: repoStore,
            layout: layout,
            projects: projects,
            currentProjectID: project.id,
            onSwitchProject: onSwitchProject
        )
```

In the `.onAppear` (line 60), set `store.layout` before the reload Task:

```swift
        .onAppear {
            store.layout = layout
            // Remember where the user was so the next launch can land
            // here instead of the Home grid.
            LastOpenedProject.record(project.id)
```

- [ ] **Step 2: Thread `layout` through `ContentView`**

In `Sources/Dreamux/Views/ContentView.swift`, add a stored property after `repoStore` (line 16):

```swift
    @Bindable var store: WorkspaceStore
    @Bindable var repoStore: RepoStore
    let layout: SidebarLayoutStore
```

Add the parameter to `init` (after `repoStore:` at line 29) and assign it:

```swift
    init(
        store: WorkspaceStore,
        repoStore: RepoStore,
        layout: SidebarLayoutStore,
        projects: ProjectStore,
        currentProjectID: UUID,
        onSwitchProject: @escaping (UUID?) -> Void
    ) {
        self.store = store
        self.repoStore = repoStore
        self.layout = layout
        self.projects = projects
```

Pass it into `WorkspaceSidebar` in `body` (the `content:` closure, after `runners: runners,` at line 81) — this compiles after Task 9 adds the parameter:

```swift
            WorkspaceSidebar(
                store: store,
                repoStore: repoStore,
                runners: runners,
                layout: layout,
                sidebarMode: $sidebarMode
            )
```

- [ ] **Step 3: Build**

Run: `swift build`
Expected: FAIL — `WorkspaceSidebar` has no `layout:` parameter yet. This is expected; Task 9 adds it. (If you prefer a green build here, do Task 9 before building.)

- [ ] **Step 4: Commit (with Task 9)**

Do not commit a non-building tree. Proceed to Task 9, then build and commit both together as directed in Task 9's final step.

---

### Task 9: Sidebar grid + browser tile

**Files:**
- Modify: `Sources/Dreamux/Views/WorkspaceSidebar.swift`

**Interfaces:**
- Consumes: `SidebarLayoutStore` (Task 3), `PinnedTileGrid` (Task 7), `WorkspaceSession.openWebTab(url:title:)` (existing), `store.activeWorkspace` (existing).
- Produces: `WorkspaceSidebar` gains `@Bindable var layout: SidebarLayoutStore`; the pinned card is replaced by the grid; a hardcoded `browserHomepage`; `handleTileTap`/`openBrowserTab`.

- [ ] **Step 1: Add imports and the layout property**

At the top of `Sources/Dreamux/Views/WorkspaceSidebar.swift`, add after `import SwiftUI`:

```swift
import SwiftUI
import UniformTypeIdentifiers
```

Add the property after `@Binding var sidebarMode: SidebarMode` (line 11):

```swift
    @Bindable var runners: RunnerManager
    @Bindable var layout: SidebarLayoutStore
    @Binding var sidebarMode: SidebarMode
```

- [ ] **Step 2: Swap the pinned card for the grid**

In `content` (line 117), replace:

```swift
            card { signalsRow }
```

with:

```swift
            PinnedTileGrid(
                tiles: $layout.tiles,
                isSelected: { $0 == .signals && sidebarMode == .signals },
                isEnabled: { tile in tile == .browser ? !store.workspaces.isEmpty : true },
                onTap: handleTileTap,
                onReorder: { layout.persistTiles() }
            )
```

- [ ] **Step 3: Delete `signalsRow`, add the tile actions**

Delete the entire `signalsRow` computed property (lines 157-181).

Add these members (place them right after the `content` property, before `signalsRow`'s old location):

```swift
    private static let browserHomepage = URL(string: "https://www.google.com")!

    private func handleTileTap(_ tile: SidebarTile) {
        switch tile {
        case .signals:
            sidebarMode = .signals
        case .browser:
            openBrowserTab()
        }
    }

    /// Open a fresh browser tab (hardcoded homepage) in the active
    /// feature's pane, switching to it. Web tabs live inside a feature's
    /// Bonsplit pane, so this needs a workspace to land in — the grid
    /// tile is disabled when there are none.
    private func openBrowserTab() {
        guard let workspace = store.activeWorkspace ?? store.workspaces.first else { return }
        store.activate(workspace.id)
        sidebarMode = .workspace
        store.session(for: workspace).openWebTab(url: Self.browserHomepage, title: "New Tab")
    }
```

- [ ] **Step 4: Build**

Run: `swift build`
Expected: builds with no errors (this also resolves Task 8's expected failure).

- [ ] **Step 5: Commit (Tasks 8 + 9 together)**

```bash
git add Sources/Dreamux/Views/ProjectWindow.swift Sources/Dreamux/Views/ContentView.swift Sources/Dreamux/Views/WorkspaceSidebar.swift
git commit -m "Replace Signals card with the pinned tile grid + Browser tile"
```

---

### Task 10: Features as reorderable Arc tabs

**Files:**
- Modify: `Sources/Dreamux/Views/WorkspaceSidebar.swift`

**Interfaces:**
- Consumes: `ReorderDropDelegate` (Task 2), `store.persistFeatureOrder()` (Task 4).
- Produces: flat feature rows with drag-reorder, `addFeatureButton` above the list, a `draggingWorkspace` state and a `workspacesBinding` helper. View change — verified by build + manual run.

- [ ] **Step 1: Add drag state and a workspaces binding**

Add after the `customizing` state property (near line 27):

```swift
    /// Feature currently being dragged for reorder.
    @State private var draggingWorkspace: Workspace?
```

Add this computed helper (near the other private vars, e.g. after `hasNoFeaturesOrRepos`):

```swift
    private var workspacesBinding: Binding<[Workspace]> {
        Binding(get: { store.workspaces }, set: { store.workspaces = $0 })
    }
```

- [ ] **Step 2: Restyle the Features section (flat tabs, Add Feature on top, drag-reorder)**

In `content` (lines 119-146), replace the Features `VStack` block:

```swift
            VStack(alignment: .leading, spacing: 6) {
                sectionLabel("Features")
                switchNoticeIfAny
                if hasNoFeaturesOrRepos {
                    emptyFeaturesText
                } else {
                    card {
                        VStack(spacing: 0) {
                            ForEach(Array(store.workspaces.enumerated()), id: \.element.id) { index, workspace in
                                if index > 0 {
                                    Divider().padding(.leading, 46)
                                }
                                featureRow(workspace) { featureRowBody(workspace) }
                            }
                            // Separator between the feature rows and the
                            // Add Feature button — only when there are rows
                            // above it, otherwise it renders as an orphaned
                            // inset line at the top of the card.
                            if !store.workspaces.isEmpty {
                                Divider().padding(.leading, 46)
                            }
                            addFeatureButton
                                .padding(.horizontal, 2)
                                .padding(.vertical, 2)
                        }
                    }
                }
            }
```

with:

```swift
            VStack(alignment: .leading, spacing: 4) {
                sectionLabel("Features")
                switchNoticeIfAny
                addFeatureButton
                if hasNoFeaturesOrRepos {
                    emptyFeaturesText
                } else {
                    VStack(spacing: 2) {
                        ForEach(store.workspaces) { workspace in
                            featureRow(workspace) { featureRowBody(workspace) }
                                .onDrag {
                                    draggingWorkspace = workspace
                                    return NSItemProvider(object: workspace.id.uuidString as NSString)
                                }
                                .onDrop(of: [.text], delegate: ReorderDropDelegate(
                                    item: workspace,
                                    items: workspacesBinding,
                                    dragging: $draggingWorkspace,
                                    onReorder: { store.persistFeatureOrder() }
                                ))
                        }
                    }
                }
            }
```

- [ ] **Step 3: Build**

Run: `swift build`
Expected: builds with no errors.

- [ ] **Step 4: Full test suite**

Run: `swift test`
Expected: PASS — all existing tests plus the new `SidebarTileTests`, `ReorderTests`, `SidebarLayoutStoreTests`, `WorkspaceOrderingTests`, `WebTabNavigationTests`.

- [ ] **Step 5: Manual verification**

Launch the app (per the project's run flow), open a project with at least one feature, and confirm:
1. Signals + Browser show as square tiles in the grid; dragging one reorders them and the order survives relaunch.
2. Clicking Browser opens a `google.com` web tab in the active feature; the address bar navigates (type `reddit.com`, type a search term), back/forward/reload work, and the bar tracks the page.
3. Feature rows are flat Arc-style tabs; "+ Add Feature" sits above them; dragging a feature reorders live and the order survives relaunch (check `‹project›/.dreamux/sidebar.json`).

- [ ] **Step 6: Commit**

```bash
git add Sources/Dreamux/Views/WorkspaceSidebar.swift
git commit -m "Render features as reorderable Arc-style tabs"
```

---

## Notes for the implementer

- `Workspace` has a memberwise initializer with defaults for `id` (`UUID()`) and `linkedRepoIDs` (`[]`); the tests call `Workspace(name:symbol:tint:workingDirectory:linkedRepoIDs:)`.
- `WorkspaceSession.openWebTab(url:title:)` already exists and creates a globe-icon Bonsplit tab backed by a `WebTabSession`; the browser tile just calls it.
- Do not touch the Repositories section, the `card(_:)` helper (still used elsewhere), or `softBadge` (used by `featureRowBody`).
- Keep commits building; Task 8 intentionally leaves the tree non-building until Task 9 — commit them together.
