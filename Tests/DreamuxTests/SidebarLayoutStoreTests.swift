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
        XCTAssertTrue(store.appsExpanded, "the Apps section is expanded by default")
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
        first.tiles = [.library, .signals]
        first.persistTiles()
        let reloaded = SidebarLayoutStore(project: project)
        XCTAssertEqual(reloaded.tiles, [.library, .signals, .flows])
    }

    @MainActor func testMissingTilesAreReconciledOnLoad() throws {
        // Simulate an old file that only pinned Signals.
        let dir = project.rootPath.appendingPathComponent(".dreamux", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let json = #"{"features":[],"tiles":["signals"]}"#
        try json.write(to: dir.appendingPathComponent("sidebar.json"),
                       atomically: true, encoding: .utf8)

        let store = SidebarLayoutStore(project: project)
        XCTAssertEqual(store.tiles, [.signals, .flows, .library])
    }

    /// A file written by the pre-retirement app names `"browser"`. Decoding
    /// `tiles` as `[SidebarTile]` would throw on it and fail the WHOLE
    /// payload, silently resetting features / plansExpanded / appsExpanded /
    /// autoRunParallel to defaults. Retired raw values must drop out and
    /// leave every other field intact (spec: "Lenient tile decode").
    @MainActor func testRetiredTileNameDropsWithoutLosingOtherFields() throws {
        let dir = project.rootPath.appendingPathComponent(".dreamux", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let json = """
        {"appsExpanded":false,"autoRunParallel":true,\
        "features":["alpha","beta"],"plansExpanded":false,\
        "tiles":["signals","browser","flows","library"]}
        """
        try json.write(to: dir.appendingPathComponent("sidebar.json"),
                       atomically: true, encoding: .utf8)

        let store = SidebarLayoutStore(project: project)
        XCTAssertEqual(store.tiles, [.signals, .flows, .library],
                       "retired names drop; saved order survives")
        XCTAssertEqual(store.featureOrder, ["alpha", "beta"])
        XCTAssertFalse(store.plansExpanded)
        XCTAssertFalse(store.appsExpanded)
        XCTAssertTrue(store.autoRunParallel)
    }

    /// sidebar.json written before a tile case existed must still show
    /// the new tile after load — union missing cases (append, keeping
    /// the user's saved order for the rest).
    @MainActor func testTilesUnionInMissingCases() throws {
        let dir = project.rootPath.appendingPathComponent(".dreamux", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let json = #"{"features":[],"tiles":["flows","signals"]}"#
        try json.write(to: dir.appendingPathComponent("sidebar.json"),
                       atomically: true, encoding: .utf8)

        let store = SidebarLayoutStore(project: project)
        XCTAssertTrue(store.tiles.contains(.library))
        XCTAssertEqual(Array(store.tiles.prefix(2)), [.flows, .signals],
                       "saved order preserved; new cases appended")
    }

    @MainActor
    func testPlansExpandedPersists() throws {
        let store = SidebarLayoutStore(project: project)
        XCTAssertTrue(store.plansExpanded, "expanded by default")
        store.plansExpanded = false
        let reloaded = SidebarLayoutStore(project: project)
        XCTAssertFalse(reloaded.plansExpanded)
    }

    @MainActor
    func testAutoRunParallelPersists() throws {
        let store = SidebarLayoutStore(project: project)
        XCTAssertFalse(store.autoRunParallel, "auto-run is off by default")
        store.autoRunParallel = true
        let reloaded = SidebarLayoutStore(project: project)
        XCTAssertTrue(reloaded.autoRunParallel, "the toggle round-trips through the config file")
    }
}
