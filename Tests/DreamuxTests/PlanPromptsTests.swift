import XCTest
@testable import Dreamux

final class PlanPromptsTests: XCTestCase {
    func testRunPlanPromptNamesTheFileAndCheckboxContract() {
        let p = PlanPrompts.runPlan(
            planRelativePath: "docs/plans/2026-07-02-x.md", docsLinkName: "docs")
        XCTAssertTrue(p.contains("docs/plans/2026-07-02-x.md"))
        XCTAssertTrue(p.contains("- [ ]"))
        XCTAssertTrue(p.contains("- [x]"))
        XCTAssertTrue(p.contains("task-by-task"))
    }

    func testResumePromptMentionsContinuing() {
        let p = PlanPrompts.resumePlan(
            planRelativePath: "docs/plans/x.md", docsLinkName: "project-docs")
        XCTAssertTrue(p.contains("project-docs/plans/x.md")
                      || p.contains("docs/plans/x.md"))
        XCTAssertTrue(p.lowercased().contains("continue"))
        XCTAssertTrue(p.contains("dreamux-signals"),
                      "agents resuming a plan must also learn the signals MCP exists")
    }

    func testBrainstormKickoffCarriesIdeaAndTargets() {
        let p = PlanPrompts.brainstormKickoff(idea: "make widgets fast")
        XCTAssertTrue(p.contains("make widgets fast"))
        XCTAssertTrue(p.contains("docs/specs/"))
        XCTAssertTrue(p.contains("docs/plans/"))
        XCTAssertTrue(p.contains("brainstorming"))
    }

    func testWritePlanKickoffTargetsSpec() {
        let p = PlanPrompts.writePlanKickoff(specRelativePath: "docs/specs/x-design.md")
        XCTAssertTrue(p.contains("docs/specs/x-design.md"))
        XCTAssertTrue(p.contains("writing-plans"))
    }

    // MARK: - Intake enrichment: byte-identical when the digest is absent

    /// The exact brainstorm kickoff as it shipped before intake. A nil
    /// digest MUST reproduce this verbatim so the New Plan flow on a fresh
    /// project (no plans on record) is unchanged.
    private static let brainstormGolden = """
    You're planning work for this Dreamux project. The folders under ./repos/<repo>/<default-branch>/ are reference checkouts of each repo's default branch — explore them read-only to ground the design; implementation happens later in dedicated worktrees.

    Use your brainstorming skill (superpowers:brainstorming) to turn the idea below into a validated design through dialogue with me. Write the resulting spec to docs/specs/YYYY-MM-DD-<topic>-design.md and, once I approve it, the implementation plan to docs/plans/YYYY-MM-DD-<topic>.md (superpowers:writing-plans). Use those exact folders — they're this project's shared docs home that the app's sidebar reads.

    Idea: make widgets fast
    """

    /// The exact write-plan kickoff as it shipped before intake.
    private static let writePlanGolden = """
    Read docs/specs/x-design.md — an approved design spec in this project's shared docs home. Use your writing-plans skill (superpowers:writing-plans) to produce its implementation plan and save it to docs/plans/ named after the spec (spec filename minus `-design`). The repos under ./repos/<repo>/<default-branch>/ are reference checkouts for grounding exact file paths and code.
    """

    func testBrainstormKickoffNilDigestIsByteIdenticalToPreIntake() {
        XCTAssertEqual(
            PlanPrompts.brainstormKickoff(idea: "make widgets fast"),
            Self.brainstormGolden)
        XCTAssertEqual(
            PlanPrompts.brainstormKickoff(idea: "make widgets fast", intakeDigest: nil),
            Self.brainstormGolden)
    }

    func testWritePlanKickoffNilDigestIsByteIdenticalToPreIntake() {
        XCTAssertEqual(
            PlanPrompts.writePlanKickoff(specRelativePath: "docs/specs/x-design.md"),
            Self.writePlanGolden)
        XCTAssertEqual(
            PlanPrompts.writePlanKickoff(
                specRelativePath: "docs/specs/x-design.md", intakeDigest: nil),
            Self.writePlanGolden)
    }

    // MARK: - Intake enrichment: digest + disposition instructions when present

    private static let sampleDigest = """
    - Snip! renderer — running, docs/plans/2026-07-01-snip.md, feature snip
        · Cut the rope
    queue: docs/plans/2026-07-01-snip.md
    """

    func testBrainstormKickoffEmbedsDigestVerbatim() {
        let p = PlanPrompts.brainstormKickoff(
            idea: "make widgets fast", intakeDigest: Self.sampleDigest)
        // The pre-intake prompt is still fully present (nothing dropped).
        XCTAssertTrue(p.contains("Idea: make widgets fast"))
        XCTAssertTrue(p.contains("superpowers:brainstorming"))
        // The digest rides inside a clearly-labelled block, verbatim.
        XCTAssertTrue(p.contains("Current work in flight"))
        XCTAssertTrue(p.contains(Self.sampleDigest))
    }

    func testWritePlanKickoffEmbedsDigestVerbatim() {
        let p = PlanPrompts.writePlanKickoff(
            specRelativePath: "docs/specs/x-design.md", intakeDigest: Self.sampleDigest)
        XCTAssertTrue(p.contains("writing-plans"))
        XCTAssertTrue(p.contains("Current work in flight"))
        XCTAssertTrue(p.contains(Self.sampleDigest))
    }

