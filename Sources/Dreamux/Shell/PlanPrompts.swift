import Foundation

/// Delivery priority for a course correction (spec: "Phase 2 — course
/// correction" — Fix now / Fix next / Add to queue, default Fix next).
/// Raw values double as the e2e `courseCorrect` command's `priority`
/// tokens (`now|next|queue`).
enum CorrectionPriority: String, CaseIterable, Sendable {
    case now, next, queue

    /// Human label for the sheet's picker (Task 3).
    var label: String {
        switch self {
        case .now: return "Fix now"
        case .next: return "Fix next"
        case .queue: return "Add to queue"
        }
    }
}

/// The prompts Dreamux types into claude sessions for plan work. Kept
/// as pure functions so tests can pin the contract (file paths named,
/// checkbox-ticking instruction present) without a PTY.
enum PlanPrompts {
    /// Kick off execution of a plan inside a freshly provisioned
    /// feature aggregation directory. `autoCommit` mirrors the Settings
    /// "Commit after each task" toggle (`WorkflowSettings.autoCommitEnabled`)
    /// — when false, the agent is left to the plan's own commit
    /// instructions instead of being told to commit every task.
    static func runPlan(
        planRelativePath: String, docsLinkName: String, autoCommit: Bool = true
    ) -> String {
        let autoCommitBullet = Self.autoCommitBullet(autoCommit)
        return """
        You're in a Dreamux feature directory (see DREAMUX.md — each \
        subfolder is a git worktree for one repo; `\(docsLinkName)/` is the \
        shared project docs home).

        Read \(planRelativePath) and implement it task-by-task, \
        following the plan's own execution instructions (the "For agentic \
        workers" header). The contract Dreamux relies on:

        - As you complete each step, edit the plan file itself to tick its \
        checkbox (`- [ ]` → `- [x]`) and save — the app tracks live \
        progress from that file.
        - Commit exactly as the plan's steps direct, inside the relevant \
        repo subfolder.\(autoCommitBullet)
        - The `dreamux-signals` MCP is available: `signals_query` / \
        `signals_recent` read this project's live service logs (useful \
        when a dev server misbehaves), and `signals_emit` records \
        findings the app surfaces in its Signals page.
        - Stop and ask if a step fails rather than improvising around it.

        Begin with Task 1's first unchecked step.
        """
    }

    /// Re-enter a partially executed plan in its existing worktree.
    /// `autoCommit` — see `runPlan`.
    static func resumePlan(
        planRelativePath: String, docsLinkName: String, autoCommit: Bool = true
    ) -> String {
        let autoCommitBullet = Self.autoCommitBullet(autoCommit)
        return """
        You're back in a Dreamux feature directory (see DREAMUX.md; \
        `\(docsLinkName)/` is the shared project docs home). The plan at \
        \(planRelativePath) is partially done — checked boxes (`- [x]`) are \
        complete, unchecked (`- [ ]`) are not. Verify the last checked \
        step's commit exists, then continue from the first unchecked step, \
        ticking checkboxes in the plan file as you go and committing as \
        the plan directs.
        \(autoCommitBullet)
        - The `dreamux-signals` MCP is available: `signals_query` / \
        `signals_recent` read this project's live service logs (useful \
        when a dev server misbehaves), and `signals_emit` records \
        findings the app surfaces in its Signals page.
        """
    }

    /// Start a brainstorming dialogue in the project-scope planning tab.
    ///
    /// `intakeDigest` — when non-nil, the app's snapshot of every
    /// non-merged plan (assembled at send time). Its presence turns the
    /// kickoff into an intake: the agent must disposition the idea against
    /// work already in flight. When nil (a project with no plans on
    /// record), the prompt is byte-for-byte its pre-intake form.
    static func brainstormKickoff(idea: String, intakeDigest: String? = nil) -> String {
        let base = """
        You're planning work for this Dreamux project. The folders under \
        ./repos/<repo>/<default-branch>/ are reference checkouts of each \
        repo's default branch — explore them read-only to ground the \
        design; implementation happens later in dedicated worktrees.

        Use your brainstorming skill (superpowers:brainstorming) to turn \
        the idea below into a validated design through dialogue with me. \
        Write the resulting spec to docs/specs/YYYY-MM-DD-<topic>-design.md \
        and, once I approve it, the implementation plan to \
        docs/plans/YYYY-MM-DD-<topic>.md (superpowers:writing-plans). Use \
        those exact folders — they're this project's shared docs home that \
        the app's sidebar reads.

        Idea: \(idea)
        """
        return withIntake(base, digest: intakeDigest)
    }

    /// Turn an existing spec into a plan. `intakeDigest` behaves exactly as
    /// in `brainstormKickoff`: non-nil enriches the kickoff with the
    /// in-flight snapshot and disposition instructions; nil leaves the
    /// prompt byte-identical to its pre-intake form.
    static func writePlanKickoff(specRelativePath: String, intakeDigest: String? = nil) -> String {
        let base = """
        Read \(specRelativePath) — an approved design spec in this \
        project's shared docs home. Use your writing-plans skill \
        (superpowers:writing-plans) to produce its implementation plan and \
        save it to docs/plans/ named after the spec (spec filename minus \
        `-design`). The repos under ./repos/<repo>/<default-branch>/ are \
        reference checkouts for grounding exact file paths and code.
        """
        return withIntake(base, digest: intakeDigest)
    }

