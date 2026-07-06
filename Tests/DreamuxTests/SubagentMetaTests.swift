import XCTest
@testable import Dreamux

final class SubagentMetaTests: XCTestCase {
    var sandbox: TestSandbox!
    override func setUpWithError() throws { sandbox = try TestSandbox() }
    override func tearDown() { sandbox.destroy(); sandbox = nil }

    func testParsesFixtureMetas() throws {
        for url in try ClaudeFixtures.subagentMetaURLs() {
            let meta = SubagentMeta.parse(url: url)
            XCTAssertNotNil(meta, "fixture meta failed to parse: \(url.lastPathComponent)")
            XCTAssertFalse(meta!.agentID.isEmpty)
        }
    }

    func testAgentIDComesFromFilename() throws {
        let url = sandbox.root.appendingPathComponent("agent-abc123.meta.json")
        try #"{"agentType":"Explore","description":"d","toolUseId":"toolu_9","spawnDepth":1}"#
            .write(to: url, atomically: true, encoding: .utf8)
        let meta = try XCTUnwrap(SubagentMeta.parse(url: url))
        XCTAssertEqual(meta.agentID, "abc123")
        XCTAssertEqual(meta.toolUseID, "toolu_9")
        XCTAssertEqual(meta.agentType, "Explore")
        XCTAssertEqual(meta.spawnDepth, 1)
    }

    func testUnknownKeysAndMissingFieldsTolerated() throws {
        let url = sandbox.root.appendingPathComponent("agent-x.meta.json")
        try #"{"name":"teammate","taskKind":"in_process_teammate","weird":[1,2]}"#
            .write(to: url, atomically: true, encoding: .utf8)
        let meta = try XCTUnwrap(SubagentMeta.parse(url: url))
        XCTAssertEqual(meta.agentID, "x")
        XCTAssertNil(meta.toolUseID)
    }

    func testMalformedReturnsNil() throws {
        let url = sandbox.root.appendingPathComponent("agent-y.meta.json")
        try "not json".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertNil(SubagentMeta.parse(url: url))
    }

    func testLastActivityFromAgentLines() throws {
        let lines = [
            #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"swift build"}}]}}"#,
            #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t2","name":"Read","input":{"file_path":"/a/b.swift"}}]}}"#,
        ]
        XCTAssertEqual(ClaudeFlowAdapter.lastActivity(fromAgentLines: lines), "/a/b.swift")
        XCTAssertNil(ClaudeFlowAdapter.lastActivity(fromAgentLines: ["garbage"]))
    }

    func testFixtureAgentTranscriptYieldsActivity() throws {
        // The fixture agent file contains at least one tool_use.
        XCTAssertNotNil(ClaudeFlowAdapter.lastActivity(fromAgentLines: try ClaudeFixtures.agentTranscriptLines()))
    }
}
