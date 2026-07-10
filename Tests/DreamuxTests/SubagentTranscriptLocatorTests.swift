import XCTest
@testable import Dreamux

final class SubagentTranscriptLocatorTests: XCTestCase {
    var sandbox: TestSandbox!
    override func setUpWithError() throws { sandbox = try TestSandbox() }
    override func tearDown() { sandbox.destroy(); sandbox = nil }

    /// Shape a temp dir like a real Claude Code session:
    /// `<root>/<uuid>.jsonl` (the parent transcript) alongside
    /// `<root>/<uuid>/subagents/agent-1.meta.json` (the sidecar joining a
    /// parent tool_use id to its child) and the child `agent-1.jsonl` itself.
    @discardableResult
    private func makeSession(
        toolUseID: String, writeAgentJSONL: Bool = true
    ) throws -> (parent: URL, agentJSONL: URL) {
        let uuid = UUID().uuidString
        let parent = sandbox.root.appendingPathComponent("\(uuid).jsonl")
        try "{}\n".write(to: parent, atomically: true, encoding: .utf8)
        let subagents = sandbox.root
            .appendingPathComponent(uuid)
            .appendingPathComponent("subagents")
        try FileManager.default.createDirectory(at: subagents, withIntermediateDirectories: true)
        let meta = subagents.appendingPathComponent("agent-1.meta.json")
        try #"{"toolUseId":"\#(toolUseID)","spawnDepth":1}"#
            .write(to: meta, atomically: true, encoding: .utf8)
        let agentJSONL = subagents.appendingPathComponent("agent-1.jsonl")
        if writeAgentJSONL {
            try "{}\n".write(to: agentJSONL, atomically: true, encoding: .utf8)
        }
        return (parent, agentJSONL)
    }

    func testResolvesMatchingToolUseID() throws {
        let session = try makeSession(toolUseID: "tu-1")
        let found = SubagentTranscriptLocator.transcript(
            forToolUseID: "tu-1", parentTranscript: session.parent)
        // Compare resolved paths: `contentsOfDirectory` canonicalizes the
        // temp dir's /var → /private/var symlink, the sandbox root doesn't.
        XCTAssertEqual(
            found?.resolvingSymlinksInPath(),
            session.agentJSONL.resolvingSymlinksInPath())
    }

    func testUnknownToolUseIDReturnsNil() throws {
        let session = try makeSession(toolUseID: "tu-1")
        XCTAssertNil(SubagentTranscriptLocator.transcript(
            forToolUseID: "tu-other", parentTranscript: session.parent))
    }

    func testMissingSubagentsDirectoryReturnsNil() throws {
        let uuid = UUID().uuidString
        let parent = sandbox.root.appendingPathComponent("\(uuid).jsonl")
        try "{}\n".write(to: parent, atomically: true, encoding: .utf8)
        XCTAssertNil(SubagentTranscriptLocator.transcript(
            forToolUseID: "tu-1", parentTranscript: parent))
    }

    func testMatchingMetaButMissingTranscriptReturnsNil() throws {
        let session = try makeSession(toolUseID: "tu-1", writeAgentJSONL: false)
        XCTAssertNil(SubagentTranscriptLocator.transcript(
            forToolUseID: "tu-1", parentTranscript: session.parent))
    }
}
