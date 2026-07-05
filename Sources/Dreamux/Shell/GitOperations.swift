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

    /// Run a git command. Always non-interactive — we bake in flags and
    /// env vars that prevent git from popping a tty prompt or sitting on
    /// a GPG passphrase that no terminal can answer. Optionally
    /// streams every output line as it arrives via `onLine`; the
    /// merge sheet uses that to render live progress under each row.
    /// Task cancellation (Swift structured concurrency) sends SIGTERM
    /// to the child so a "Cancel" click actually unblocks the user.
    static func runGit(
        _ args: [String],
        in cwd: URL,
        onLine: (@Sendable (String) -> Void)? = nil
    ) async throws -> String {
        let processBox = ProcessBox()

        return try await withTaskCancellationHandler(
            operation: {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
                    DispatchQueue.global(qos: .userInitiated).async {
                        let process = Process()
                        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                        // Non-interactive defaults applied to every git
                        // invocation: GPG signing off (yubikey/passphrase
                        // prompts hang headless), editor disabled (so any
                        // accidental commit without -m fails fast instead
                        // of waiting on $EDITOR), and credential helpers
                        // told to give up rather than prompt.
                        process.arguments = [
                            "git",
                            "-c", "commit.gpgsign=false",
                            "-c", "tag.gpgsign=false",
                            "-c", "core.editor=true",
                        ] + args
                        process.currentDirectoryURL = cwd

                        var env = ProcessInfo.processInfo.environment
                        env["GIT_TERMINAL_PROMPT"] = "0"
                        env["GIT_ASKPASS"] = "echo"
                        env["SSH_ASKPASS"] = "echo"
                        process.environment = env

                        let outPipe = Pipe()
                        let errPipe = Pipe()
                        process.standardOutput = outPipe
                        process.standardError = errPipe

                        let accumulator = OutputAccumulator()
                        // Drain handlers are installed unconditionally, even
                        // with no `onLine` consumer: nothing else reads the
                        // pipes until after waitUntilExit(), so a git command
                        // producing more than the kernel pipe buffer (~64KB —
                        // e.g. a merge diffstat or a commit touching hundreds
                        // of files) would block writing while we block
                        // waiting, deadlocking both processes forever.
                        outPipe.fileHandleForReading.readabilityHandler = { handle in
                            let data = handle.availableData
                            if data.isEmpty {
                                handle.readabilityHandler = nil
                                return
                            }
                            accumulator.processStdout(data, onLine: onLine)
                        }
                        errPipe.fileHandleForReading.readabilityHandler = { handle in
                            let data = handle.availableData
                            if data.isEmpty {
                                handle.readabilityHandler = nil
                                return
                            }
                            accumulator.processStderr(data, onLine: onLine)
                        }

                        processBox.set(process)
                        do {
                            try process.run()
                        } catch {
                            continuation.resume(throwing: error)
                            return
                        }
                        process.waitUntilExit()

                        outPipe.fileHandleForReading.readabilityHandler = nil
                        errPipe.fileHandleForReading.readabilityHandler = nil

                        // Drain any bytes that landed after the last
                        // readability callback fired — important on fast
                        // commands that finish in a single chunk.
                        let tailOut = outPipe.fileHandleForReading.readDataToEndOfFile()
                        let tailErr = errPipe.fileHandleForReading.readDataToEndOfFile()
                        if !tailOut.isEmpty {
                            accumulator.processStdout(tailOut, onLine: onLine)
                        }
                        if !tailErr.isEmpty {
                            accumulator.processStderr(tailErr, onLine: onLine)
                        }
                        accumulator.flushPartial(onLine: onLine)

                        let outStr = accumulator.allStdout
                        let errStr = accumulator.allStderr

                        if process.terminationStatus != 0 {
                            continuation.resume(
                                throwing: GitError.commandFailed(
                                    args: args,
                                    stderr: errStr.isEmpty ? outStr : errStr
                                )
                            )
                        } else {
                            continuation.resume(returning: outStr)
                        }
                    }
                }
            },
            onCancel: {
                processBox.terminate()
            }
        )
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

    // MARK: - Remotes

    /// URL of the `origin` remote, or nil when the repo has none (e.g.
    /// repos created via `initBare`). Drives whether the merge sheet
    /// offers the "Create PR" path at all.
    static func remoteURL(in repoRootURL: URL) async -> String? {
        guard let output = try? await runGit(
            ["remote", "get-url", "origin"],
            in: repoRootURL
        ) else { return nil }
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Push a branch to `origin`, creating/updating the remote branch
    /// and setting upstream. Auth prompts are disabled by `runGit`'s
    /// non-interactive env, so a missing credential fails fast with a
    /// surfaced error instead of hanging the sheet.
    static func push(
        branch: String,
        in repoRootURL: URL,
        onLine: (@Sendable (String) -> Void)? = nil
    ) async throws {
        _ = try await runGit(
            ["push", "--set-upstream", "origin", branch],
            in: repoRootURL,
            onLine: onLine
        )
    }

    /// Fetch `origin` and fast-forward the local default branch from
    /// `origin/<branch>` inside its worktree. Used after a PR merges
    /// remotely so local main reflects the merged state before the
    /// feature worktree is cleaned up. Best-effort by design: a
    /// diverged local main is the user's situation to resolve, not a
    /// reason to block cleanup. ff-only (never a real merge) because a
    /// PR merged via squash/rebase produces remote commits unrelated to
    /// the local feature tip — merging those would invent conflicts.
    static func fastForwardFromOrigin(
        branch: String,
        in baseWorktreeURL: URL,
        onLine: (@Sendable (String) -> Void)? = nil
    ) async {
        _ = try? await runGit(["fetch", "origin", branch], in: baseWorktreeURL, onLine: onLine)
        _ = try? await runGit(
            ["merge", "--ff-only", "origin/\(branch)"],
            in: baseWorktreeURL,
            onLine: onLine
        )
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
        in baseWorktreeURL: URL,
        onLine: (@Sendable (String) -> Void)? = nil
    ) async throws -> MergeOutcome {
        let message = "Merge branch '\(feature)' into \(baseBranch)"
        do {
            let output = try await runGit(
                ["merge", "--no-ff", "--no-edit", "-m", message, feature],
                in: baseWorktreeURL,
                onLine: onLine
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

    /// The top-level paths a worktree's branch touches vs where it forked
    /// from `baseBranch` — the "territory" a running plan occupies, for the
    /// intake digest. Diffs against the merge-base (`git merge-base
    /// <baseBranch> HEAD`, then `git diff --name-only <mergeBase>`) so the
    /// territory spans committed, staged, and unstaged work in one shot: a
    /// bare `git diff` would show only uncommitted changes, and agents
    /// commit per task, so the branch's real footprint lives in its
    /// commits. Each changed path is mapped to its first segment and the
    /// deduped set returned in stable (sorted) order. Tolerant by contract:
    /// a missing worktree, an unresolvable merge-base (unrelated histories,
    /// missing base branch), or any git failure yields an empty list, so
    /// intake treats "can't tell" as "nothing to report" rather than
    /// failing the whole digest.
    static func changedTopLevelPaths(
        in worktreeURL: URL,
        baseBranch: String
    ) async -> [String] {
        guard let rawBase = try? await runGit(
            ["merge-base", baseBranch, "HEAD"],
            in: worktreeURL
        ) else { return [] }
        let mergeBase = rawBase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !mergeBase.isEmpty,
              let output = try? await runGit(
                ["diff", "--name-only", mergeBase],
                in: worktreeURL
              ) else { return [] }

        var seen: Set<String> = []
        var topLevel: [String] = []
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let head = line.split(separator: "/", maxSplits: 1).first.map(String.init)
                ?? String(line)
            if seen.insert(head).inserted { topLevel.append(head) }
        }
        return topLevel.sorted()
    }

    /// Abort an in-progress merge so the worktree returns to a clean
    /// state. Best-effort.
    static func abortMerge(in worktreeURL: URL) async {
        _ = try? await runGit(["merge", "--abort"], in: worktreeURL)
    }

    /// Number of commits on `feature` that aren't on `base`. Used by the
    /// merge sheet to detect "nothing to merge" up-front rather than
    /// running `git merge` and parsing its "Already up to date" output.
    static func commitsAhead(
        of base: String,
        feature: String,
        in repoURL: URL
    ) async -> Int {
        let output = (try? await runGit(
            ["rev-list", "--count", "\(base)..\(feature)"],
            in: repoURL
        )) ?? "0"
        return Int(output.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    /// True when `git status --porcelain` is non-empty in the given
    /// worktree — i.e. there are untracked or modified files.
    static func hasUncommittedChanges(in worktreeURL: URL) async -> Bool {
        let output = (try? await runGit(
            ["status", "--porcelain"],
            in: worktreeURL
        )) ?? ""
        return !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Stage every modified/untracked path and create a commit with
    /// the given message. Honours `.gitignore` the same way `git add -A`
    /// does — gitignored files stay out. Throws if either step fails so
    /// the caller can surface the error (typically missing user.name or
    /// a failing pre-commit hook).
    static func commitAll(
        message: String,
        in worktreeURL: URL,
        onLine: (@Sendable (String) -> Void)? = nil
    ) async throws {
        _ = try await runGit(["add", "-A"], in: worktreeURL, onLine: onLine)
        _ = try await runGit(["commit", "-m", message], in: worktreeURL, onLine: onLine)
    }

    enum MergeProbe {
        case inProgress
        case merged
        case notMerged
    }

    /// Probe whether a merge is happening, has happened, or hasn't.
    /// Used by the merge sheet to detect the moment the user (or an
    /// agent) finishes resolving conflicts and commits, so the row
    /// can flip to "Merged" without a manual refresh.
    ///
    /// `inProgress` is signalled by `MERGE_HEAD` existing in the
    /// worktree's git dir. `merged` is signalled by the feature tip
    /// being reachable from the base branch (so we don't depend on
    /// the merge commit's subject being intact). Anything else —
    /// merge aborted, never started, branch missing — is reported as
    /// `notMerged`.
    static func mergeProbe(
        in worktreeURL: URL,
        feature: String,
        baseBranch: String
    ) async -> MergeProbe {
        if (try? await runGit(
            ["rev-parse", "--verify", "--quiet", "MERGE_HEAD"],
            in: worktreeURL
        )) != nil {
            return .inProgress
        }
        if (try? await runGit(
            ["merge-base", "--is-ancestor", feature, baseBranch],
            in: worktreeURL
        )) != nil {
            return .merged
        }
        return .notMerged
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

// MARK: - Streaming helpers

/// Thread-safe holder for a running `Process` so the task-cancellation
/// callback can reach in and SIGTERM the child. `weak` would also work
/// (Process is a class) but we keep a strong reference until termination
/// to avoid races with deallocation while the cancel handler is fired.
private final class ProcessBox: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?

    func set(_ p: Process) {
        lock.lock(); defer { lock.unlock() }
        process = p
    }

    func terminate() {
        lock.lock()
        let p = process
        lock.unlock()
        guard let p, p.isRunning else { return }
        p.terminate()
    }
}

/// Buffers stdout/stderr chunks from a child process and emits one
/// callback per complete line. Also records the full output streams so
/// the parent can still return the canonical stdout to the caller (and
/// fold stderr into error messages). All callbacks run on whatever
/// dispatch queue the Pipe's readability handler fires on — the caller
/// is responsible for hopping back to the main actor if needed.
private final class OutputAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var allStdout = ""
    private(set) var allStderr = ""
    private var stdoutBuffer = ""
    private var stderrBuffer = ""

    func processStdout(_ data: Data, onLine: (@Sendable (String) -> Void)?) {
        guard let str = String(data: data, encoding: .utf8) else { return }
        lock.lock()
        allStdout += str
        stdoutBuffer += str
        let lines = extractLines(from: &stdoutBuffer)
        lock.unlock()
        if let onLine {
            for line in lines { onLine(line) }
        }
    }

    func processStderr(_ data: Data, onLine: (@Sendable (String) -> Void)?) {
        guard let str = String(data: data, encoding: .utf8) else { return }
        lock.lock()
        allStderr += str
        stderrBuffer += str
        let lines = extractLines(from: &stderrBuffer)
        lock.unlock()
        if let onLine {
            for line in lines { onLine(line) }
        }
    }

    func flushPartial(onLine: (@Sendable (String) -> Void)?) {
        lock.lock()
        let tail = (stdoutBuffer + stderrBuffer)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        stdoutBuffer = ""
        stderrBuffer = ""
        lock.unlock()
        if !tail.isEmpty, let onLine { onLine(tail) }
    }

    private func extractLines(from buffer: inout String) -> [String] {
        var lines: [String] = []
        while let idx = buffer.firstIndex(of: "\n") {
            let raw = String(buffer[..<idx])
            buffer.removeSubrange(buffer.startIndex...idx)
            let trimmed = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            if !trimmed.isEmpty { lines.append(trimmed) }
        }
        return lines
    }
}

// MARK: - Header status chip

/// HEAD summary for the card header's git chip: branch, short SHA, and
/// working-tree diff totals (staged + unstaged vs HEAD).
struct GitHeadStatus: Equatable, Sendable {
    var branch: String
    var shortSHA: String
    var insertions: Int
    var deletions: Int
}

extension GitOperations {
    /// The worktree checked out on `branch` for the repo at `repoRootURL`
    /// (porcelain `worktree list`), or nil when no worktree has it.
    static func worktreeURL(forBranch branch: String, in repoRootURL: URL) async -> URL? {
        guard let output = try? await runGit(
            ["worktree", "list", "--porcelain"], in: repoRootURL)
        else { return nil }
        var path: URL?
        for raw in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix("worktree ") {
                path = URL(fileURLWithPath: String(line.dropFirst("worktree ".count)))
            } else if line.hasPrefix("branch refs/heads/") {
                if String(line.dropFirst("branch refs/heads/".count)) == branch {
                    return path
                }
            }
        }
        return nil
    }

    static func headStatus(in worktreeURL: URL) async -> GitHeadStatus? {
        guard let sha = try? await runGit(
            ["rev-parse", "--short", "HEAD"], in: worktreeURL)
        else { return nil }
        let branch = (try? await runGit(
            ["rev-parse", "--abbrev-ref", "HEAD"], in: worktreeURL)) ?? ""
        let numstat = (try? await runGit(
            ["diff", "HEAD", "--numstat"], in: worktreeURL)) ?? ""
        var insertions = 0
        var deletions = 0
        for line in numstat.split(separator: "\n") {
            let parts = line.split(separator: "\t")
            // Binary files report "-" for both counts; Int() skips them.
            if parts.count >= 2 {
                insertions += Int(parts[0]) ?? 0
                deletions += Int(parts[1]) ?? 0
            }
        }
        return GitHeadStatus(
            branch: branch.trimmingCharacters(in: .whitespacesAndNewlines),
            shortSHA: sha.trimmingCharacters(in: .whitespacesAndNewlines),
            insertions: insertions,
            deletions: deletions
        )
    }
}

// MARK: - Commit log and diff content

/// One commit in a worktree's trail — the commit-trail popover's row
/// model and the task-diff resolver's input.
struct CommitInfo: Equatable, Sendable, Identifiable {
    let sha: String
    let shortSHA: String
    let subject: String
    let authorDate: Date?
    let insertions: Int
    let deletions: Int
    var id: String { sha }
}

extension GitOperations {
    /// Commits on this worktree, newest first, with per-commit diff
    /// totals. `baseBranch` scopes to `<base>..HEAD` (the branch's own
    /// commits); when that range is empty or the base doesn't resolve
    /// (we're ON the default branch), fall back to plain HEAD history
    /// so the chip is never uselessly blank.
    ///
    /// Format: one `%H<TAB>%h<TAB>%s<TAB>%aI` line per commit followed
    /// by its --numstat lines (`ins<TAB>del<TAB>path`, "-" for binary)
    /// and a blank separator. Subjects can contain anything except \n,
    /// so the header line is parsed by splitting on TAB with a max of
    /// 4 fields.
    static func commitLog(
        in worktreeURL: URL,
        baseBranch: String?,
        limit: Int = 50
    ) async -> [CommitInfo] {
        let format = "--format=%H%x09%h%x09%s%x09%aI"
        var output: String?
        if let baseBranch {
            output = try? await runGit(
                ["log", format, "--numstat", "-n", String(limit), "\(baseBranch)..HEAD"],
                in: worktreeURL)
        }
        if output == nil || output?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
            output = try? await runGit(
                ["log", format, "--numstat", "-n", String(limit), "HEAD"],
                in: worktreeURL)
        }
        guard let output else { return [] }
        return parseCommitLog(output)
    }

    /// Split out for direct unit testing of the parsing edge cases
    /// (binary "-" numstat lines, tabs in nothing, blank separators).
    static func parseCommitLog(_ output: String) -> [CommitInfo] {
        var results: [CommitInfo] = []
        var current: (sha: String, short: String, subject: String, date: Date?)?
        var ins = 0, del = 0
        let isoParser = ISO8601DateFormatter()

        func flush() {
            if let c = current {
                results.append(CommitInfo(
                    sha: c.sha, shortSHA: c.short, subject: c.subject,
                    authorDate: c.date, insertions: ins, deletions: del))
            }
            current = nil; ins = 0; del = 0
        }

        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let fields = line.split(separator: "\t", maxSplits: 3,
                                    omittingEmptySubsequences: false)
            if fields.count == 4, fields[0].count == 40,
               fields[0].allSatisfy({ $0.isHexDigit }) {
                flush()
                current = (
                    sha: String(fields[0]),
                    short: String(fields[1]),
                    subject: String(fields[2]),
                    date: isoParser.date(from: String(fields[3]))
                )
            } else if fields.count == 3 {
                // numstat: ins<TAB>del<TAB>path; "-" for binary sides.
                if let i = Int(fields[0]) { ins += i }
                if let d = Int(fields[1]) { del += d }
            }
        }
        flush()
        return results
    }

    /// `git diff --name-status` between two revisions, or against the
    /// working tree when `to` is nil. Rename lines (`R100<TAB>old<TAB>new`)
    /// surface the NEW path with the "R…" status.
    static func changedFiles(
        from: String?,
        to: String?,
        in worktreeURL: URL
    ) async -> [(status: String, path: String)] {
        var args = ["diff", "--name-status"]
        if let from { args.append(from) }
        if let to { args.append(to) }
        guard let output = try? await runGit(args, in: worktreeURL) else { return [] }
        return output.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t",
                                   omittingEmptySubsequences: false)
            guard parts.count >= 2 else { return nil }
            let status = String(parts[0])
            let path = String(parts.last!)  // rename: last field is new path
            return (status: status, path: path)
        }
    }

    /// The repo's root commit (no parents). The commit-trail popover
    /// diffs it against git's empty tree because `<root>^` doesn't
    /// exist.
    static func rootCommitSHA(in worktreeURL: URL) async -> String? {
        guard let output = try? await runGit(
            ["rev-list", "--max-parents=0", "-n1", "HEAD"], in: worktreeURL)
        else { return nil }
        let sha = output.split(separator: "\n").first.map(String.init) ?? ""
        return sha.isEmpty ? nil : sha
    }

    /// Text content of `path` at `revision` (`git show rev:path`), or
    /// from the working tree when revision is nil. Returns nil when
    /// the file doesn't exist there or looks binary (NUL byte) — the
    /// diff viewer shows an empty side instead of garbage.
    static func fileContent(
        at path: String,
        revision: String?,
        in worktreeURL: URL
    ) async -> String? {
        if let revision {
            guard let output = try? await runGit(
                ["show", "\(revision):\(path)"], in: worktreeURL)
            else { return nil }
            if output.contains("\0") { return nil }
            // runGit's pipe decodes per-chunk as UTF-8 and silently
            // drops undecodable chunks — a binary blob can therefore
            // come back truncated or empty with no NUL byte to catch.
            // Trust the content only when its byte count matches the
            // blob size git reports; verified empirically that `git
            // show rev:path` streams the raw blob byte-for-byte (with
            // or without a trailing newline, including empty blobs),
            // so this is an exact equality check, not a tolerance.
            guard let sizeOutput = try? await runGit(
                ["cat-file", "-s", "\(revision):\(path)"], in: worktreeURL),
                  let size = Int(sizeOutput.trimmingCharacters(in: .whitespacesAndNewlines)),
                  output.utf8.count == size
            else { return nil }
            return output
        }
        let url = worktreeURL.appendingPathComponent(path)
        guard let data = try? Data(contentsOf: url) else { return nil }
        if data.contains(0) { return nil }
        return String(data: data, encoding: .utf8)
    }
}
