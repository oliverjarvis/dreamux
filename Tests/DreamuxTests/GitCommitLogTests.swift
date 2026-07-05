import XCTest
@testable import Dreamux

/// The commit-trail popover and task diffs are built on these three
/// primitives; each test drives real git in a sandbox repo because
/// parsing (--numstat tabs, binary "-" lines, rename statuses) is
/// exactly where hand-rolled git plumbing goes wrong.
final class GitCommitLogTests: XCTestCase {
    private var sandbox: TestSandbox!

    /// Identity flags for commits the tests make directly, mirroring
    /// `GitOperationsTests` — `-c` covers author and committer, so the
    /// suite never depends on the machine's global git config.
    private let identity = [
        "-c", "user.name=Dreamux Tests",
        "-c", "user.email=tests@dreamux.local",
    ]

    override func setUpWithError() throws {
        // See GitOperationsTests: some entry points (none used directly
        // here, but git itself falls back to these env vars for the
        // author/committer identity of any commit made without -c) need
        // this exported so the suite works with no global git identity.
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

    // MARK: - testCommitLogParsesSubjectsStatsAndDates

    /// Two commits with known content: newest first, subjects intact,
    /// per-commit insertion/deletion totals correct, ISO author dates
    /// parsed. Binary changes ("-" numstat lines) must not poison the
    /// totals.
    func testCommitLogParsesSubjectsStatsAndDates() async throws {
        let repoURL = try await makeRepo(named: "repo")
        try write("one\ntwo\n", to: "a.txt", in: repoURL)
        _ = try await commit("First commit", in: repoURL)

        try write("one\ntwo\nthree\n", to: "a.txt", in: repoURL)
        try writeBinary(Data([0, 1, 2]), to: "b.bin", in: repoURL)
        _ = try await commit("Second commit", in: repoURL)

        let log = await GitOperations.commitLog(in: repoURL, baseBranch: nil)
        XCTAssertEqual(log.count, 2)
        XCTAssertEqual(log[0].subject, "Second commit")
        XCTAssertEqual(log[1].subject, "First commit")
        XCTAssertEqual(log[0].insertions, 1, "binary '-' lines are skipped")
        XCTAssertEqual(log[0].deletions, 0)
        XCTAssertEqual(log[1].insertions, 2)
        XCTAssertNotNil(log[0].authorDate)
        XCTAssertEqual(log[0].shortSHA.count, 7)
        XCTAssertTrue(log[0].sha.hasPrefix(log[0].shortSHA))
    }

    // MARK: - testCommitLogBaseBranchRangeAndFallback

    /// baseBranch scopes the log to branch-only commits; an empty
    /// range (HEAD == base) falls back to recent HEAD history rather
    /// than returning nothing — the chip on main still shows commits.
    func testCommitLogBaseBranchRangeAndFallback() async throws {
        let repoURL = try await makeRepo(named: "repo")
        try write("v1\n", to: "app.txt", in: repoURL)
        _ = try await commit("Main commit", in: repoURL)

        let featWorktree = sandbox.root.appendingPathComponent("repo-feat", isDirectory: true)
        _ = try await GitOperations.runGit(
            ["worktree", "add", "-b", "feat", featWorktree.path], in: repoURL)
        try write("f1\n", to: "f1.txt", in: featWorktree)
        _ = try await commit("Feat commit 1", in: featWorktree)
        try write("f2\n", to: "f2.txt", in: featWorktree)
        _ = try await commit("Feat commit 2", in: featWorktree)

        let branchOnly = await GitOperations.commitLog(in: featWorktree, baseBranch: "main")
        XCTAssertEqual(branchOnly.count, 2)

        let onMain = await GitOperations.commitLog(in: repoURL, baseBranch: "main")
        XCTAssertEqual(onMain.count, 1, "empty range falls back to HEAD history")
    }

    // MARK: - testCommitLogUnknownBaseFallsBackToHeadHistory

    /// The other fallback trigger: a base branch git can't resolve
    /// (deleted, typo) must fall back to HEAD history, not return [].
    func testCommitLogUnknownBaseFallsBackToHeadHistory() async throws {
        let repoURL = try await makeRepo(named: "repo")
        try write("v1\n", to: "app.txt", in: repoURL)
        _ = try await commit("Main commit", in: repoURL)

        let log = await GitOperations.commitLog(
            in: repoURL, baseBranch: "no-such-branch")
        XCTAssertFalse(log.isEmpty, "unknown base → plain HEAD history")
    }

    // MARK: - testChangedFilesRangeAndWorktree

    /// name-status across a range, and against the working tree when
    /// `to` is nil — the popover's "Uncommitted changes" row.
    func testChangedFilesRangeAndWorktree() async throws {
        let repoURL = try await makeRepo(named: "repo")
        try write("one\ntwo\n", to: "a.txt", in: repoURL)
        let shaA = try await commit("First commit", in: repoURL)

        try write("one\ntwo\nthree\n", to: "a.txt", in: repoURL)
        try write("new\n", to: "b.txt", in: repoURL)
        let shaB = try await commit("Second commit", in: repoURL)

        let range = await GitOperations.changedFiles(from: shaA, to: shaB, in: repoURL)
        XCTAssertTrue(range.contains { $0.status == "A" && $0.path == "b.txt" })
        XCTAssertTrue(range.contains { $0.status == "M" && $0.path == "a.txt" })

        // Dirty worktree: modify a.txt without committing.
        try write("one\ntwo\nthree\nlocal-edit\n", to: "a.txt", in: repoURL)
        let dirty = await GitOperations.changedFiles(from: "HEAD", to: nil, in: repoURL)
        XCTAssertEqual(dirty.map(\.path), ["a.txt"])
    }

    // MARK: - testChangedFilesReportsRename

    /// `git diff --name-status` detects renames by default (has since
    /// git 2.9, no `-M` needed) — a plain `git mv` + commit must surface
    /// as a single "R…" entry against the new path, not a delete+add.
    func testChangedFilesReportsRename() async throws {
        let repoURL = try await makeRepo(named: "repo")
        try write("line one\nline two\nline three\n", to: "old.txt", in: repoURL)
        let shaA = try await commit("First commit", in: repoURL)

        _ = try await GitOperations.runGit(
            ["mv", "old.txt", "new.txt"], in: repoURL)
        let shaB = try await commit("Rename commit", in: repoURL)

        let range = await GitOperations.changedFiles(from: shaA, to: shaB, in: repoURL)
        XCTAssertTrue(
            range.contains { $0.status.hasPrefix("R") && $0.path == "new.txt" },
            "expected a rename entry for new.txt, got \(range)")
    }

    // MARK: - testFileContentPerRevisionWorktreeMissingAndBinary

    /// git-show content per revision; worktree content when revision
    /// nil; nil for a path missing at that revision and for binary.
    func testFileContentPerRevisionWorktreeMissingAndBinary() async throws {
        let repoURL = try await makeRepo(named: "repo")
        try write("one\ntwo\n", to: "a.txt", in: repoURL)
        let shaA = try await commit("First commit", in: repoURL)

        try write("one\ntwo\nthree\n", to: "a.txt", in: repoURL)
        try writeBinary(Data([0, 1, 2]), to: "b.bin", in: repoURL)
        _ = try await commit("Second commit", in: repoURL)

        // Uncommitted local edit on top of the second commit.
        try write("one\ntwo\nthree\nlocal-edit\n", to: "a.txt", in: repoURL)

        let old = await GitOperations.fileContent(at: "a.txt", revision: shaA, in: repoURL)
        XCTAssertEqual(old, "one\ntwo\n")
        let live = await GitOperations.fileContent(at: "a.txt", revision: nil, in: repoURL)
        XCTAssertEqual(live, "one\ntwo\nthree\nlocal-edit\n")
        let missing = await GitOperations.fileContent(at: "b.txt", revision: shaA, in: repoURL)
        XCTAssertNil(missing, "b.txt does not exist at shaA")
        let binary = await GitOperations.fileContent(at: "b.bin", revision: nil, in: repoURL)
        XCTAssertNil(binary, "NUL bytes → treat as binary, no diff text")
    }

    // MARK: - testFileContentRevisionBinaryBlobWithoutNUL

    /// A binary blob with no NUL byte (e.g. a PNG header) must still
    /// come back nil at a revision: `runGit`'s output pipe decodes each
    /// chunk as UTF-8 and silently drops undecodable chunks, so a
    /// genuinely binary blob can round-trip through `git show` with no
    /// NUL surviving. The byte-count cross-check against `cat-file -s`
    /// catches that the string is truncated/corrupted relative to the
    /// real blob.
    func testFileContentRevisionBinaryBlobWithoutNUL() async throws {
        let repoURL = try await makeRepo(named: "repo")
        // PNG-like magic bytes: no 0x00 anywhere, but 0xFF/0xFE/0xFA are
        // not valid standalone UTF-8 continuation bytes, so decoding
        // drops or mangles them.
        let bytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0xFF, 0xFE, 0xFA])
        try writeBinary(bytes, to: "img.bin", in: repoURL)
        let sha = try await commit("Binary commit", in: repoURL)

