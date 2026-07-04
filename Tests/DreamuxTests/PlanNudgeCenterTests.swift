import XCTest
@testable import Dreamux

/// The nudge delivery engine: a state machine that parks a per-plan
/// nudge and delivers it into the feature's live agent only when the
/// plan is not gated and the agent is quiescent. Every terminal-touching
/// effect (quiescence probe, the echo-verified send) is an injected
/// closure, so these tests drive the machine without a real PTY.
@MainActor
final class PlanNudgeCenterTests: XCTestCase {
    private func parse(_ contents: String,
                       path: String = "docs/plans/2026-07-04-x.md") -> PlanDoc {
        PlanDoc.parse(fileURL: URL(fileURLWithPath: "/p/\(path)"), contents: contents)
    }

    private let oneTask = """
    # X Implementation Plan
    ### Task 1: a
    - [ ] **Step 1: t**
    """

    // MARK: - State machine

    func testParksWhileAgentIsBusy() {
        let center = PlanNudgeCenter()
        var sent: [String] = []
        center.status = { _ in .running }
        center.isQuiescent = { _ in false }
        center.send = { _, prompt in sent.append(prompt) }
        center.enqueue(planPath: "p", featureName: "f", prompt: "hi", createdAt: Date())

        center.deliverPending()

        XCTAssertTrue(sent.isEmpty, "a streaming agent keeps the nudge parked")
        XCTAssertEqual(center.pending.count, 1)
    }

    func testDeliversOnceQuiescent() {
        let center = PlanNudgeCenter()
        var sent: [String] = []
        var quiescent = false
        center.status = { _ in .running }
        center.isQuiescent = { _ in quiescent }
        center.send = { _, prompt in sent.append(prompt) }
        center.enqueue(planPath: "p", featureName: "f", prompt: "hi", createdAt: Date())

        center.deliverPending()
        XCTAssertTrue(sent.isEmpty)

        quiescent = true
        center.deliverPending()
        XCTAssertEqual(sent, ["hi"])
        XCTAssertTrue(center.pending.isEmpty, "a delivered nudge is removed")
    }

    func testGateRailParksEvenWhenQuiescent() {
        let center = PlanNudgeCenter()
        var sent: [String] = []
        center.status = { _ in .awaitingReview }   // a plan at a merge gate
        center.isQuiescent = { _ in true }
        center.send = { _, prompt in sent.append(prompt) }
        center.enqueue(planPath: "p", featureName: "f", prompt: "hi", createdAt: Date())

        center.deliverPending()

        XCTAssertTrue(sent.isEmpty, "the gate rail never delivers into an awaiting-review plan")
        XCTAssertEqual(center.pending.count, 1, "the nudge stays parked for a later resume")
    }

    func testUnknownStatusParks() {
        let center = PlanNudgeCenter()
        var sent: [String] = []
        center.status = { _ in nil }               // plan not resolvable
        center.isQuiescent = { _ in true }
        center.send = { _, prompt in sent.append(prompt) }
        center.enqueue(planPath: "p", featureName: "f", prompt: "hi", createdAt: Date())

        center.deliverPending()

        XCTAssertTrue(sent.isEmpty, "an unresolvable plan is never delivered into")
        XCTAssertEqual(center.pending.count, 1)
    }

    func testNoDoubleDelivery() {
        let center = PlanNudgeCenter()
        var sent: [String] = []
        center.status = { _ in .running }
        center.isQuiescent = { _ in true }
        center.send = { _, prompt in sent.append(prompt) }
        center.enqueue(planPath: "p", featureName: "f", prompt: "hi", createdAt: Date())

        center.deliverPending()
        center.deliverPending()

        XCTAssertEqual(sent, ["hi"], "a removed nudge is not re-sent on the next tick")
    }

    func testRemoveOnlyAfterSend() {
        let center = PlanNudgeCenter()
        var quiescent = false
        center.status = { _ in .running }
        center.isQuiescent = { _ in quiescent }
        center.send = { _, _ in }
        center.enqueue(planPath: "p", featureName: "f", prompt: "hi", createdAt: Date())

        center.deliverPending()
        XCTAssertEqual(center.pending.count, 1, "a parked (undelivered) nudge is kept")

        quiescent = true
        center.deliverPending()
        XCTAssertTrue(center.pending.isEmpty, "removal happens only after a send")
    }

