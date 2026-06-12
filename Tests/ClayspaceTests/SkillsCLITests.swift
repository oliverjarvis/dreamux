import XCTest
@testable import Clayspace

/// Integration tests for SkillsCLI against the fake `skills` fixture —
/// asserts exact argv/cwd construction and JSON parsing, no node/npm.
@MainActor
final class SkillsCLITests: XCTestCase {
    private var sandbox: TestSandbox!
    private var projectRoot: URL!
    private var globalDir: URL!
    private var logURL: URL!

    /// Repo-relative fixture path, resolved the same way other tests
    /// reach Tests/Fixtures (#filePath-relative).
    static var fakeSkillsBin: String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // ClayspaceTests
            .deletingLastPathComponent()  // Tests
            .appendingPathComponent("Fixtures/bin/skills").path
    }

    override func setUp() async throws {
        sandbox = try TestSandbox()
        projectRoot = try sandbox.makeProject(named: "proj").rootPath
        globalDir = projectRoot.deletingLastPathComponent()
            .appendingPathComponent("fake-global", isDirectory: true)
        logURL = projectRoot.deletingLastPathComponent()
            .appendingPathComponent("invocations.jsonl")
        setenv("CLAYSPACE_SKILLS_BIN", Self.fakeSkillsBin, 1)
        setenv("SKILLS_FAKE_GLOBAL_DIR", globalDir.path, 1)
        setenv("SKILLS_FAKE_LOG", logURL.path, 1)
    }

    override func tearDown() async throws {
        unsetenv("CLAYSPACE_SKILLS_BIN")
        unsetenv("SKILLS_FAKE_GLOBAL_DIR")
        unsetenv("SKILLS_FAKE_LOG")
        sandbox?.destroy()
        sandbox = nil
    }

    private var cli: SkillsCLI { SkillsCLI(nodeBinDirectory: nil) }

    private func loggedInvocations() throws -> [[String: Any]] {
        let text = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
        return text.split(separator: "\n").compactMap {
            try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
        }
    }

    func testAddInstallsAndLocksAgents() async throws {
        try await cli.add(
            source: "vercel-labs/agent-skills",
            skills: ["web-design-guidelines"],
            extraAgents: ["cursor"],
            scope: .project(projectRoot)
        )
        // Canonical copy in the project root.
        let canonical = projectRoot.appendingPathComponent(
            ".agents/skills/web-design-guidelines/SKILL.md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: canonical.path))

        // Exact argv: locked agents always present, extras appended,
        // -y always, cwd = project root.
        let invocation = try XCTUnwrap(loggedInvocations().last)
        let argv = try XCTUnwrap(invocation["argv"] as? [String])
        XCTAssertEqual(argv, [
            "add", "vercel-labs/agent-skills",
            "-s", "web-design-guidelines",
            "-a", "claude-code", "codex", "cursor",
            "-y",
        ])
        XCTAssertEqual(invocation["cwd"] as? String, "/private" + projectRoot.path)
    }

    func testAddGlobalPassesG() async throws {
        try await cli.add(
            source: "anthropics/skills", skills: ["s1"], extraAgents: [], scope: .global
        )
        let argv = try XCTUnwrap(loggedInvocations().last?["argv"] as? [String])
        XCTAssertTrue(argv.contains("-g"))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: globalDir.appendingPathComponent(".agents/skills/s1/SKILL.md").path))
    }

    func testListParsesBothScopes() async throws {
        try await cli.add(source: "a/b", skills: ["p1"], extraAgents: [], scope: .project(projectRoot))
        try await cli.add(source: "a/b", skills: ["g1"], extraAgents: [], scope: .global)

        let project = try await cli.list(scope: .project(projectRoot))
        XCTAssertEqual(project.map(\.name), ["p1"])
        XCTAssertEqual(project.first?.scope, "project")

        let global = try await cli.list(scope: .global)
        XCTAssertEqual(global.map(\.name), ["g1"])
        XCTAssertEqual(global.first?.isGlobal, true)
    }

    func testRemoveDeletesInstall() async throws {
        try await cli.add(source: "a/b", skills: ["p1"], extraAgents: [], scope: .project(projectRoot))
        try await cli.remove(skills: ["p1"], scope: .project(projectRoot))
        let remaining = try await cli.list(scope: .project(projectRoot))
        XCTAssertTrue(remaining.isEmpty)
        // Invocations: add, remove, list — remove is second-to-last.
        let invocations = try loggedInvocations()
        let removeInvocation = try XCTUnwrap(invocations.dropLast().last)
        let argv = try XCTUnwrap(removeInvocation["argv"] as? [String])
        XCTAssertEqual(argv, ["remove", "-s", "p1", "-a", "*", "-y"])
    }

    func testNodeUnavailableWithoutOverride() async {
        unsetenv("CLAYSPACE_SKILLS_BIN")
        do {
            _ = try await SkillsCLI(nodeBinDirectory: nil).list(scope: .global)
            XCTFail("expected nodeUnavailable")
        } catch SkillsCLIError.nodeUnavailable {
        } catch { XCTFail("unexpected error: \(error)") }
    }
}
