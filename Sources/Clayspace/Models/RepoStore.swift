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

    // MARK: - Worktree discovery

    /// Group every non-default-branch worktree across the project's repos
    /// by branch name. Each entry in the result is a feature whose linked
    /// repos are the ones that have a worktree on that branch. This is
    /// what the launch-time feature list is reconstructed from.
    func discoverFeatures() async -> [String: [Repository]] {
        var byBranch: [String: [Repository]] = [:]
        for repo in repositories {
            for entry in await Self.listWorktrees(in: repo) where !entry.isBare {
                guard let branch = entry.branch, branch != repo.defaultBranch else { continue }
                byBranch[branch, default: []].append(repo)
            }
        }
        return byBranch
    }

    private struct WorktreeEntry {
        let path: URL
        let branch: String?
        let isBare: Bool
    }

    private static func listWorktrees(in repo: Repository) async -> [WorktreeEntry] {
        let output: String
        do {
            output = try await GitOperations.runGit(
                ["worktree", "list", "--porcelain"],
                in: repo.rootURL
            )
        } catch {
            return []
        }

        var result: [WorktreeEntry] = []
        var path: URL?
        var branch: String?
        var isBare = false

        func flush() {
            if let p = path {
                result.append(WorktreeEntry(path: p, branch: branch, isBare: isBare))
            }
            path = nil
            branch = nil
            isBare = false
        }

        for raw in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.isEmpty {
                flush()
                continue
            }
            if line.hasPrefix("worktree ") {
                path = URL(fileURLWithPath: String(line.dropFirst("worktree ".count)))
            } else if line.hasPrefix("branch ") {
                let ref = String(line.dropFirst("branch ".count))
                let prefix = "refs/heads/"
                branch = ref.hasPrefix(prefix)
                    ? String(ref.dropFirst(prefix.count))
                    : ref
            } else if line == "bare" {
                isBare = true
            }
        }
        flush()
        return result
    }
}
