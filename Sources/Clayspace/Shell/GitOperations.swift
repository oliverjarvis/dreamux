import Foundation

enum GitError: LocalizedError {
    case alreadyExists(name: String)
    case commandFailed(args: [String], stderr: String)
    case directoryCreationFailed(underlying: Error)

    var errorDescription: String? {
        switch self {
        case .alreadyExists(let name):
            return "A repository named “\(name)” already exists in this project."
        case .commandFailed(let args, let stderr):
            let cmd = (["git"] + args).joined(separator: " ")
            let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty
                ? "Git command failed: \(cmd)"
                : "git: \(trimmed)"
        case .directoryCreationFailed(let underlying):
            return "Couldn't create the repository folder: \(underlying.localizedDescription)"
        }
    }
}

/// Async helpers around `git` for the bare-repo-with-worktrees layout.
/// All public entry points create `<project>/repos/<name>/`, populate
/// `.bare/`, write the `.git` pointer file, and produce a worktree for
/// the default branch.
enum GitOperations {
    @discardableResult
    static func cloneBare(
        url: String,
        into projectRoot: URL,
        name: String
    ) async throws -> Repository {
        let fm = FileManager.default
        let reposDir = projectRoot.appendingPathComponent("repos", isDirectory: true)
        let repoDir = reposDir.appendingPathComponent(name, isDirectory: true)

        guard !fm.fileExists(atPath: repoDir.path) else {
            throw GitError.alreadyExists(name: name)
        }
        try createDir(reposDir)
        try createDir(repoDir)

        do {
            _ = try await runGit(["clone", "--bare", url, ".bare"], in: repoDir)
        } catch {
            try? fm.removeItem(at: repoDir)
            throw error
        }

        try writeGitdirPointer(in: repoDir)

        // Reconfigure the bare clone so it fetches like a regular working
        // copy (otherwise its only refs are local heads — confusing for
        // worktree-based development).
        _ = try? await runGit(
            ["--git-dir=.bare", "config", "remote.origin.fetch",
             "+refs/heads/*:refs/remotes/origin/*"],
            in: repoDir
        )
        _ = try? await runGit(["--git-dir=.bare", "fetch", "origin"], in: repoDir)

        let head = (try? await runGit(
            ["--git-dir=.bare", "symbolic-ref", "--short", "HEAD"],
            in: repoDir
        ))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let defaultBranch = head.isEmpty ? "main" : head

        _ = try await runGit(
            ["worktree", "add", defaultBranch, defaultBranch],
            in: repoDir
        )

        return Repository(rootURL: repoDir, defaultBranch: defaultBranch)
    }

    @discardableResult
    static func initBare(
        into projectRoot: URL,
        name: String
    ) async throws -> Repository {
        let fm = FileManager.default
        let reposDir = projectRoot.appendingPathComponent("repos", isDirectory: true)
        let repoDir = reposDir.appendingPathComponent(name, isDirectory: true)

        guard !fm.fileExists(atPath: repoDir.path) else {
            throw GitError.alreadyExists(name: name)
        }
        try createDir(reposDir)
        try createDir(repoDir)

        do {
            _ = try await runGit(
                ["init", "--bare", "--initial-branch=main", ".bare"],
                in: repoDir
            )
        } catch {
            try? fm.removeItem(at: repoDir)
            throw error
        }

        try writeGitdirPointer(in: repoDir)

        // Create an orphan worktree on `main`. `--orphan -b` lands a
        // fresh empty worktree on a new branch with no commits — we
        // make a starter commit so the branch is real and other tooling
        // doesn't choke on the empty repo state.
        do {
            _ = try await runGit(
                ["worktree", "add", "--orphan", "-b", "main", "main"],
                in: repoDir
            )
        } catch {
            try? fm.removeItem(at: repoDir)
            throw error
        }

        let mainURL = repoDir.appendingPathComponent("main", isDirectory: true)
        let readmeURL = mainURL.appendingPathComponent("README.md")
        if !fm.fileExists(atPath: readmeURL.path) {
            let body = "# \(name)\n"
            try? body.write(to: readmeURL, atomically: true, encoding: .utf8)
            _ = try? await runGit(["add", "README.md"], in: mainURL)
            _ = try? await runGit(
                ["-c", "commit.gpgsign=false",
                 "commit", "-m", "Initial commit"],
                in: mainURL
            )
        }

        return Repository(rootURL: repoDir, defaultBranch: "main")
    }

    // MARK: - Internals

