import Foundation

/// The prompts Dreamux types into claude sessions for plan work. Kept
/// as pure functions so tests can pin the contract (file paths named,
/// checkbox-ticking instruction present) without a PTY.
enum PlanPrompts {
    /// Kick off execution of a plan inside a freshly provisioned
    /// feature aggregation directory.
    static func runPlan(planRelativePath: String, docsLinkName: String) -> String {
        """
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
        repo subfolder.
        - Stop and ask if a step fails rather than improvising around it.

        Begin with Task 1's first unchecked step.
        """
    }

    /// Re-enter a partially executed plan in its existing worktree.
    static func resumePlan(planRelativePath: String, docsLinkName: String) -> String {
        """
        You're back in a Dreamux feature directory (see DREAMUX.md; \
        `\(docsLinkName)/` is the shared project docs home). The plan at \
        \(planRelativePath) is partially done — checked boxes (`- [x]`) are \
        complete, unchecked (`- [ ]`) are not. Verify the last checked \
        step's commit exists, then continue from the first unchecked step, \
        ticking checkboxes in the plan file as you go and committing as \
        the plan directs.
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
