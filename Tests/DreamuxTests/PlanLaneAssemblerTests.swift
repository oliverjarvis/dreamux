import XCTest
@testable import Dreamux

/// `PlanLaneAssembler.inputs(docStore:queue:store:)` is the hoisted,
/// shared home for what was ContentView's `planLaneInputs()` glue — this
/// exercises the fixture idiom `PlanQueueControllerTests`/`DocStoreTests`
/// use (a `TestSandbox` project, a plan doc written to disk, `DocStore`
/// refresh) to confirm the assembled `PlanLaneInput`s match what the
/// Flows pane and the e2e `flowsState` command both now read.
@MainActor
final class PlanLaneAssemblerTests: XCTestCase {
    private var sandbox: TestSandbox!
    private var project: Project!

    override func setUpWithError() throws {
        sandbox = try TestSandbox()
        project = try sandbox.makeProject(named: "demo")
    }
    override func tearDown() { sandbox?.destroy(); sandbox = nil }

    private func write(_ relative: String, _ contents: String) throws {
        let url = project.rootPath.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    func testEnqueuedReadyPlanAssemblesQueuedInputWithNoWorkspace() throws {
        try write("docs/plans/2026-07-05-widget.md", """
        # Widget Implementation Plan
        ### Task 1: a
        - [ ] **Step 1: t**
        - [ ] **Step 2: u**
        """)
        let docStore = DocStore(project: project)
        docStore.refresh()
        let path = docStore.relativePath(of: docStore.plans[0])

        let queue = PlanQueueController(project: project)
        queue.enqueue(path)
        let store = WorkspaceStore()

        let inputs = PlanLaneAssembler.inputs(docStore: docStore, queue: queue, store: store)
        XCTAssertEqual(inputs.count, 1)
        let input = try XCTUnwrap(inputs.first)
        XCTAssertEqual(input.planPath, path)
        XCTAssertEqual(input.status, .ready, "never run — no ledger record")
        XCTAssertEqual(input.queueOrdinal, 1)
        XCTAssertEqual(input.phases, [PlanPhaseSummary(title: "tasks", checkedSteps: 0, totalSteps: 2)])
        XCTAssertNil(input.workspaceID, "no worktree registered for this feature")
        XCTAssertNil(input.startedAt)
    }

    func testRunningPlanWithLedgerRecordSetsStartedAtAndStatus() throws {
        try write("docs/plans/2026-07-05-gadget.md", """
        # Gadget Implementation Plan
        ### Task 1: a
        - [x] **Step 1: t**
        - [ ] **Step 2: u**
        """)
        let docStore = DocStore(project: project)
        docStore.refresh()
        let path = docStore.relativePath(of: docStore.plans[0])
        docStore.ledger.record(planPath: path, featureName: "gadget")
        let expectedStartedAt = try XCTUnwrap(docStore.ledger.recordForPlan(path)?.startedAt)

        let store = WorkspaceStore()
        let workspace = store.registerFeature(
            name: "gadget",
            featureDirectory: project.rootPath.appendingPathComponent("features/gadget"),
            linkedRepoIDs: [])
        let queue = PlanQueueController(project: project)

        let inputs = PlanLaneAssembler.inputs(docStore: docStore, queue: queue, store: store)
        XCTAssertEqual(inputs.count, 1)
        let input = try XCTUnwrap(inputs.first)
        XCTAssertEqual(input.status, .running, "ledger record + live feature, boxes not all checked")
        XCTAssertEqual(input.startedAt, expectedStartedAt)
        XCTAssertEqual(input.workspaceID, workspace.id)
    }
}
