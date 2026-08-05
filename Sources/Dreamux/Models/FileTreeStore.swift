import Foundation
import Observation

/// Builds the cross-repo file tree shown in the right-side inspector.
/// Holds no cached tree: `roots` and `children` are recomputed from the
/// live workspace/repository values passed in, so switching the active
/// feature or hitting refresh simply recomputes.
@MainActor
@Observable
final class FileTreeStore {
    /// Directory entries never shown in the tree — git internals.
    private static let hiddenNames: Set<String> = [".git", ".bare"]

    /// Top-level nodes: one per repo the feature spans that has a
    /// worktree checked out at the feature's branch. Repos without such
    /// a worktree, and repos the feature doesn't link, are omitted. A
    /// nil/orphan workspace (no linked repos) yields `[]`.
    func roots(for workspace: Workspace?, repositories: [Repository]) -> [FileNode] {
        guard let workspace else { return [] }
        return WorkspaceWorktrees.existing(for: workspace, in: repositories).map { worktree in
            FileNode(
                url: worktree.resolvingSymlinksInPath(),
                // A worktree is `<project>/repos/<repo>/<branch>/`, so its
                // parent folder name IS `Repository.name`. Taken from the
                // unresolved URL: symlink resolution can respell ancestors
                // (/var → /private/var) but never renames a component.
                name: worktree.deletingLastPathComponent().lastPathComponent,
                isDirectory: true,
                isRepoRoot: true
            )
        }
    }

    /// Immediate children of a directory node — directories first, then
    /// files, each case-insensitively sorted. `.git`/`.bare` are hidden;
    /// other dotfiles are shown. A file node (or unreadable dir) yields
    /// `[]`.
    func children(of node: FileNode) -> [FileNode] {
        guard node.isDirectory else { return [] }
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: node.url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        )) ?? []
        let nodes = entries.compactMap { url -> FileNode? in
            let name = url.lastPathComponent
            guard !Self.hiddenNames.contains(name) else { return nil }
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            return FileNode(url: url, name: name, isDirectory: isDir, isRepoRoot: false)
        }
        return nodes.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }
}
