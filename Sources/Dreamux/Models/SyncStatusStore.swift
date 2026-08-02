import Foundation

/// Where a repo's local default branch stands relative to
/// `origin/<defaultBranch>` — the verdict behind every sync surface
/// (header chip, main's Overview, sidebar badge, popover rows).
enum RepoSyncState: Equatable {
    case noRemote
    case upToDate
    case behind(Int)
    case ahead(Int)
    case diverged(ahead: Int, behind: Int)

    /// Pure verdict from the probe results. `hasRemote` false wins
    /// regardless of counts — counts against a ref that doesn't exist
    /// are meaningless.
    static func decide(ahead: Int, behind: Int, hasRemote: Bool) -> RepoSyncState {
        guard hasRemote else { return .noRemote }
        switch (ahead > 0, behind > 0) {
        case (false, false): return .upToDate
        case (false, true): return .behind(behind)
        case (true, false): return .ahead(ahead)
        case (true, true): return .diverged(ahead: ahead, behind: behind)
        }
    }
}