    private static func createDir(_ url: URL) throws {
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            throw GitError.directoryCreationFailed(underlying: error)
        }
    }

    private static func writeGitdirPointer(in repoDir: URL) throws {
        let gitFile = repoDir.appendingPathComponent(".git")
        do {
            try "gitdir: ./.bare\n".write(to: gitFile, atomically: true, encoding: .utf8)
        } catch {
            throw GitError.directoryCreationFailed(underlying: error)
        }
    }

    static func runGit(_ args: [String], in cwd: URL) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                process.arguments = ["git"] + args
                process.currentDirectoryURL = cwd

                let outPipe = Pipe()
                let errPipe = Pipe()
                process.standardOutput = outPipe
                process.standardError = errPipe

                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }
                process.waitUntilExit()

                let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                let outStr = String(data: outData, encoding: .utf8) ?? ""
                let errStr = String(data: errData, encoding: .utf8) ?? ""

                if process.terminationStatus != 0 {
                    continuation.resume(
                        throwing: GitError.commandFailed(args: args, stderr: errStr.isEmpty ? outStr : errStr)
                    )
                } else {
                    continuation.resume(returning: outStr)
                }
            }
        }
    }

    // MARK: - Worktrees

    /// Create a worktree at `<repoRootURL>/<branch>/` on a branch named
    /// `<branch>`. If the branch already exists locally, the worktree
    /// is checked out from it; otherwise a fresh branch is created off
    /// the repository's current HEAD.
    static func addWorktree(in repoRootURL: URL, branch: String) async throws {
        let exists = (try? await runGit(
            ["rev-parse", "--verify", "--quiet", "refs/heads/\(branch)"],
            in: repoRootURL
        )) != nil
        let args: [String]
        if exists {
            args = ["worktree", "add", branch, branch]
        } else {
            args = ["worktree", "add", "-b", branch, branch]
        }
        _ = try await runGit(args, in: repoRootURL)
    }

    /// Remove a worktree, force if needed, and prune.
    static func removeWorktree(at worktreeURL: URL, in repoRootURL: URL) async throws {
        _ = try? await runGit(["worktree", "remove", "--force", worktreeURL.path], in: repoRootURL)
        _ = try? await runGit(["worktree", "prune"], in: repoRootURL)
    }

    /// Force-delete a local branch — used during feature teardown so
    /// abandoned branches don't pile up. We use `-D` because the
    /// expected case is "branch never merged."
    static func deleteBranch(in repoRootURL: URL, branch: String) async throws {
        _ = try? await runGit(["branch", "-D", branch], in: repoRootURL)
    }

    // MARK: - Merge

    enum MergeOutcome: Equatable {
        case alreadyUpToDate
        case merged
        case conflicted(paths: [String])
    }

    /// Merge `feature` into `baseBranch` from inside the worktree where
    /// `baseBranch` is checked out. Always uses `--no-ff` so the merge
    /// commit is explicit and easy to revert later. On conflict, leaves
    /// the worktree in a conflicted state for the user (or an agent) to
    /// resolve — does *not* abort automatically.
    static func mergeBranch(
        feature: String,
        into baseBranch: String,
        in baseWorktreeURL: URL
    ) async throws -> MergeOutcome {
        let message = "Merge branch '\(feature)' into \(baseBranch)"
        do {
            let output = try await runGit(
                ["merge", "--no-ff", "--no-edit", "-m", message, feature],
                in: baseWorktreeURL
            )
            if output.lowercased().contains("already up to date") {
                return .alreadyUpToDate
            }
            return .merged
        } catch let GitError.commandFailed(args, stderr) {
            let conflicted = await conflictedPaths(in: baseWorktreeURL)
            if !conflicted.isEmpty {
                return .conflicted(paths: conflicted)
            }
            throw GitError.commandFailed(args: args, stderr: stderr)
        }
    }

    static func conflictedPaths(in worktreeURL: URL) async -> [String] {
        let output = (try? await runGit(
            ["diff", "--name-only", "--diff-filter=U"],
            in: worktreeURL
        )) ?? ""
        return output
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
    }

    /// Abort an in-progress merge so the worktree returns to a clean
    /// state. Best-effort.
    static func abortMerge(in worktreeURL: URL) async {
        _ = try? await runGit(["merge", "--abort"], in: worktreeURL)
    }

    // MARK: - Names

    /// Heuristic name extraction from a clone URL. `git@host:foo/bar.git` →
    /// `bar`; `https://host/foo/bar` → `bar`; falls back to a sanitized
    /// version of whatever's after the last `/` or `:`.
    static func deriveName(from url: String) -> String {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        let separators = CharacterSet(charactersIn: "/:")
        let last = trimmed.split(whereSeparator: { separators.contains($0.unicodeScalars.first!) }).last
            .map(String.init) ?? trimmed
        var name = last
        if name.hasSuffix(".git") {
            name = String(name.dropLast(4))
        }
        // Strip any leftover characters that aren't safe in folder names.
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let scrubbed = name.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        return String(scrubbed).trimmingCharacters(in: CharacterSet(charactersIn: "-_."))
    }
}
