import XCTest
@testable import Dreamux

/// The auto-run half of intake (spec: Decisions §1) plus the `after`
/// caption — the pure pieces of Task 5, table-tested without a live session.
/// `shouldAutoRun` is the decision; `enactAutoRun` adds the edge-trigger
/// (fire at most once per plan); `afterCaption` is the sidebar caption.
@MainActor
final class IntakeAutoRunTests: XCTestCase {
    /// Parse a PlanDoc straight from markdown — no files needed, since the
    /// predicates read only the parsed doc, an injected status, and the
    /// toggle.
    private func planDoc(
        _ name: String, parallel: Bool = false, runsAfter: String? = nil
    ) -> PlanDoc {
        var lines = ["# \(name) Implementation Plan", ""]
        if parallel { lines += ["**Runs:** parallel", ""] }
        if let runsAfter { lines += ["**Runs:** after \(runsAfter)", ""] }
        lines += ["### Task 1: work", "- [ ] **Step 1: do it**"]
        return PlanDoc.parse(
            fileURL: URL(fileURLWithPath: "/p/docs/plans/\(name)"),
            contents: lines.joined(separator: "\n"))
    }

    // MARK: - shouldAutoRun table

    func testAutoRunsWhenAllConditionsHold() {
        let plan = planDoc("2026-07-04-x.md", parallel: true)
        XCTAssertTrue(IntakeEnactment.shouldAutoRun(doc: plan, status: .ready, toggleOn: true))
    }

    func testToggleOffNeverAutoRuns() {
        let plan = planDoc("2026-07-04-x.md", parallel: true)
        XCTAssertFalse(IntakeEnactment.shouldAutoRun(doc: plan, status: .ready, toggleOn: false))
    }

    func testNonPlanKindNeverAutoRuns() {
        // A spec (by `-design` suffix, prose only) that carries a parallel
        // header parses `declaresParallel`, but only PLAN-kind docs auto-run.
        let spec = PlanDoc.parse(
            fileURL: URL(fileURLWithPath: "/p/docs/specs/2026-07-04-thing-design.md"),
            contents: """
            # Thing Design
            **Runs:** parallel
            Prose only, no tasks.
            """)
        XCTAssertEqual(spec.kind, .spec)
        XCTAssertTrue(spec.declaresParallel)
        XCTAssertFalse(IntakeEnactment.shouldAutoRun(doc: spec, status: .ready, toggleOn: true))
    }

    func testNoParallelHeaderNeverAutoRuns() {
        // A plain plan (no `**Runs:**` header) stays manual even with the
        // toggle on — absence is not the explicit parallel disposition.
        let plan = planDoc("2026-07-04-x.md")
        XCTAssertFalse(plan.declaresParallel)
        XCTAssertFalse(IntakeEnactment.shouldAutoRun(doc: plan, status: .ready, toggleOn: true))
    }

    func testNotReadyNeverAutoRuns() {
        // A parallel plan that has already run (`.running`) must not relaunch.
        let plan = planDoc("2026-07-04-x.md", parallel: true)
        XCTAssertFalse(IntakeEnactment.shouldAutoRun(doc: plan, status: .running, toggleOn: true))
    }

    func testRunsAfterBlockerNeverAutoRuns() {
        // A waiter (`**Runs:** after …`) is enqueued behind its blocker, not
        // auto-run — even were a stray parallel header also present.
        let waiter = planDoc("2026-07-04-x.md", runsAfter: "docs/plans/2026-07-04-blocker.md")
        XCTAssertFalse(waiter.declaresParallel)
        XCTAssertFalse(IntakeEnactment.shouldAutoRun(doc: waiter, status: .ready, toggleOn: true))
    }

    // MARK: - enactAutoRun edge-trigger

    func testEnactAutoRunLaunchesEligiblePlanOnce() {
        let plan = planDoc("2026-07-04-x.md", parallel: true)
        var enacted: Set<String> = []
        var launched: [String] = []
        let launch: (PlanDoc) -> Void = { launched.append($0.fileURL.lastPathComponent) }

        IntakeEnactment.enactAutoRun(
            docs: [plan], toggleOn: true,
            relativePath: { $0.fileURL.lastPathComponent },
            status: { _ in .ready }, enacted: &enacted, launch: launch)
        XCTAssertEqual(launched, ["2026-07-04-x.md"], "the eligible parallel plan launches")

        // Next refresh: still ready + parallel + toggle on, but the pair has
        // enacted — it must NOT relaunch (edge-triggered off `enacted`).
        IntakeEnactment.enactAutoRun(
            docs: [plan], toggleOn: true,
            relativePath: { $0.fileURL.lastPathComponent },
            status: { _ in .ready }, enacted: &enacted, launch: launch)
        XCTAssertEqual(launched, ["2026-07-04-x.md"], "auto-run fires at most once per plan")
    }

    func testResetToReadyDoesNotRelaunch() {
        let plan = planDoc("2026-07-04-x.md", parallel: true)
        var enacted: Set<String> = []
        var launched: [String] = []
        let launch: (PlanDoc) -> Void = { launched.append($0.fileURL.lastPathComponent) }

        // Auto-run, then the plan goes running, then it is reset back to
        // `.ready` (worktree closed, ledger record lost). The enacted record
        // — not the live status — is the trigger, so it never relaunches.
        IntakeEnactment.enactAutoRun(
            docs: [plan], toggleOn: true,
            relativePath: { $0.fileURL.lastPathComponent },
            status: { _ in .ready }, enacted: &enacted, launch: launch)
        IntakeEnactment.enactAutoRun(
            docs: [plan], toggleOn: true,
            relativePath: { $0.fileURL.lastPathComponent },
            status: { _ in .ready }, enacted: &enacted, launch: launch)
        XCTAssertEqual(launched, ["2026-07-04-x.md"], "a reset plan is never relaunched")
    }

    func testToggleOffEnactsNothing() {
        let plan = planDoc("2026-07-04-x.md", parallel: true)
        var enacted: Set<String> = []
        var launched: [String] = []
        IntakeEnactment.enactAutoRun(
            docs: [plan], toggleOn: false,
            relativePath: { $0.fileURL.lastPathComponent },
            status: { _ in .ready }, enacted: &enacted,
            launch: { launched.append($0.fileURL.lastPathComponent) })
        XCTAssertTrue(launched.isEmpty, "no launch while the toggle is off")
        XCTAssertTrue(enacted.isEmpty, "and nothing is recorded — turning it on later still fires")
    }

    // MARK: - afterCaption

    func testAfterCaptionResolvedTitle() {
        let caption = IntakeEnactment.afterCaption(
            runsAfter: "docs/plans/2026-07-04-queue.md") { _ in "Queue Rework" }
        XCTAssertEqual(caption, "after Queue Rework")
    }

    func testAfterCaptionMissingUsesFilename() {
        let caption = IntakeEnactment.afterCaption(
            runsAfter: "docs/plans/2026-07-04-ghost.md") { _ in nil }
        XCTAssertEqual(caption, "after 2026-07-04-ghost.md (missing)")
    }

    func testAfterCaptionNilWhenNoRunsAfter() {
        XCTAssertNil(IntakeEnactment.afterCaption(runsAfter: nil) { _ in "unused" })
    }
}
