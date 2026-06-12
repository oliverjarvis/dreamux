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

    func testPrivateSpelledProjectRootSurvivesInstallAndUninstall() async throws {
        // TestSandbox lives under temporaryDirectory (/var/folders/…),
        // which macOS also exposes as /private/var/folders/… — the same
        // directory under two spellings. All identity and relative-path
        // math must be lexical: URL.standardizedFileURL strips /private
        // only when the path EXISTS, so existence-dependent
        // normalization mixes spellings (root-crossing link targets) and
        // flips link identity across install/uninstall (leaked links).
        let varPath = project.rootPath.path
        guard varPath.hasPrefix("/var/") else {
            throw XCTSkip("sandbox is not under /var/, so there is no /private alias to exercise")
        }
        let privateRoot = URL(fileURLWithPath: "/private" + varPath, isDirectory: true)
        guard FileManager.default.fileExists(atPath: privateRoot.path) else {
            throw XCTSkip("/private spelling does not resolve on this machine")
        }

        try installCanonicalSkill("foo")
        SkillLinker.reconcile(projectRoot: privateRoot)

        let fm = FileManager.default
        for agentDir in [".agents", ".claude"] {
            let link = mainWorktree().appendingPathComponent("\(agentDir)/skills/foo")
            // repos/<repo>/<branch>/<agentDir>/skills → project root is
            // exactly five ups, whatever the root spelling. A
            // root-crossing target like ../../../../../../private/…
            // means the math mixed spellings.
            XCTAssertEqual(
                try fm.destinationOfSymbolicLink(atPath: link.path),
                "../../../../../.agents/skills/foo",
                "\(agentDir) link target must be pure component math")
        }

        // Uninstall, then reconcile under the same /private spelling.
        // The canonical dir no longer exists, so any existence-dependent
        // normalization stops recognizing our links and leaks them.
        try fm.removeItem(at: project.rootPath.appendingPathComponent(".agents/skills/foo"))
        SkillLinker.reconcile(projectRoot: privateRoot)

        for agentDir in [".agents", ".claude"] {
            let link = mainWorktree().appendingPathComponent("\(agentDir)/skills/foo")
            XCTAssertNil(
                try? fm.destinationOfSymbolicLink(atPath: link.path),
                "stale link \(link.path) must be removed")
            XCTAssertFalse(fm.fileExists(atPath: link.path))
        }
    }

    func testExcludeFilePreservesUserContent() async throws {
        let excludeURL = alpha.rootURL.appendingPathComponent(".bare/info/exclude")
        try FileManager.default.createDirectory(
            at: excludeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "# my stuff\nnode_modules/\n*.log\n".write(
            to: excludeURL, atomically: true, encoding: .utf8)

        try installCanonicalSkill("foo")
        SkillLinker.reconcile(projectRoot: project.rootPath)

        var exclude = try String(contentsOf: excludeURL, encoding: .utf8)
        XCTAssertTrue(exclude.contains("# my stuff"))
        XCTAssertTrue(exclude.contains("node_modules/"))
        XCTAssertTrue(exclude.contains("*.log"))
        XCTAssertTrue(exclude.contains(SkillLinker.excludeBlockStart))
        XCTAssertTrue(exclude.contains("/.agents/skills/foo"))
        XCTAssertTrue(exclude.contains("/.claude/skills/foo"))

        // Uninstall: managed block disappears, user content survives.
        try FileManager.default.removeItem(
            at: project.rootPath.appendingPathComponent(".agents/skills/foo"))
        SkillLinker.reconcile(projectRoot: project.rootPath)

        exclude = try String(contentsOf: excludeURL, encoding: .utf8)
        XCTAssertTrue(exclude.contains("# my stuff"))
        XCTAssertTrue(exclude.contains("node_modules/"))
        XCTAssertTrue(exclude.contains("*.log"))
        XCTAssertFalse(exclude.contains(SkillLinker.excludeBlockStart))
        XCTAssertFalse(exclude.contains("foo"))
    }

    func testForeignSymlinkIsSkippedAndReported() async throws {
        // A symlink someone else put where our link would go, pointing
        // somewhere outside the canonical store.
        let elsewhere = sandbox.root.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let foreign = mainWorktree().appendingPathComponent(".claude/skills/foo")
        try FileManager.default.createDirectory(
            at: foreign.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            atPath: foreign.path, withDestinationPath: elsewhere.path)

        try installCanonicalSkill("foo")
        let report = SkillLinker.reconcile(projectRoot: project.rootPath)

        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: foreign.path),
            elsewhere.path,
            "foreign symlink must not be retargeted or removed")
        XCTAssertEqual(report.skipped.count, 1)
        XCTAssertTrue(
            report.skipped.contains { $0.contains(foreign.path) },
            "skipped must mention the foreign link, got \(report.skipped)")
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

    func testProvisionLinksProjectSkillsIntoNewWorktree() async throws {
        try installCanonicalSkill("foo")
        // No explicit reconcile: provisioning itself must wire the links.
        _ = try await FeatureProvisioner.provision(
            featureName: "feature-y", in: project, across: [alpha])

        let worktree = alpha.rootURL.appendingPathComponent("feature-y", isDirectory: true)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: worktree.appendingPathComponent(".agents/skills/foo/SKILL.md").path))
        let status = try await GitOperations.runGit(["status", "--porcelain"], in: worktree)
        XCTAssertEqual(status.trimmingCharacters(in: .whitespacesAndNewlines), "")
    }
}
