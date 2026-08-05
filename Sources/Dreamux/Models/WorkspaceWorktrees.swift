import Foundation

/// The one place "which worktree does this workspace mean?" is answered.
///
/// A Dreamux repo lays out as `<project>/repos/<repo>/<branch>/`, so a
/// workspace resolves to one worktree per linked repo. The reserved main
/// workspace means each repo's OWN default branch — its display name is
/// only the FIRST repo's (`WorkspaceSidebar.openMainWorkspace` passes
/// `repositories.first?.defaultBranch`), so `workspace.name` is the
/// wrong answer there. Every other workspace means the branch it is
/// named after.
///
/// Deliberately not `@MainActor` and holding no state: this is value
/// math plus one existence check, so it is directly unit-testable.
enum WorkspaceWorktrees {
    /// The worktree directory `workspace` means in `repo`. Path
    /// arithmetic only — the directory may not exist.
    static func worktreeURL(for workspace: Workspace, in repo: Repository) -> URL {
        let branchFolder = workspace.isMain ? repo.defaultBranch : workspace.name
        return repo.rootURL.appendingPathComponent(branchFolder, isDirectory: true)
    }

    /// Every worktree this workspace spans that is present on disk, in
    /// `linkedRepoIDs` order. A linked name the project no longer has is
    /// dropped; so is a worktree that hasn't been provisioned yet.
    static func existing(for workspace: Workspace, in repositories: [Repository]) -> [URL] {
        let byName = Dictionary(
            repositories.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        var result: [URL] = []
        for repoID in workspace.linkedRepoIDs {
            guard let repo = byName[repoID] else { continue }
            let worktree = worktreeURL(for: workspace, in: repo)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: worktree.path, isDirectory: &isDir),
                  isDir.boolValue else { continue }
            result.append(worktree)
        }
        return result
    }

    /// Where a new *user* shell should start: the worktree of the single
    /// repo this workspace links, when that worktree exists on disk;
    /// otherwise the workspace's own `workingDirectory`. `String?`
    /// matches `Workspace.workingDirectory`, so the fallback is a
    /// straight pass-through.
    ///
    /// The count comes from `linkedRepoIDs`, never from how many
    /// worktrees happen to be on disk. Keying on disk state would make a
    /// shell descend into repo A today and jump back up to the
    /// aggregation directory the moment repo B's worktree appeared — the
    /// same workspace answering the same question two different ways
    /// depending on provisioning timing. The rule is "descend only when
    /// there is no ambiguity."
    static func shellHome(for workspace: Workspace, in repositories: [Repository]) -> String? {
        guard workspace.linkedRepoIDs.count == 1,
              let worktree = existing(for: workspace, in: repositories).first
        else { return workspace.workingDirectory }
        return worktree.path
    }
}
