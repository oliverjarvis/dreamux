import XCTest
@testable import Dreamux

/// DiffTabSession's model layer: file-list loading from a real repo
/// and content-pair resolution per revision. The Monaco push itself is
/// visual (verified in Task 7); what must be right here is WHICH
/// content lands on each side for adds, edits, deletes, and the
/// worktree ("uncommitted") case.
@MainActor
final class DiffTabSessionTests: XCTestCase {
    private var sandbox: TestSandbox!

    /// Identity flags for commits the tests make directly, mirroring
    /// `GitCommitLogTests` — `-c` covers author and committer, so the
    /// suite never depends on the machine's global git config.
    private let identity = [
        "-c", "user.name=Dreamux Tests",
        "-c", "user.email=tests@dreamux.local",
    ]

    override func setUpWithError() throws {
        setenv("GIT_AUTHOR_NAME", "Dreamux Tests", 1)
        setenv("GIT_AUTHOR_EMAIL", "tests@dreamux.local", 1)
        setenv("GIT_COMMITTER_NAME", "Dreamux Tests", 1)
        setenv("GIT_COMMITTER_EMAIL", "tests@dreamux.local", 1)

        sandbox = try TestSandbox()
    }

    override func tearDown() {
        sandbox?.destroy()
        sandbox = nil
        super.tearDown()
    }

    func testLoadsChangedFilesForRange() async throws {
        let (repoURL, shaA, shaB) = try await makeThreeStageRepo()
        let session = DiffTabSession(request: DiffRequest(
            worktreeURL: repoURL, fromRevision: shaA, toRevision: shaB,
            title: "A → B"))
        await session.loadForTesting()
        XCTAssertEqual(Set(session.files.map(\.path)), ["a.txt", "b.txt"])
        XCTAssertEqual(session.selectedPath, session.files.first?.path,
                       "first file auto-selected")
        XCTAssertFalse(session.isLoading)
    }

    func testContentPairsPerStatus() async throws {
        let (repoURL, shaA, shaB) = try await makeThreeStageRepo()
        let session = DiffTabSession(request: DiffRequest(
            worktreeURL: repoURL, fromRevision: shaA, toRevision: shaB,
            title: "A → B"))
        await session.loadForTesting()
        let edited = await session.contentPair(for: "a.txt")
        XCTAssertEqual(edited.original, "one\n")
        XCTAssertEqual(edited.modified, "one\ntwo\n")
        let added = await session.contentPair(for: "b.txt")
        XCTAssertNil(added.original, "added file has no original side")
        XCTAssertNotNil(added.modified)
    }

    func testWorktreeSideWhenToRevisionNil() async throws {
        let (repoURL, _, _) = try await makeThreeStageRepo()
        let session = DiffTabSession(request: DiffRequest(
            worktreeURL: repoURL, fromRevision: "HEAD", toRevision: nil,
            title: "Uncommitted"))
        await session.loadForTesting()
        let pair = await session.contentPair(for: "a.txt")
        XCTAssertEqual(pair.modified, "one\ntwo\nthree\n",
                       "nil toRevision reads the live worktree file")
    }

    // MARK: - Fixture

    /// Shared history every test above reads a different slice of:
    /// commit A (a.txt = "one\n"), commit B (a.txt = "one\ntwo\n", b.txt
    /// added), then an uncommitted worktree edit on top
    /// (a.txt = "one\ntwo\nthree\n") — the popover's "Uncommitted
    /// changes" row.
    private func makeThreeStageRepo() async throws -> (repoURL: URL, shaA: String, shaB: String) {
        let repoURL = try await makeRepo(named: "repo")
        try write("one\n", to: "a.txt", in: repoURL)
        let shaA = try await commit("First commit", in: repoURL)

        try write("one\ntwo\n", to: "a.txt", in: repoURL)
        try write("b contents\n", to: "b.txt", in: repoURL)
        let shaB = try await commit("Second commit", in: repoURL)

        try write("one\ntwo\nthree\n", to: "a.txt", in: repoURL)
        return (repoURL, shaA, shaB)
    }

    // MARK: - Helpers (mirrors GitCommitLogTests)

    /// A plain (non-bare) repo at `<sandbox>/<name>`, initialized on
    /// `main`.
    private func makeRepo(named name: String) async throws -> URL {
        let url = sandbox.root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        _ = try await GitOperations.runGit(["init", "-b", "main"], in: url)
        return url
    }

    private func write(_ contents: String, to name: String, in dir: URL) throws {
        try contents.write(
            to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8
        )
    }

    /// Stage everything, commit with the test identity, and return the
    /// new HEAD sha (trimmed) so tests can pin revisions by value.
    @discardableResult
    private func commit(_ message: String, in repo: URL) async throws -> String {
        _ = try await GitOperations.runGit(["add", "-A"], in: repo)
        _ = try await GitOperations.runGit(identity + ["commit", "-m", message], in: repo)
        return try await GitOperations.runGit(["rev-parse", "HEAD"], in: repo)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
