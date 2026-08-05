import XCTest
@testable import Dreamux

/// WorktreeEnvironment against real git repos (TestSandbox +
/// GitFixtures), modelled on SkillLinkerTests: every worktree gets all
/// three artifacts, `git status` stays clean, a second pass changes
/// nothing, and anything the repo already owns is left alone.
@MainActor
final class WorktreeEnvironmentTests: XCTestCase {
    private var sandbox: TestSandbox!
    private var project: Project!
    private var alpha: Repository!

    override func setUp() async throws {
        setenv("GIT_AUTHOR_NAME", "Dreamux Tests", 1)
        setenv("GIT_AUTHOR_EMAIL", "tests@dreamux.local", 1)
        setenv("GIT_COMMITTER_NAME", "Dreamux Tests", 1)
        setenv("GIT_COMMITTER_EMAIL", "tests@dreamux.local", 1)
        sandbox = try TestSandbox()
        project = try sandbox.makeProject(named: "proj")
        alpha = try await GitFixtures.makeBareLayoutRepo(
            in: project.rootPath, name: "alpha", files: ["alpha.txt": "a\n"])
        try await GitOperations.addWorktree(in: alpha.rootURL, branch: "feature-x")
        // Pin the MCP runner so `.mcp.json` lands deterministically
        // regardless of this machine's dev-checkout layout, exactly as
        // MCPInstallerTests does.
        let script = sandbox.root.appendingPathComponent("dreamux-signals-mcp.ts")
        try "// stub".write(to: script, atomically: true, encoding: .utf8)
        UserDefaults.standard.set(script.path, forKey: MCPInstaller.scriptPathDefaultsKey)
    }

    override func tearDown() async throws {
        UserDefaults.standard.removeObject(forKey: MCPInstaller.scriptPathDefaultsKey)
        sandbox?.destroy()
        sandbox = nil
    }

    private func worktree(_ branch: String) -> URL {
        alpha.rootURL.appendingPathComponent(branch, isDirectory: true)
    }

    private func settingsURL(_ branch: String) -> URL {
        worktree(branch).appendingPathComponent(".claude/settings.local.json")
    }

    private func sessionStartEntries(_ branch: String) throws -> [[String: Any]] {
        let data = try Data(contentsOf: settingsURL(branch))
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let hooks = root?["hooks"] as? [String: Any]
        return (hooks?["SessionStart"] as? [[String: Any]]) ?? []
    }

    private func commands(in entry: [String: Any]) -> [String] {
        ((entry["hooks"] as? [[String: Any]]) ?? []).compactMap { $0["command"] as? String }
    }

    // MARK: - The happy path

    func testEquipsEveryWorktreeAndKeepsGitClean() async throws {
        WorktreeEnvironment.reconcile(projectRoot: project.rootPath)
        let fm = FileManager.default

        for branch in ["main", "feature-x"] {
            let wt = worktree(branch)

            // 1. .mcp.json, scoped to the PROJECT root — not the worktree.
            let mcp = try JSONSerialization.jsonObject(
                with: Data(contentsOf: wt.appendingPathComponent(".mcp.json"))) as? [String: Any]
            let servers = mcp?["mcpServers"] as? [String: Any]
            let entry = servers?["dreamux-signals"] as? [String: Any]
            XCTAssertNotNil(entry, "\(branch): dreamux-signals entry missing")
            XCTAssertEqual((entry?["env"] as? [String: String])?["DREAMUX_PROJECT_DIR"],
                           project.rootPath.path)

            // 2. project-docs → the PROJECT docs home, relatively.
            let link = wt.appendingPathComponent("project-docs")
            let dest = try fm.destinationOfSymbolicLink(atPath: link.path)
            XCTAssertEqual(dest, "../../../docs", "\(branch): link must be relative")
            XCTAssertTrue(fm.fileExists(atPath: link.appendingPathComponent("plans").path),
                          "\(branch): project-docs must resolve to the docs home")

            // 3. Exactly one SessionStart entry, ours, with repo and
            //    branch interpolated.
            let entries = try sessionStartEntries(branch)
            XCTAssertEqual(entries.count, 1, "\(branch): expected one SessionStart entry")
            XCTAssertEqual(entries[0]["matcher"] as? String, "startup|clear|compact")
            let hook = (entries[0]["hooks"] as? [[String: Any]])?.first
            XCTAssertEqual(hook?["type"] as? String, "command")
            XCTAssertEqual(hook?["shell"] as? String, "bash")
            XCTAssertEqual(hook?["async"] as? Bool, false)
            let command = hook?["command"] as? String ?? ""
            XCTAssertTrue(command.contains(WorktreeEnvironment.hookSentinel))
            XCTAssertTrue(command.contains("`alpha`"), "\(branch): repo name missing")
            XCTAssertTrue(command.contains("branch `\(branch)`"), "\(branch): branch missing")
            XCTAssertTrue(command.contains("project-docs/"))

            // The load-bearing assertion: zero git noise.
            let status = try await GitOperations.runGit(["status", "--porcelain"], in: wt)
            XCTAssertEqual(status.trimmingCharacters(in: .whitespacesAndNewlines), "",
                           "\(branch) must stay git-clean")
        }
    }

