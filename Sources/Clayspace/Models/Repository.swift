import Foundation

/// A bare-repo-with-worktrees layout under a project's `repos/` folder.
///
///     <project>/repos/<name>/
///       .bare/         ← real git data (a `git init --bare` repository)
///       .git           ← text file: "gitdir: ./.bare"
///       <branch>/      ← worktree(s) created via `git worktree add`
///
/// The `.git` pointer makes git commands run from anywhere inside
/// `<name>/` (or its worktrees) discover the bare repo automatically,
/// so users can `cd` into a worktree and use git as normal.
struct Repository: Identifiable, Hashable {
    var rootURL: URL
    var defaultBranch: String

    var id: URL { rootURL }
    var name: String { rootURL.lastPathComponent }
    var bareURL: URL {
        rootURL.appendingPathComponent(".bare", isDirectory: true)
    }

    init(rootURL: URL, defaultBranch: String = "main") {
        self.rootURL = rootURL
        self.defaultBranch = defaultBranch
    }

    /// The worktree directories present under the repo root (any
    /// directory besides `.bare/` that contains a `.git` pointer file).
    var worktrees: [URL] {
        let fm = FileManager.default
        let entries = (try? fm.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return entries.filter { url in
            guard url.lastPathComponent != ".bare" else { return false }
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard isDir else { return false }
            let gitPointer = url.appendingPathComponent(".git")
            return fm.fileExists(atPath: gitPointer.path)
        }.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }
}
