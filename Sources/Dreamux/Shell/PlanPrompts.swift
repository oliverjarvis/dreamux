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
    static func brainstormKickoff(idea: String) -> String {
        """
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
    }

    /// Turn an existing spec into a plan.
    static func writePlanKickoff(specRelativePath: String) -> String {
        """
        Read \(specRelativePath) — an approved design spec in this \
        project's shared docs home. Use your writing-plans skill \
        (superpowers:writing-plans) to produce its implementation plan and \
        save it to docs/plans/ named after the spec (spec filename minus \
        `-design`). The repos under ./repos/<repo>/<default-branch>/ are \
        reference checkouts for grounding exact file paths and code.
        """
    }
}
