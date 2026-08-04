import XCTest
@testable import Dreamux

final class HarnessRegistryTests: XCTestCase {
    var sandbox: TestSandbox!

    override func setUpWithError() throws { sandbox = try TestSandbox() }
    override func tearDown() { sandbox.destroy(); sandbox = nil }

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func testShippedCatalogDecodesAndDescribesClaude() throws {
        let url = repoRoot.appendingPathComponent("Tools/harnesses.json")
        let catalog = HarnessRegistry.load(from: url)
        let claude = try XCTUnwrap(catalog.harnesses.first { $0.id == "claude" })
        XCTAssertEqual(claude.displayName, "Claude Code")
        XCTAssertEqual(claude.binaryNames, ["claude"])
        XCTAssertEqual(claude.strategy, .processInjection)

        let permission = try XCTUnwrap(claude.events["Notification:permission_prompt"])
        XCTAssertEqual(permission.state, "blocked")
        XCTAssertEqual(permission.reason, "permission")

        let completed = try XCTUnwrap(claude.events["Notification:agent_completed"])
        XCTAssertEqual(completed.state, "done")

        let stop = try XCTUnwrap(claude.events["Stop"])
        XCTAssertEqual(stop.state, "done")
        XCTAssertEqual(stop.messageField, "last_assistant_message")

        XCTAssertEqual(claude.events["SessionEnd"]?.state, "none")
        XCTAssertEqual(claude.events["UserPromptSubmit"]?.state, "working")
        XCTAssertEqual(claude.events["PreToolUse"]?.state, "working")
    }

    func testMalformedCatalogFallsBackToClaudeOnly() throws {
        let bad = sandbox.root.appendingPathComponent("bad.json")
        try "{ not json".write(to: bad, atomically: true, encoding: .utf8)
        let catalog = HarnessRegistry.load(from: bad)
        XCTAssertEqual(catalog.harnesses.map(\.id), ["claude"])
        XCTAssertEqual(catalog.harnesses.first?.events["Stop"]?.state, "done")
    }

    func testMissingCatalogFallsBackToClaudeOnly() {
        let catalog = HarnessRegistry.load(from: nil)
        XCTAssertEqual(catalog.harnesses.map(\.id), ["claude"])
    }

    func testEmptyHarnessListFallsBackToClaudeOnly() throws {
        let empty = sandbox.root.appendingPathComponent("empty.json")
        try #"{"version":1,"harnesses":[]}"#.write(to: empty, atomically: true, encoding: .utf8)
        XCTAssertEqual(HarnessRegistry.load(from: empty).harnesses.map(\.id), ["claude"])
    }

    /// `@MainActor` because `HarnessRegistry` is: Swift 6 will not let a
    /// nonisolated test call its init or `adapter(id:)`.
    @MainActor
    func testAdapterLookupByID() throws {
        let url = repoRoot.appendingPathComponent("Tools/harnesses.json")
        let registry = HarnessRegistry(catalog: HarnessRegistry.load(from: url))
        XCTAssertEqual(registry.adapter(id: "claude")?.displayName, "Claude Code")
        XCTAssertNil(registry.adapter(id: "nope"))
    }
}