    func testSecondPassChangesNothing() async throws {
        WorktreeEnvironment.reconcile(projectRoot: project.rootPath)
        let excludeURL = alpha.rootURL.appendingPathComponent(".bare/info/exclude")
        let exclude = try String(contentsOf: excludeURL, encoding: .utf8)
        let settings = try Data(contentsOf: settingsURL("main"))
        let mcp = try Data(contentsOf: worktree("main").appendingPathComponent(".mcp.json"))

        let report = WorktreeEnvironment.reconcile(projectRoot: project.rootPath)

        XCTAssertTrue(report.skipped.isEmpty, "unexpected skips: \(report.skipped)")
        XCTAssertEqual(try String(contentsOf: excludeURL, encoding: .utf8), exclude)
        XCTAssertEqual(try Data(contentsOf: settingsURL("main")), settings)
        XCTAssertEqual(
            try Data(contentsOf: worktree("main").appendingPathComponent(".mcp.json")), mcp)
        XCTAssertEqual(try sessionStartEntries("main").count, 1,
                       "the hook entry must be replaced, never appended twice")
    }

    // MARK: - Merging into a file that already has user content

    func testExistingSettingsContentSurvivesTheMerge() throws {
        let url = settingsURL("main")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #"{"enabledMcpjsonServers":["dreamux-signals"]}"#.write(
            to: url, atomically: true, encoding: .utf8)

        WorktreeEnvironment.reconcile(projectRoot: project.rootPath)

