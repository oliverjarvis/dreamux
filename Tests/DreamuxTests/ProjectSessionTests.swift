import XCTest
@testable import Dreamux

/// The contract that fixes the "switching projects kills my terminals"
/// bug: bundles are cached per project id, fully wired at construction,
/// and the terminal NSView is session-owned so its ghostty surface can
/// never die with a SwiftUI teardown.
@MainActor
final class ProjectSessionTests: XCTestCase {
    var sandbox: TestSandbox!

    override func setUpWithError() throws {
        sandbox = try TestSandbox()
    }

    override func tearDown() { sandbox?.destroy(); sandbox = nil }

    // MARK: - Registry identity

    func testRegistryReturnsSameBundleForSameProject() throws {
        let project = try sandbox.makeProject(named: "alpha")
        let registry = ProjectSessionRegistry()

        let first = registry.session(for: project)
        let second = registry.session(for: project)

        XCTAssertTrue(first === second,
                      "switch-back must reuse the live bundle, not rebuild it")
    }

    func testRegistryKeepsDistinctBundlesPerProject() throws {
        let alpha = try sandbox.makeProject(named: "alpha")
        let beta = try sandbox.makeProject(named: "beta")
        let registry = ProjectSessionRegistry()

        let alphaSession = registry.session(for: alpha)
        let betaSession = registry.session(for: beta)

        XCTAssertFalse(alphaSession === betaSession)
        XCTAssertTrue(registry.session(for: alpha) === alphaSession,
                      "visiting another project must not evict the first bundle")
    }

    // MARK: - Bundle wiring

    func testBundleWiresPlanQueueStatusAtConstruction() throws {
        let project = try sandbox.makeProject(named: "alpha")
        let planPath = "docs/plans/2026-07-03-x.md"
        let url = project.rootPath.appendingPathComponent(planPath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try """
        # X Implementation Plan
        ### Task 1: a
        - [ ] **Step 1: t**
        """.write(to: url, atomically: true, encoding: .utf8)

        let session = ProjectSession(project: project)

        // The queue's closures used to be wired in ContentView's
        // init/onAppear — a queue polling before the view appeared saw
        // the no-op defaults (statusForPlan == nil for everything).
        XCTAssertNotNil(session.planQueue.statusForPlan(planPath),
                        "statusForPlan must reach the bundle's DocStore")
    }

    func testDocStoreRefreshAutoEnqueuesWaitingPlan() throws {
        let project = try sandbox.makeProject(named: "alpha")

        func writePlan(_ relativePath: String, _ contents: String) throws {
            let url = project.rootPath.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }
        try writePlan("docs/plans/2026-07-04-blocker.md", """
        # Blocker Implementation Plan
        ### Task 1: a
        - [ ] **Step 1: t**
        """)
        try writePlan("docs/plans/2026-07-04-waiter.md", """
        # Waiter Implementation Plan

        **Runs:** after docs/plans/2026-07-04-blocker.md

        ### Task 1: a
        - [ ] **Step 1: t**
        """)

        let session = ProjectSession(project: project)
        // The bundle wires DocStore.onRefresh to intake enactment; a scan
        // of a never-run blocker leaves the waiter appended (the caption,
        // not the queue slot, carries "after" while the blocker is idle).
        session.docStore.refresh()

        XCTAssertEqual(session.planQueue.entries, ["docs/plans/2026-07-04-waiter.md"])
    }

    func testRequestMergeParksWorkspaceOnGateChannel() throws {
        let project = try sandbox.makeProject(named: "alpha")
        let session = ProjectSession(project: project)
        let workspace = session.store.registerFeature(
            name: "feature-x",
            featureDirectory: project.rootPath.appendingPathComponent("features/feature-x"),
            linkedRepoIDs: []
        )

        session.planQueue.requestMerge("feature-x")

        XCTAssertEqual(session.pendingGateMergeWorkspaceID, workspace.id)
    }

    func testRequestMergeIgnoresUnknownFeature() throws {
        let project = try sandbox.makeProject(named: "alpha")
        let session = ProjectSession(project: project)

        session.planQueue.requestMerge("no-such-feature")

        XCTAssertNil(session.pendingGateMergeWorkspaceID)
    }

    func testCloseChannelParksAndClearsWorkspace() throws {
        let project = try sandbox.makeProject(named: "alpha")
        let session = ProjectSession(project: project)
        let workspace = session.store.registerFeature(
            name: "feature-x",
            featureDirectory: project.rootPath.appendingPathComponent("features/feature-x"),
            linkedRepoIDs: []
        )

        // The plan-row Close action parks the target here; WorkspaceSidebar's
        // confirm-alert owner adopts and clears it — the same set/consume
        // handoff `pendingGateMergeWorkspaceID` uses for merge.
        XCTAssertNil(session.pendingCloseWorkspaceID)
        session.pendingCloseWorkspaceID = workspace.id
        XCTAssertEqual(session.pendingCloseWorkspaceID, workspace.id)
        session.pendingCloseWorkspaceID = nil
        XCTAssertNil(session.pendingCloseWorkspaceID)
    }

    func testBootstrapIsOneShot() throws {
        let project = try sandbox.makeProject(named: "alpha")
        let session = ProjectSession(project: project)

        session.bootstrapIfNeeded()
        let firstLoad = session.store.didLoadFeatures
        // Second appear (project switch-back) must be a no-op — it must
        // not schedule another reload over live workspaces.
        session.bootstrapIfNeeded()

        // Nothing observable should change synchronously; the guard is
        // what we're testing (didBootstrap flips on the first call).
        XCTAssertEqual(session.store.didLoadFeatures, firstLoad)
    }

    // MARK: - Session-owned terminal view

    func testTerminalViewIsStableAndBoundToItsSurfaceState() {
        let tab = TabSession()

        let first = tab.terminalView
        let second = tab.terminalView

        XCTAssertTrue(first === second,
                      "remounts must reattach the same NSView, not build a fresh surface")
        XCTAssertTrue(first.controller === tab.viewState.controller)
    }
}
