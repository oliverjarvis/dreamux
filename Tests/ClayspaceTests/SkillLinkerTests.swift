import XCTest
@testable import Clayspace

/// SkillLinker tests against real git repos (TestSandbox + GitFixtures):
/// links in every worktree, exclude entries keep `git status` clean,
/// reconcile is idempotent, never touches repo-owned files, and cleans
/// up after uninstalls.
@MainActor
final class SkillLinkerTests: XCTestCase {
    private var sandbox: TestSandbox!
    private var project: Project!
    private var alpha: Repository!

    override func setUp() async throws {
        setenv("GIT_AUTHOR_NAME", "Clayspace Tests", 1)
        setenv("GIT_AUTHOR_EMAIL", "tests@clayspace.local", 1)
        setenv("GIT_COMMITTER_NAME", "Clayspace Tests", 1)
        setenv("GIT_COMMITTER_EMAIL", "tests@clayspace.local", 1)
        sandbox = try TestSandbox()
        project = try sandbox.makeProject(named: "proj")
        alpha = try await GitFixtures.makeBareLayoutRepo(
            in: project.rootPath, name: "alpha", files: ["alpha.txt": "a\n"]
        )
    }

    override func tearDown() async throws {
        sandbox?.destroy()
        sandbox = nil
    }

    /// Drop a canonical project skill the way `npx skills add` would.
    private func installCanonicalSkill(_ name: String) throws {
        let dir = project.rootPath.appendingPathComponent(
            ".agents/skills/\(name)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "---\nname: \(name)\n---\nbody\n".write(
            to: dir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
    }

    private func mainWorktree() -> URL {
        alpha.rootURL.appendingPathComponent("main", isDirectory: true)
    }

    func testReconcileLinksSkillIntoWorktreeAndKeepsGitClean() async throws {
        try installCanonicalSkill("foo")
        let report = SkillLinker.reconcile(projectRoot: project.rootPath)
        XCTAssertTrue(report.skipped.isEmpty)

        let fm = FileManager.default
        for agentDir in [".agents", ".claude"] {
            let link = mainWorktree().appendingPathComponent("\(agentDir)/skills/foo")
            let dest = try fm.destinationOfSymbolicLink(atPath: link.path)
            // Relative target that resolves to the canonical copy.
            XCTAssertFalse(dest.hasPrefix("/"), "link must be relative, got \(dest)")
            let resolved = URL(fileURLWithPath: dest,
                               relativeTo: link.deletingLastPathComponent()).standardizedFileURL
            XCTAssertEqual(resolved.path,
                           project.rootPath.appendingPathComponent(".agents/skills/foo").standardizedFileURL.path)
            // Reading through the link proves it resolves.
            XCTAssertTrue(fm.fileExists(atPath: link.appendingPathComponent("SKILL.md").path))
        }

        // The load-bearing assertion: zero git noise.
        let status = try await GitOperations.runGit(["status", "--porcelain"], in: mainWorktree())
        XCTAssertEqual(status.trimmingCharacters(in: .whitespacesAndNewlines), "")
    }

    func testReconcileCoversFeatureWorktrees() async throws {
        try installCanonicalSkill("foo")
        _ = try await FeatureProvisioner.provision(
            featureName: "feature-x", in: project, across: [alpha])
        SkillLinker.reconcile(projectRoot: project.rootPath)

        let featureWorktree = alpha.rootURL.appendingPathComponent("feature-x", isDirectory: true)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: featureWorktree.appendingPathComponent(".agents/skills/foo/SKILL.md").path))
        let status = try await GitOperations.runGit(["status", "--porcelain"], in: featureWorktree)
        XCTAssertEqual(status.trimmingCharacters(in: .whitespacesAndNewlines), "")
    }

    func testReconcileIsIdempotent() async throws {
        try installCanonicalSkill("foo")
        SkillLinker.reconcile(projectRoot: project.rootPath)
        let excludeURL = alpha.rootURL.appendingPathComponent(".bare/info/exclude")
        let before = try String(contentsOf: excludeURL, encoding: .utf8)

        let second = SkillLinker.reconcile(projectRoot: project.rootPath)
        XCTAssertTrue(second.skipped.isEmpty)
        XCTAssertEqual(try String(contentsOf: excludeURL, encoding: .utf8), before)
    }

    func testRepoOwnedSkillIsNeverTouched() async throws {
        // A committed skill with the same name already in the worktree.
        let owned = mainWorktree().appendingPathComponent(".claude/skills/foo", isDirectory: true)
        try FileManager.default.createDirectory(at: owned, withIntermediateDirectories: true)
        try "repo-owned\n".write(
            to: owned.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        _ = try await GitOperations.runGit(["add", "-A"], in: mainWorktree())
        _ = try await GitOperations.runGit(
            ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-m", "own skill"],
            in: mainWorktree())

        try installCanonicalSkill("foo")
        let report = SkillLinker.reconcile(projectRoot: project.rootPath)

        XCTAssertEqual(report.skipped.count, 1)
        var isSymlink = false
        if let values = try? owned.resourceValues(forKeys: [.isSymbolicLinkKey]) {
            isSymlink = values.isSymbolicLink ?? false
        }
        XCTAssertFalse(isSymlink, "repo-owned dir must not be replaced")
        XCTAssertEqual(
            try String(contentsOf: owned.appendingPathComponent("SKILL.md"), encoding: .utf8),
            "repo-owned\n")
    }

    func testUninstalledSkillLinksAreRemoved() async throws {
        try installCanonicalSkill("foo")
        SkillLinker.reconcile(projectRoot: project.rootPath)
        // Uninstall: canonical dir disappears (what `skills remove` does).
        try FileManager.default.removeItem(
            at: project.rootPath.appendingPathComponent(".agents/skills/foo"))
        SkillLinker.reconcile(projectRoot: project.rootPath)

        for agentDir in [".agents", ".claude"] {
            let link = mainWorktree().appendingPathComponent("\(agentDir)/skills/foo")
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: link.path)
                || (try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) != nil,
                "stale link \(link.path) must be removed")
        }
        // Exclude block is emptied too.
        let exclude = (try? String(
            contentsOf: alpha.rootURL.appendingPathComponent(".bare/info/exclude"),
            encoding: .utf8)) ?? ""
        XCTAssertFalse(exclude.contains("foo"))
    }
}