    func testEnqueueReplacesParkedNudgeForSamePlan() {
        let center = PlanNudgeCenter()
        center.enqueue(planPath: "p", featureName: "f", prompt: "first", createdAt: Date())
        center.enqueue(planPath: "p", featureName: "f", prompt: "second", createdAt: Date())
        XCTAssertEqual(center.pending.count, 1)
        XCTAssertEqual(center.pending["p"]?.prompt, "second", "the latest instruction wins")
    }

    func testEnqueueRejectsEmptyPath() {
        let center = PlanNudgeCenter()
        center.enqueue(planPath: "", featureName: "f", prompt: "hi", createdAt: Date())
        XCTAssertTrue(center.pending.isEmpty)
    }

    func testDeliversTwoIndependentPlans() {
        let center = PlanNudgeCenter()
        var sent: [String: String] = [:]
        center.status = { _ in .running }
        center.isQuiescent = { _ in true }
        center.send = { path, prompt in sent[path] = prompt }
        center.enqueue(planPath: "a", featureName: "fa", prompt: "A", createdAt: Date())
        center.enqueue(planPath: "b", featureName: "fb", prompt: "B", createdAt: Date())

        center.deliverPending()

        XCTAssertEqual(sent, ["a": "A", "b": "B"])
        XCTAssertTrue(center.pending.isEmpty)
    }

    // MARK: - Appended-task growth detection (pure classifier)

    func testAppendedTaskRangeDetectsSingleIntegrateAppend() {
        let after = parse("""
        # X Implementation Plan
        ### Task 1: a
        - [ ] **Step 1: t**
        ### Task 2: b *(added 2026-07-04)*
        - [ ] **Step 1: u**
        """)
        XCTAssertEqual(
            IntakeGrowthDetector.appendedTaskRange(before: parse(oneTask), after: after),
            "Task 2")
    }

    func testAppendedTaskRangeSpansMultipleAppendedTasks() {
        let after = parse("""
        # X Implementation Plan
        ### Task 1: a
        - [ ] **Step 1: t**
        ### Task 2: b *(added 2026-07-04)*
        - [ ] **Step 1: u**
        ### Task 3: c *(added 2026-07-04)*
        - [ ] **Step 1: v**
        """)
        XCTAssertEqual(
            IntakeGrowthDetector.appendedTaskRange(before: parse(oneTask), after: after),
            "Task 2–Task 3")
    }

    func testCourseCorrectionMarkedGrowthDoesNotNudge() {
        // A fix-task append carries the `*(course correction, …)*` marker —
        // Task 3 nudges those itself, so the integrate detector stays quiet.
        let after = parse("""
        # X Implementation Plan
        ### Task 1: a
        - [ ] **Step 1: t**
        ### Task 1.1: Fix — rope not severed *(course correction, 2026-07-04)*
        - [ ] **Step 1: u**
        """)
        XCTAssertNil(
            IntakeGrowthDetector.appendedTaskRange(before: parse(oneTask), after: after),
            "course-correction growth must not double-nudge")
    }

    func testNoGrowthYieldsNoRange() {
        let doc = parse(oneTask)
        XCTAssertNil(IntakeGrowthDetector.appendedTaskRange(before: doc, after: doc))
    }

    func testCombinedRefreshNudgesOnlyTheUnmarkedAppends() {
        // One refresh coalesces a course-correction fix-task AND two
        // intake-integrate appends. Suppressing on ANY marker would drop
        // the integrate nudge forever (the snapshot advances), so the
        // re-read nudge must fire for exactly the unmarked pair.
        let after = parse("""
        # X Implementation Plan
        ### Task 1: a
        - [ ] **Step 1: t**
        ### Task 1.1: Fix — rope *(course correction, 2026-07-04)*
        - [ ] **Step 1: fix**
        ### Task 2: b *(added 2026-07-04)*
        - [ ] **Step 1: u**
        ### Task 3: c *(added 2026-07-04)*
        - [ ] **Step 1: v**
        """)
        XCTAssertEqual(
            IntakeGrowthDetector.appendedTaskRange(before: parse(oneTask), after: after),
            "Task 2–Task 3",
            "the range covers the unmarked integrate appends, not the fix-task")
    }

