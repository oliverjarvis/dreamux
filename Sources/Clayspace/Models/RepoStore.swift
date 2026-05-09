import Foundation
import Observation

/// Per-project view of the bare repos under `<project>/repos/`. The
/// folder is the source of truth — anything mkdir'd in there with a
/// `.bare/` subdir shows up; deleting a folder removes it.
@MainActor
@Observable
final class RepoStore {
    let project: Project
    let reposDirectory: URL

    private(set) var repositories: [Repository] = []

    init(project: Project) {
        self.project = project
        self.reposDirectory = project.rootPath
            .appendingPathComponent("repos", isDirectory: true)
        refresh()
    }

    func refresh() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: reposDirectory.path) else {
            repositories = []
            return
        }

        let entries = (try? fm.contentsOfDirectory(
            at: reposDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        repositories = entries.compactMap { url in
            let bareURL = url.appendingPathComponent(".bare", isDirectory: true)
            guard fm.fileExists(atPath: bareURL.path) else { return nil }
            let defaultBranch = Self.detectDefaultBranch(at: bareURL)
            return Repository(rootURL: url, defaultBranch: defaultBranch)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    @discardableResult
    func clone(url: String, name: String?) async throws -> Repository {
        let resolvedName = (name?.isEmpty == false ? name! : GitOperations.deriveName(from: url))
        let repo = try await GitOperations.cloneBare(
            url: url,
            into: project.rootPath,
            name: resolvedName
        )
        refresh()
        return repo
    }

    @discardableResult
    func initRepo(name: String) async throws -> Repository {
        let repo = try await GitOperations.initBare(
            into: project.rootPath,
            name: name
        )
        refresh()
        return repo
    }

    @discardableResult
    func importLocal(path: URL, name: String) async throws -> Repository {
        // Importing is just `git clone --bare` from a local source path —
        // the resulting `.bare/` mirrors the source's history and stays
        // independent (the source folder is untouched). We then lay
        // down the worktree on the default branch like a normal clone.
        let repo = try await GitOperations.cloneBare(
            url: path.path,
            into: project.rootPath,
            name: name
        )
        refresh()
        return repo
    }

    private static func detectDefaultBranch(at bareURL: URL) -> String {
        let headFile = bareURL.appendingPathComponent("HEAD")
        guard let content = try? String(contentsOf: headFile, encoding: .utf8) else {
            return "main"
        }
        // HEAD typically reads `ref: refs/heads/<branch>\n`.
        if let range = content.range(of: "ref: refs/heads/") {
            let branch = content[range.upperBound...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !branch.isEmpty { return branch }
        }
        return "main"
    }
}
