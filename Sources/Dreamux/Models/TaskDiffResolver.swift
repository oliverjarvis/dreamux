import Foundation

/// Maps a plan task's heading to the worktree commits that implemented
/// it. Agents commit the heading verbatim; the queue backstop appends
/// " (auto)" — both count. Pure so the matching rules are testable
/// without a repo.
enum TaskDiffResolver {
    /// The revision range covering every commit whose subject is the
    /// task title (exactly, or followed by a " (" suffix like
    /// " (auto)"). `log` is newest-first (GitOperations.commitLog
    /// order). Returns oldest-parent..newest, nil when nothing matches.
    static func range(
        for taskTitle: String,
        in log: [CommitInfo]
    ) -> (from: String, to: String)? {
        let matches = log.filter { commit in
            commit.subject == taskTitle
                || commit.subject.hasPrefix("\(taskTitle) (")
        }
        guard let newest = matches.first, let oldest = matches.last else {
            return nil
        }
        return (from: "\(oldest.sha)^", to: newest.sha)
    }
}
