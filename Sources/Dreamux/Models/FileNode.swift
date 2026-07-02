import Foundation

/// One node in the cross-repo file tree. Directories expand lazily —
/// `FileTreeStore.children(of:)` enumerates a node's contents on demand
/// so a deep worktree is never walked eagerly.
struct FileNode: Identifiable, Hashable {
    /// Resolved (symlink-free) absolute path on disk. Also the identity
    /// used for tree diffing and editor-tab dedup.
    let url: URL
    /// Display label — the repo name for a root, else the file/dir name.
    let name: String
    let isDirectory: Bool
    /// True for the per-repo top-level nodes (repo-style chrome, opened
    /// by default in the panel).
    let isRepoRoot: Bool

    var id: URL { url }
}