        let root = try JSONSerialization.jsonObject(
            with: Data(contentsOf: url)) as? [String: Any]
        XCTAssertEqual(root?["enabledMcpjsonServers"] as? [String], ["dreamux-signals"])
        XCTAssertEqual(try sessionStartEntries("main").count, 1)
    }

    func testForeignSessionStartHookIsNotRemoved() throws {
        let url = settingsURL("main")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #"""
        {"hooks":{"SessionStart":[{"matcher":"startup","hooks":[{"type":"command","command":"echo someone-elses-hook"}]}]}}
        """#.write(to: url, atomically: true, encoding: .utf8)

        WorktreeEnvironment.reconcile(projectRoot: project.rootPath)

        let entries = try sessionStartEntries("main")
        XCTAssertEqual(entries.count, 2, "the foreign entry must survive alongside ours")
        XCTAssertTrue(entries.contains { commands(in: $0).contains("echo someone-elses-hook") })
        XCTAssertEqual(
            entries.filter { commands(in: $0).contains { $0.contains(WorktreeEnvironment.hookSentinel) } }.count,
            1)
    }

    // MARK: - The shared exclude file

    func testExcludeBlockCoexistsWithSkillLinkerAndUserContent() throws {
        let excludeURL = alpha.rootURL.appendingPathComponent(".bare/info/exclude")
        try FileManager.default.createDirectory(
            at: excludeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "# my stuff\nnode_modules/\n".write(
            to: excludeURL, atomically: true, encoding: .utf8)
        let skillDir = project.rootPath.appendingPathComponent(
            ".agents/skills/foo", isDirectory: true)
        try FileManager.default.createDirectory(at: skillDir, withIntermediateDirectories: true)
        try "---\nname: foo\n---\n".write(
            to: skillDir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)

        SkillLinker.reconcile(projectRoot: project.rootPath)
        WorktreeEnvironment.reconcile(projectRoot: project.rootPath)

        let text = try String(contentsOf: excludeURL, encoding: .utf8)
        XCTAssertTrue(text.contains("# my stuff"))
        XCTAssertTrue(text.contains("node_modules/"))
        XCTAssertTrue(text.contains("/.agents/skills/foo"),
                      "SkillLinker's block must survive our write")
        for pattern in WorktreeEnvironment.excludePatterns {
            XCTAssertTrue(text.contains(pattern), "missing \(pattern)")
        }
        XCTAssertEqual(
            text.components(separatedBy: WorktreeEnvironment.excludeBlockStart).count - 1, 1,
            "our block must appear exactly once")
    }

    // MARK: - Anything that isn't ours

    func testRepoWithoutBareIsSkippedWholesale() throws {
        let foreign = project.rootPath.appendingPathComponent("repos/foreign/main", isDirectory: true)
        try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: true)
        try "gitdir: ...".write(
            to: foreign.appendingPathComponent(".git"), atomically: true, encoding: .utf8)

        WorktreeEnvironment.reconcile(projectRoot: project.rootPath)

        let fm = FileManager.default
        XCTAssertFalse(fm.fileExists(atPath: foreign.appendingPathComponent(".mcp.json").path))
        XCTAssertNil(try? fm.destinationOfSymbolicLink(
            atPath: foreign.appendingPathComponent("project-docs").path))
        XCTAssertFalse(fm.fileExists(
            atPath: foreign.appendingPathComponent(".claude/settings.local.json").path))
    }

    func testRealProjectDocsDirectoryIsSkippedAndReported() throws {
        let owned = worktree("main").appendingPathComponent("project-docs", isDirectory: true)
        try FileManager.default.createDirectory(at: owned, withIntermediateDirectories: true)
        try "repo-owned\n".write(
            to: owned.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)

        let report = WorktreeEnvironment.reconcile(projectRoot: project.rootPath)

        XCTAssertNil(try? FileManager.default.destinationOfSymbolicLink(atPath: owned.path),
                     "a real directory must not be replaced by a symlink")
        XCTAssertEqual(
            try String(contentsOf: owned.appendingPathComponent("README.md"), encoding: .utf8),
            "repo-owned\n")
        XCTAssertTrue(report.skipped.contains { $0.contains(owned.path) },
                      "skipped must mention it, got \(report.skipped)")
    }

    func testTrackedSettingsFileIsSkippedAndReported() async throws {
        let url = settingsURL("main")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #"{"tracked":true}"#.write(to: url, atomically: true, encoding: .utf8)
        // `-f`: a developer's own `~/.config/git/ignore` may well list
        // `.claude/settings.local.json` (git reads that path by default,
        // no core.excludesFile needed), and a plain `add` would silently
        // stage nothing — leaving this test asserting against an
        // UNtracked file, which is the opposite of its point.
        _ = try await GitOperations.runGit(["add", "-f", "-A"], in: worktree("main"))
        _ = try await GitOperations.runGit(
            ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-m", "own settings"],
            in: worktree("main"))

        let report = WorktreeEnvironment.reconcile(projectRoot: project.rootPath)

        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), #"{"tracked":true}"#,
                       "a tracked file is never ours to rewrite")
        XCTAssertTrue(report.skipped.contains { $0.contains(url.path) },
                      "skipped must mention it, got \(report.skipped)")
        // The other two artifacts still land — one collision doesn't
        // disqualify the worktree.
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: worktree("main").appendingPathComponent(".mcp.json").path))
    }
}
