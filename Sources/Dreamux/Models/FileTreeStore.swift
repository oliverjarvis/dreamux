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
        let byName = Dictionary(repositories.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        var result: [FileNode] = []
        for repoID in workspace.linkedRepoIDs {
            guard let repo = byName[repoID] else { continue }
            // Main workspaces browse each repo's own default branch —
            // display name aside, "main" here can be "master" there.
            let branchFolder = workspace.isMain ? repo.defaultBranch : workspace.name
            let worktree = repo.rootURL.appendingPathComponent(branchFolder, isDirectory: true)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: worktree.path, isDirectory: &isDir),
                  isDir.boolValue else { continue }
            result.append(FileNode(
                url: worktree.resolvingSymlinksInPath(),
                name: repo.name,
                isDirectory: true,
                isRepoRoot: true
            ))
        }
        return result
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