    /// The course-correction nudge typed into a RUNNING plan's live agent
    /// (spec: "Phase 2 — course correction"). One typed REPL line carrying
    /// the chosen delivery priority: Fix now interrupts the current task,
    /// Fix next waits for it to finish, Add to queue reaches the fix in
    /// document order. Names the plan file and the fix-task so the agent
    /// can locate the tracked task the app just wrote. `taskTitle` collapses
    /// to one line — the whole nudge stays a single line the driver types
    /// into the agent's REPL.
    static func courseCorrection(
        taskTitle: String,
        priority: CorrectionPriority,
        planRelativePath: String
    ) -> String {
        let task = collapse(taskTitle)
        switch priority {
        case .now:
            return "Course correction filed in \(planRelativePath): pause your current task, "
                + "do \"\(task)\" first, then resume where you left off."
        case .next:
            return "Course correction filed in \(planRelativePath): finish your current task "
                + "cleanly, then do \"\(task)\" before anything else."
        case .queue:
            return "Course correction filed in \(planRelativePath): a new task \"\(task)\" was "
                + "appended — pick it up in document order after your current work."
        }
    }

    /// The re-read nudge for intake-integrate appends to a RUNNING plan
    /// (spec: "Phase 2 — integrating into a RUNNING plan"). One typed REPL
    /// line naming the plan file and the appended task range; the agent
    /// re-reads the plan and folds the new work into what's left.
    static func planUpdated(taskRange: String, planRelativePath: String) -> String {
        "The plan file \(planRelativePath) has been updated — new tasks were appended "
            + "(\(taskRange)). Re-read the plan and fold them into your remaining work."
    }

    /// The per-task auto-commit contract bullet shared by `runPlan` and
    /// `resumePlan` (single source for this contract text) — empty
    /// string when the Workflow "Commit after each task" toggle is off.
    /// Tells the agent the backstop may have already committed for it:
    /// without this, the "Stop and ask if a step fails" instruction
    /// could park the agent on a `git commit` that fails with "nothing
    /// to commit" because the app's backstop front-ran it.
    private static func autoCommitBullet(_ enabled: Bool) -> String {
        guard enabled else { return "" }
        return "\n- After finishing each task — all its checkboxes ticked — commit the work "
            + "in every repo subfolder you touched: `git add -A && git commit` with the "
            + "commit message set to the task's full heading text (e.g. \"Task 2: Wire the "
            + "store\"). One commit per task per repo. If the commit reports nothing to "
            + "commit, the app's backstop already committed for you — continue, don't stop."
    }

    /// Collapse every run of whitespace (including newlines) to one space
    /// and trim, so a multi-line title becomes a single typed line.
    private static func collapse(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// Append the intake block to a kickoff prompt, or return it unchanged
    /// when there is nothing in flight. Kept append-only so a nil digest is
    /// a no-op — the base prompts above stay the sole source of their
    /// pre-intake bytes.
    private static func withIntake(_ base: String, digest: String?) -> String {
        guard let digest else { return base }
        return base + "\n\n" + intakeGuidance(digest: digest)
    }

    /// The disposition instructions carried alongside the digest. Faithful
    /// to the design spec's "The disposition model" and "How the decision
    /// is made" sections: the agent judges overlap against the fenced
    /// snapshot, then enacts one of parallel / wait / integrate. The
    /// `**Runs:**` grammar note is exact because `PlanDoc` parses it
    /// case-sensitively off the `.md` path token — loose casing or a title
    /// instead of a path silently degrades to plain `ready`.
    private static func intakeGuidance(digest: String) -> String {
        """
        Before writing anything up, decide how this idea relates to work \
        already in flight — don't assume it deserves a brand-new plan of \
        its own. Here is the current work in flight (every non-merged plan \
        on record, with each running plan's touched territory and the \
        queue order):

        --- Current work in flight ---
        \(digest)
        --- end ---

        Judge the idea's scope against that snapshot (you have repo access — \
        use it), pick ONE disposition, and enact it:

        - parallel — the idea has no meaningful overlap with any active \
        plan's territory (different files, different subsystem, no \
        dependency on another plan's outcome). Write a NEW plan file whose \
        header carries the line `**Runs:** parallel`. It lands `ready` and \
        runs in its own worktree.
        - wait — the idea overlaps a running or queued plan's territory \
        (same files, same subsystem, or it depends on that plan's outcome). \
        Write a NEW plan file whose header carries `**Runs:** after \
        <project-relative path to the blocking plan>`, e.g. `**Runs:** \
        after docs/plans/2026-07-01-snip.md`. Grammar is strict: the exact \
        lowercase word `after` then ONLY the path — the app parses this \
        case-sensitively and keys on the `.md` path token, so `After`, a \
        plan title instead of a path, or trailing prose in place of the \
        path will not be recognized (it degrades to a plain ready plan). \
        The app then auto-enqueues the new plan behind its blocker.
        - integrate — the idea isn't really a new plan, it's more work for \
        an existing, unfinished plan. Do NOT write a new file. Instead \
        APPEND a clearly-marked task group to that plan's own file, \
        continuing its task numbering: `### Task N+1: <title> *(added \
        <today's date>)*`. NEVER integrate into a plan that is at a merge \
        gate or awaiting review — if the only fitting target is in that \
        state, fall back to `wait` behind it instead.

        End your summary with a single final line stating your choice and \
        why, in the form `Disposition: <parallel|wait|integrate> — <reason>`.
        """
    }
}
