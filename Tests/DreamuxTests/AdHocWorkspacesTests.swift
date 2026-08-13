import XCTest
@testable import Dreamux

/// The plan-backed/ad-hoc partition pulled out of `WorkspaceSidebar`: for
/// every plan in every initiative, the feature it runs as (ledger name,
/// else filename-derived branch). Table-tested without the view, mirroring
/// `PlanWorkspacePresenceTests`.
final class AdHocWorkspacesTests: XCTestCase {
    private func plan(_ fileName: String) -> PlanDoc {
        PlanDoc(
            fileURL: URL(fileURLWithPath: "/p/docs/plans/\(fileName)"),
            kind: .plan, title: fileName, date: nil, goal: nil,
            specReference: nil, checkedSteps: 0, totalSteps: 0, tasks: [])
    }

    private func initiative(_ plans: [PlanDoc]) -> Initiative {
        Initiative(id: plans.first?.title ?? "i", title: "I",
                   spec: nil, plans: plans, supportingDocs: [])
    }

    private func record(_ featureName: String) -> PlanRunRecord {
        PlanRunRecord(planPath: "", featureName: featureName, startedAt: Date())
    }

    // MARK: featureName(for:record:)

    func testFeatureNameFallsBackToFilenameBranchWhenUnrun() {
        let p = plan("2026-07-04-widget.md")
        XCTAssertEqual(
            AdHocWorkspaces.featureName(for: p, record: { _ in nil }), "widget")
    }

    func testFeatureNamePrefersLedgerRecordOverFilename() {
        let p = plan("2026-07-04-widget.md")
        XCTAssertEqual(
            AdHocWorkspaces.featureName(for: p, record: { _ in self.record("widget-v2") }),
            "widget-v2")
    }

    // MARK: planBackedFeatureNames(in:record:)

    func testUnrunPlanContributesFilenameDerivedBranch() {
        let set = AdHocWorkspaces.planBackedFeatureNames(
            in: [initiative([plan("2026-07-04-gameboy.md")])], record: { _ in nil })
        XCTAssertEqual(set, ["gameboy"])
    }

    func testPhaseSuffixSurvivesInTheDerivedBranch() {
        // `branchName` keeps a `phase-N` segment (only `familyKey` drops it),
        // so a phased plan's feature name is the phased branch.
        let set = AdHocWorkspaces.planBackedFeatureNames(
            in: [initiative([plan("2026-07-02-beta-phase-1.md")])], record: { _ in nil })
        XCTAssertEqual(set, ["beta-phase-1"])
    }

    func testNamesUnionAcrossInitiativesAndPlans() {
        let a = plan("2026-07-01-alpha.md")
        let b = plan("2026-07-02-beta.md")
        let c = plan("2026-07-03-gamma.md")
        let set = AdHocWorkspaces.planBackedFeatureNames(
            in: [initiative([a, b]), initiative([c])],
            record: { $0.fileURL.lastPathComponent.contains("gamma") ? self.record("gamma-run") : nil })
        XCTAssertEqual(set, ["alpha", "beta", "gamma-run"])
    }

    func testEmptyInitiativesYieldEmptySet() {
        XCTAssertTrue(AdHocWorkspaces.planBackedFeatureNames(
            in: [], record: { _ in nil }).isEmpty)
    }

    // MARK: deletesBranchOnClose(workspaceName:planBacked:)

    func testPlanBackedWorkspaceKeepsTheDestructiveClose() {
        // Its branch exists because a plan run made it, so abandoning the
        // run shouldn't leave the branch behind.
        let planBacked = AdHocWorkspaces.planBackedFeatureNames(
            in: [initiative([plan("2026-08-13-widget.md")])], record: { _ in nil })
        XCTAssertTrue(AdHocWorkspaces.deletesBranchOnClose(
            workspaceName: "widget", planBacked: planBacked))
    }

    func testAnOpenedBranchClosesWithoutDeletingTheBranch() {
        // Nothing plans against `fix/retry-backoff` — it was OPENED, quite
        // possibly to review someone else's work, so the branch outlives
        // its worktree. Derived from plan documents, so it needs no
        // persistence and survives relaunch and project moves.
        let planBacked = AdHocWorkspaces.planBackedFeatureNames(
            in: [initiative([plan("2026-08-13-widget.md")])], record: { _ in nil })
        XCTAssertFalse(AdHocWorkspaces.deletesBranchOnClose(
            workspaceName: "fix/retry-backoff", planBacked: planBacked))
    }

    func testALedgerRenamedFeatureStillCountsAsPlanBacked() {
        // The ledger name wins over the filename, so a plan run on a
        // renamed branch keeps its destructive close.
        let planBacked = AdHocWorkspaces.planBackedFeatureNames(
            in: [initiative([plan("2026-08-13-widget.md")])],
            record: { _ in self.record("widget-v2") })
        XCTAssertTrue(AdHocWorkspaces.deletesBranchOnClose(
            workspaceName: "widget-v2", planBacked: planBacked))
        XCTAssertFalse(AdHocWorkspaces.deletesBranchOnClose(
            workspaceName: "widget", planBacked: planBacked))
    }
}