    func testStepsAddedToExistingTaskWithoutNewTaskDoesNotNudge() {
        // totalSteps grew, but no NEW task heading appeared — nothing to
        // "re-read and fold in", so no nudge.
        let after = parse("""
        # X Implementation Plan
        ### Task 1: a
        - [ ] **Step 1: t**
        - [ ] **Step 2: extra**
        """)
        XCTAssertNil(IntakeGrowthDetector.appendedTaskRange(before: parse(oneTask), after: after))
    }

    // MARK: - Refresh folding (stateful, running-gated)

    private var twoTasks: String {
        """
        # X Implementation Plan
        ### Task 1: a
        - [ ] **Step 1: t**
        ### Task 2: b *(added 2026-07-04)*
        - [ ] **Step 1: u**
        """
    }

    func testNoteRefreshEnqueuesForRunningPlanOnGrowth() {
        let center = PlanNudgeCenter()
        let path = "docs/plans/2026-07-04-x.md"
        let now = Date(timeIntervalSince1970: 42)

        // First sighting only snapshots — no previous parse to diff against.
        center.noteRefresh(
            docs: [parse(oneTask)], relativePath: { _ in path },
            status: { _ in .running }, featureName: { _ in "x" }, now: { now })
        XCTAssertTrue(center.pending.isEmpty, "the first sighting only records a baseline")

        // Growth on a running plan parks a planUpdated nudge.
        center.noteRefresh(
            docs: [parse(twoTasks)], relativePath: { _ in path },
            status: { _ in .running }, featureName: { _ in "x" }, now: { now })
        let nudge = center.pending[path]
        XCTAssertEqual(nudge?.featureName, "x")
        XCTAssertEqual(nudge?.createdAt, now)
        XCTAssertTrue(nudge?.prompt.contains("Task 2") ?? false)
        XCTAssertTrue(nudge?.prompt.contains(path) ?? false)
    }

    func testNoteRefreshIgnoresNonRunningPlans() {
        let center = PlanNudgeCenter()
        let path = "docs/plans/2026-07-04-x.md"
        center.noteRefresh(
            docs: [parse(oneTask)], relativePath: { _ in path },
            status: { _ in .ready }, featureName: { _ in "x" }, now: { Date() })
        center.noteRefresh(
            docs: [parse(twoTasks)], relativePath: { _ in path },
            status: { _ in .ready }, featureName: { _ in "x" }, now: { Date() })
        XCTAssertTrue(center.pending.isEmpty, "a non-running plan's growth is not nudged")
    }

    func testNoteRefreshNudgesUnmarkedAppendsAlongsideAFixTask() {
        let center = PlanNudgeCenter()
        let path = "docs/plans/2026-07-04-x.md"
        let combined = """
        # X Implementation Plan
        ### Task 1: a
        - [ ] **Step 1: t**
        ### Task 1.1: Fix — rope *(course correction, 2026-07-04)*
        - [ ] **Step 1: fix**
        ### Task 2: b *(added 2026-07-04)*
        - [ ] **Step 1: u**
        """
        center.noteRefresh(
            docs: [parse(oneTask)], relativePath: { _ in path },
            status: { _ in .running }, featureName: { _ in "x" }, now: { Date() })
        center.noteRefresh(
            docs: [parse(combined)], relativePath: { _ in path },
            status: { _ in .running }, featureName: { _ in "x" }, now: { Date() })
        let nudge = center.pending[path]
        XCTAssertNotNil(nudge, "the integrate append still owes a re-read nudge")
        XCTAssertTrue(nudge?.prompt.contains("Task 2") ?? false)
    }

    func testNoteRefreshSuppressesCourseCorrectionGrowth() {
        let center = PlanNudgeCenter()
        let path = "docs/plans/2026-07-04-x.md"
        let fixed = """
        # X Implementation Plan
        ### Task 1: a
        - [ ] **Step 1: t**
        ### Task 1.1: Fix — rope *(course correction, 2026-07-04)*
        - [ ] **Step 1: u**
        """
        center.noteRefresh(
            docs: [parse(oneTask)], relativePath: { _ in path },
            status: { _ in .running }, featureName: { _ in "x" }, now: { Date() })
        center.noteRefresh(
            docs: [parse(fixed)], relativePath: { _ in path },
            status: { _ in .running }, featureName: { _ in "x" }, now: { Date() })
        XCTAssertTrue(center.pending.isEmpty,
                      "the course-correction flow owns its own nudge")
    }
}
