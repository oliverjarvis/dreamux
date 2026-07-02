import XCTest
@testable import Dreamux

@MainActor
final class PlanRunLedgerTests: XCTestCase {
    private var sandbox: TestSandbox!
    private var project: Project!

    override func setUpWithError() throws {
        sandbox = try TestSandbox()
        project = try sandbox.makeProject(named: "demo")
    }
    override func tearDown() { sandbox?.destroy(); sandbox = nil }

    func testRecordPersistsAcrossReload() {
        let ledger = PlanRunLedger(project: project)
        ledger.record(planPath: "docs/plans/a.md", featureName: "a")
        XCTAssertEqual(ledger.recordForPlan("docs/plans/a.md")?.featureName, "a")

        let reloaded = PlanRunLedger(project: project)
        XCTAssertEqual(reloaded.recordForPlan("docs/plans/a.md")?.featureName, "a")
    }

    func testRecordReplacesSamePlan() {
        let ledger = PlanRunLedger(project: project)
        ledger.record(planPath: "docs/plans/a.md", featureName: "a")
        ledger.record(planPath: "docs/plans/a.md", featureName: "a-retry")
        XCTAssertEqual(ledger.records.count, 1)
        XCTAssertEqual(ledger.recordForPlan("docs/plans/a.md")?.featureName, "a-retry")
    }

    func testReconcilePrunesAbandonedButKeepsCompleted() {
        let ledger = PlanRunLedger(project: project)
        ledger.record(planPath: "docs/plans/abandoned.md", featureName: "abandoned")
        ledger.record(planPath: "docs/plans/done.md", featureName: "done")
        ledger.record(planPath: "docs/plans/live.md", featureName: "live")

        ledger.reconcile(
            existingFeatureNames: ["live"],
            isPlanComplete: { $0 == "docs/plans/done.md" }
        )

        XCTAssertNil(ledger.recordForPlan("docs/plans/abandoned.md"))
        XCTAssertNotNil(ledger.recordForPlan("docs/plans/done.md"))
        XCTAssertNotNil(ledger.recordForPlan("docs/plans/live.md"))
    }
}