    func testDispositionInstructionsCoverAllThreeDispositions() {
        let p = PlanPrompts.brainstormKickoff(
            idea: "x", intakeDigest: Self.sampleDigest)
        // All three dispositions named.
        XCTAssertTrue(p.contains("parallel"))
        XCTAssertTrue(p.contains("wait"))
        XCTAssertTrue(p.contains("integrate"))
        // Enactment for parallel and wait: the `**Runs:**` headers.
        XCTAssertTrue(p.contains("**Runs:** parallel"))
        XCTAssertTrue(p.contains("**Runs:** after"))
        // Enactment for integrate: append a dated task group, no new file.
        XCTAssertTrue(p.contains("### Task N+1"))
        XCTAssertTrue(p.contains("*(added"))
    }

    func testDispositionInstructionsSpellOutTheLowercaseAfterGrammar() {
        let p = PlanPrompts.brainstormKickoff(
            idea: "x", intakeDigest: Self.sampleDigest)
        // The parser is case-sensitive and keys on the .md path token — the
        // instruction must say so, or the agent may write `After <title>`.
        XCTAssertTrue(p.contains("lowercase"))
        XCTAssertTrue(p.contains("case-sensitive"))
        XCTAssertTrue(p.contains(".md"))
        XCTAssertTrue(p.contains("project-relative"))
    }

    func testDispositionInstructionsCarryTheGateRail() {
        let p = PlanPrompts.brainstormKickoff(
            idea: "x", intakeDigest: Self.sampleDigest)
        // Never integrate into a plan at a merge gate or awaiting review.
        XCTAssertTrue(p.lowercased().contains("merge gate"))
        XCTAssertTrue(p.lowercased().contains("awaiting review")
                      || p.lowercased().contains("awaitingreview"))
    }

    func testDispositionInstructionsDemandAFinalSummaryLine() {
        let p = PlanPrompts.brainstormKickoff(
            idea: "x", intakeDigest: Self.sampleDigest)
        XCTAssertTrue(p.contains("Disposition:"))
    }

    // MARK: - Nudge prompts (Task 2)

    /// Fix now interrupts: pause the current task, do the fix, then
    /// resume. Names the plan file; one typed REPL line.
    func testCourseCorrectionFixNowPausesAndResumes() {
        let p = PlanPrompts.courseCorrection(
            taskTitle: "Task 3.1: Fix — rope not severed",
            priority: .now,
            planRelativePath: "docs/plans/2026-07-04-snip.md")
        XCTAssertTrue(p.contains("docs/plans/2026-07-04-snip.md"))
        XCTAssertTrue(p.contains("Task 3.1: Fix — rope not severed"))
        XCTAssertTrue(p.lowercased().contains("pause"))
        XCTAssertTrue(p.lowercased().contains("resume"))
        XCTAssertFalse(p.contains("\n"), "a nudge is a single typed REPL line")
    }

    /// Fix next finishes the current task cleanly, then does the fix
    /// before anything else.
    func testCourseCorrectionFixNextFinishesCurrentFirst() {
        let p = PlanPrompts.courseCorrection(
            taskTitle: "Fix the thing", priority: .next,
            planRelativePath: "docs/plans/x.md")
        XCTAssertTrue(p.contains("docs/plans/x.md"))
        XCTAssertTrue(p.lowercased().contains("finish your current task"))
        XCTAssertTrue(p.lowercased().contains("before anything else"))
        XCTAssertFalse(p.contains("\n"))
    }

    /// Add to queue reaches the fix in document order.
    func testCourseCorrectionAddToQueuePicksUpInOrder() {
        let p = PlanPrompts.courseCorrection(
            taskTitle: "Fix the thing", priority: .queue,
            planRelativePath: "docs/plans/x.md")
        XCTAssertTrue(p.contains("docs/plans/x.md"))
        XCTAssertTrue(p.lowercased().contains("appended"))
        XCTAssertTrue(p.lowercased().contains("document order"))
        XCTAssertFalse(p.contains("\n"))
    }

    /// A multi-line task title collapses to a single line so the whole
    /// nudge stays one typed REPL line.
    func testCourseCorrectionCollapsesMultilineTaskTitle() {
        let p = PlanPrompts.courseCorrection(
            taskTitle: "Fix\n  the   rope\nnow", priority: .next,
            planRelativePath: "docs/plans/x.md")
        XCTAssertTrue(p.contains("Fix the rope now"))
        XCTAssertFalse(p.contains("\n"))
    }

    /// The intake-integrate re-read nudge names the appended range and
    /// the plan file, one typed line.
    func testPlanUpdatedNamesRangeAndFile() {
        let p = PlanPrompts.planUpdated(
            taskRange: "Task 5–Task 7", planRelativePath: "docs/plans/x.md")
        XCTAssertTrue(p.contains("docs/plans/x.md"))
        XCTAssertTrue(p.contains("Task 5–Task 7"))
        XCTAssertTrue(p.lowercased().contains("re-read"))
        XCTAssertTrue(p.lowercased().contains("appended"))
        XCTAssertFalse(p.contains("\n"))
    }
}
