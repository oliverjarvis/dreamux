import Foundation

/// Partitions the sidebar's workspaces into plan-backed and *ad hoc*. A
/// workspace is plan-backed when its name is the feature that some
/// initiative's plan runs as (so it's reachable from that plan's row);
/// everything else is ad hoc and needs a row of its own. Pure logic pulled
/// out of `WorkspaceSidebar` so the partition is testable without the view
/// — like `PlanWorkspacePresence`.
enum AdHocWorkspaces {
    /// The feature a plan runs as: the ledger's recorded feature name once
    /// the plan has run, else the branch derived from its filename. The
    /// single-plan resolution shared by the Plans section's row labels and
    /// the set below.
    static func featureName(
        for plan: PlanDoc,
        record: (PlanDoc) -> PlanRunRecord?
    ) -> String {
        record(plan)?.featureName
            ?? PlanDoc.branchName(forFileName: plan.fileURL.lastPathComponent)
    }

    /// Every feature name a plan across `initiatives` is bound to. A
    /// workspace whose name is absent from this set is ad hoc.
    static func planBackedFeatureNames(
        in initiatives: [Initiative],
        record: (PlanDoc) -> PlanRunRecord?
    ) -> Set<String> {
        Set(initiatives.flatMap(\.plans).map { featureName(for: $0, record: record) })
    }

    /// Whether closing this workspace should also delete its branch.
    ///
    /// A PLAN-BACKED feature keeps the destructive close: its branch
    /// exists because a plan run made it, and abandoning the run
    /// shouldn't leave the branch behind. Anything else was OPENED — the
    /// branch already existed, quite possibly as someone else's PR — so
    /// the branch stays and only the worktree goes.
    ///
    /// Derived from plan documents rather than stored, so it needs no
    /// persistence and survives relaunch, project moves, and workspaces
    /// discovered from disk.
    static func deletesBranchOnClose(
        workspaceName: String,
        planBacked: Set<String>
    ) -> Bool {
        planBacked.contains(workspaceName)
    }
}
