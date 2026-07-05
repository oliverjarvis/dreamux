import XCTest
@testable import Dreamux

/// Merge semantics for `.mcp.json`: the installer must add or refresh
/// the dreamux-signals entry without ever clobbering other servers or
/// a malformed file — agents' hand-written config is not ours to lose.
final class MCPInstallerTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-install-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Pin the script override so tests don't depend on this
        // machine's dev-checkout layout.
        let script = dir.appendingPathComponent("dreamux-signals-mcp.ts")
        try "// stub".write(to: script, atomically: true, encoding: .utf8)
        UserDefaults.standard.set(script.path, forKey: MCPInstaller.scriptPathDefaultsKey)
    }

    override func tearDownWithError() throws {
        UserDefaults.standard.removeObject(forKey: MCPInstaller.scriptPathDefaultsKey)
        try? FileManager.default.removeItem(at: dir)
    }

    private func readServers(in base: URL? = nil) throws -> [String: Any] {
        let data = try Data(contentsOf: (base ?? dir).appendingPathComponent(".mcp.json"))
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (root?["mcpServers"] as? [String: Any]) ?? [:]
    }

    func testFreshInstallDefaultsEnvScopeToInstallDir() throws {
        let result = MCPInstaller.installIfNeeded(at: dir.path)
        guard case .installed = result else {
            return XCTFail("expected .installed, got \(result)")
        }
        let servers = try readServers()
        let entry = servers["dreamux-signals"] as? [String: Any]
        XCTAssertNotNil(entry)
        let env = entry?["env"] as? [String: String]
        XCTAssertEqual(env?["DREAMUX_PROJECT_DIR"], dir.path,
                       "no explicit scope: the install dir IS the project root "
                       + "(planning tab, sidebar, SignalsView repair button)")
        if case .installed = MCPInstaller.status(at: dir.path) {} else {
            XCTFail("status should read back installed")
        }
    }

    func testExplicitProjectScopeOverridesInstallDirInEnv() throws {
        // Plan runs install into `<project>/features/<branch>` (where the
        // agent runs), but every signal is tagged with the project ROOT
        // (ProjectSession). The env must carry the root, or the agent's
        // queries and emits are scoped to a dir no signal ever matches.
        let featureDir = dir.appendingPathComponent("features/my-branch")
        try FileManager.default.createDirectory(
            at: featureDir, withIntermediateDirectories: true)

        let result = MCPInstaller.installIfNeeded(
            at: featureDir.path, projectScope: dir.path)
        guard case .installed = result else {
            return XCTFail("expected .installed, got \(result)")
        }
        let servers = try readServers(in: featureDir)
        let entry = servers["dreamux-signals"] as? [String: Any]
        let env = entry?["env"] as? [String: String]
        XCTAssertEqual(env?["DREAMUX_PROJECT_DIR"], dir.path,
                       "agents run in feature subdirs; scoping must pin the project root")
    }

    func testExistingServersArePreserved() throws {
        let existing = ["mcpServers": ["other": ["command": "/bin/echo"]]]
        let data = try JSONSerialization.data(withJSONObject: existing, options: [.prettyPrinted])
        try data.write(to: dir.appendingPathComponent(".mcp.json"))

        _ = MCPInstaller.installIfNeeded(at: dir.path)

        let servers = try readServers()
        XCTAssertNotNil(servers["other"], "merge must not drop unrelated servers")
        XCTAssertNotNil(servers["dreamux-signals"])
    }

    func testMalformedJSONIsNotClobbered() throws {
        let url = dir.appendingPathComponent(".mcp.json")
        try "{ not json".write(to: url, atomically: true, encoding: .utf8)

        let result = MCPInstaller.installIfNeeded(at: dir.path)
        if case .skippedReason = result {} else {
            XCTFail("malformed file must be left alone, got \(result)")
        }
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "{ not json")
    }

    func testWorkingEntryIsNotRewrittenWithoutForce() throws {
        _ = MCPInstaller.installIfNeeded(at: dir.path)
        let before = try Data(contentsOf: dir.appendingPathComponent(".mcp.json"))
        let second = MCPInstaller.installIfNeeded(at: dir.path)
        if case .alreadyInstalled = second {} else {
            XCTFail("idempotence: got \(second)")
        }
        XCTAssertEqual(before, try Data(contentsOf: dir.appendingPathComponent(".mcp.json")),
                       "no git churn from repeated session starts")
    }

    func testStaleReferenceIsRefreshed() throws {
        let url = dir.appendingPathComponent(".mcp.json")
        let stale = ["mcpServers": ["dreamux-signals": ["command": "/bun", "args": ["run", "/gone.ts"]]]]
        try JSONSerialization.data(withJSONObject: stale).write(to: url)

        let result = MCPInstaller.installIfNeeded(at: dir.path)
        if case .installed = result {} else {
            XCTFail("stale path must be refreshed, got \(result)")
        }
    }
}