        let content = await GitOperations.fileContent(at: "img.bin", revision: sha, in: repoURL)
        XCTAssertNil(content, "NUL-free binary must still be rejected via the byte-count check")
    }

    // MARK: - testFileContentRevisionEmptyFileIsNotBinary

    /// An empty text file at a revision is legitimate content ("") and
    /// must not be mistaken for binary/corrupted output — the
    /// byte-count check (0 == 0) must let it through.
    func testFileContentRevisionEmptyFileIsNotBinary() async throws {
        let repoURL = try await makeRepo(named: "repo")
        try write("", to: "empty.txt", in: repoURL)
        let sha = try await commit("Empty file commit", in: repoURL)

        let content = await GitOperations.fileContent(at: "empty.txt", revision: sha, in: repoURL)
        XCTAssertEqual(content, "", "empty file is valid text, not binary")
    }

    // MARK: - testRootCommitSHA

    /// The popover diffs the root commit against the empty tree — it
    /// needs to know which commit IS the root.
    func testRootCommitSHA() async throws {
        let repoURL = try await makeRepo(named: "repo")
        try write("one\ntwo\n", to: "a.txt", in: repoURL)
        let shaA = try await commit("First commit", in: repoURL)
        try write("one\ntwo\nthree\n", to: "a.txt", in: repoURL)
        _ = try await commit("Second commit", in: repoURL)

        let root = await GitOperations.rootCommitSHA(in: repoURL)
        XCTAssertEqual(root, shaA, "first commit in the fixture repo")
    }

    // MARK: - testParentRevisionGuardsRootCommit

    /// `<root>^` is an invalid revspec — `changedFiles` would fail
    /// silently (via `try?`) and render an empty diff with no error,
    /// since the caller's "matched" counter already incremented. For
    /// the root commit, `parentRevision` must return the empty-tree
    /// sentinel instead of a bogus `^` revspec; for any other commit
    /// it's the ordinary parent revspec.
    func testParentRevisionGuardsRootCommit() async throws {
        let repoURL = try await makeRepo(named: "repo")
        try write("one\ntwo\n", to: "a.txt", in: repoURL)
        let shaA = try await commit("First commit", in: repoURL)
        try write("one\ntwo\nthree\n", to: "a.txt", in: repoURL)
        let shaB = try await commit("Second commit", in: repoURL)

        let rootParent = await GitOperations.parentRevision(of: shaA, in: repoURL)
        XCTAssertEqual(rootParent, GitOperations.emptyTreeSHA)

        let ordinaryParent = await GitOperations.parentRevision(of: shaB, in: repoURL)
        XCTAssertEqual(ordinaryParent, "\(shaB)^")
    }

    // MARK: - Helpers

    /// A plain (non-bare) repo at `<sandbox>/<name>`, initialized on
    /// `main`. Simpler than the app's bare-plus-worktrees layout — these
    /// tests only need ordinary commit history, not `GitOperations`'
    /// worktree bookkeeping.
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

    private func writeBinary(_ data: Data, to name: String, in dir: URL) throws {
        try data.write(to: dir.appendingPathComponent(name))
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
