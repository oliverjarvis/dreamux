import Foundation
@testable import Clayspace

/// Helpers for building real git repositories inside a `TestSandbox`.
/// They shell out to the system `git` via `GitOperations.runGit` so the
/// fixtures exercise exactly the same plumbing the app uses.
///
/// Commits always pass `-c user.name`/`-c user.email` explicitly, so
/// the suite works on machines (and CI) with no global git identity.
enum GitFixtures {
    /// Identity flags prefixed onto every commit. `-c` covers both the
    /// author and the committer, which is all `git commit` needs.
    private static let identity = [
        "-c", "user.name=Clayspace Tests",
        "-c", "user.email=tests@clayspace.local",
    ]

    /// Create a plain repository at `url` (init -b main), write `files`
    /// (`relative/path` → contents, intermediate directories created),
    /// and commit everything. This is the simple shape for tests that
    /// don't need the bare-plus-worktrees layout.
    static func makeCommittedRepo(
        at url: URL,
        files: [String: String]
    ) async throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        _ = try await GitOperations.runGit(["init", "-b", "main"], in: url)
        try write(files, into: url)
        _ = try await GitOperations.runGit(["add", "-A"], in: url)
        _ = try await GitOperations.runGit(
            identity + ["commit", "-m", "Fixture commit"],
            in: url
        )
    }

    /// Build the Clayspace `repos/<name>/{.bare, main}` layout inside a
    /// project root via `GitOperations.initBare`, then write and commit
    /// `files` in the `main` worktree. Returns the `Repository` so the
    /// caller can reach `rootURL` / `worktrees` directly.
    ///
    /// Note `initBare` itself drops a starter README.md; the fixture
    /// commit sits on top of it (or absorbs it, on machines where the
    /// starter commit was skipped for lack of a git identity).
    @discardableResult
    static func makeBareLayoutRepo(
        in projectRoot: URL,
        name: String,
        files: [String: String]
    ) async throws -> Repository {
        let repository = try await GitOperations.initBare(into: projectRoot, name: name)
        let mainWorktree = repository.rootURL
            .appendingPathComponent(repository.defaultBranch, isDirectory: true)
        try write(files, into: mainWorktree)
        _ = try await GitOperations.runGit(["add", "-A"], in: mainWorktree)
        _ = try await GitOperations.runGit(
            identity + ["commit", "-m", "Add fixture files"],
            in: mainWorktree
        )
        return repository
    }

    /// Write each `relative path → contents` pair below `root`,
    /// creating intermediate directories as needed.
    private static func write(_ files: [String: String], into root: URL) throws {
        for (relativePath, contents) in files {
            let target = root.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(
                at: target.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try contents.write(to: target, atomically: true, encoding: .utf8)
        }
    }
}
