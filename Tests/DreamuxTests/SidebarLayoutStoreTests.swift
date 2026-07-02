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

    @MainActor
    func testPlansExpandedPersists() throws {
        let store = SidebarLayoutStore(project: project)
        XCTAssertTrue(store.plansExpanded, "expanded by default")
        store.plansExpanded = false
        let reloaded = SidebarLayoutStore(project: project)
        XCTAssertFalse(reloaded.plansExpanded)
    }
}
