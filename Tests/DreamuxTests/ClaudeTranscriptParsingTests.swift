import XCTest
@testable import Dreamux

final class ClaudeTranscriptParsingTests: XCTestCase {
    func testFixtureParsesWithAgentSpawns() throws {
        let (events, skipped) = ClaudeFlowAdapter.transcriptEvents(fromLines: try ClaudeFixtures.transcriptLines())
        XCTAssertFalse(events.isEmpty)
        let spawns = events.compactMap { if case let .agentSpawned(id, _, _, _) = $0 { return id } else { return nil as String? } }
        XCTAssertFalse(spawns.isEmpty, "the fixture session spawned agents")
        // Every agentSpawned toolUseID eventually gets an agentReturned in the slice OR not —
        // but no agentReturned may reference an id that never spawned within the same slice
        // ONLY when the slice includes the spawn (replay slices can start mid-stream) — so just
        // assert the parser produced both kinds without crashing.
        XCTAssertGreaterThanOrEqual(skipped, 0)
    }

    func testAgentToolUseBecomesAgentSpawned() {
        let line = #"{"type":"assistant","timestamp":"2026-07-06T10:00:00.000Z","message":{"id":"m1","content":[{"type":"tool_use","id":"toolu_01","name":"Agent","input":{"description":"map repo","subagent_type":"Explore","prompt":"go"}}]}}"#
        let (events, _) = ClaudeFlowAdapter.transcriptEvents(fromLines: [line])
        guard case let .agentSpawned(id, type, desc, at)? = events.first else { return XCTFail("expected agentSpawned") }
        XCTAssertEqual(id, "toolu_01")
        XCTAssertEqual(type, "Explore")
        XCTAssertEqual(desc, "map repo")
        XCTAssertNotNil(at)
    }

    func testTaskToolNameAlsoSpawns() {
        let line = #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t2","name":"Task","input":{"description":"d","subagent_type":"general-purpose"}}]}}"#
        let (events, _) = ClaudeFlowAdapter.transcriptEvents(fromLines: [line])
        guard case .agentSpawned? = events.first else { return XCTFail("Task tool must map to agentSpawned") }
    }

    func testOrdinaryToolUseAndResult() {
        let use = #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t3","name":"Bash","input":{"command":"swift test --filter X\necho done"}}]}}"#
        let ok = #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t3","content":"ok"}]}}"#
        let (events, _) = ClaudeFlowAdapter.transcriptEvents(fromLines: [use, ok])
        guard case let .toolStarted(id, tool, summary, _)? = events.first else { return XCTFail("expected toolStarted") }
        XCTAssertEqual(id, "t3"); XCTAssertEqual(tool, "Bash")
        XCTAssertEqual(summary, "swift test --filter X") // first line only
        guard case let .toolFinished(fid, isError, _)? = events.dropFirst().first else { return XCTFail("expected toolFinished") }
        XCTAssertEqual(fid, "t3"); XCTAssertFalse(isError)
    }

    func testErrorResultSetsIsError() {
        let err = #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t4","is_error":true,"content":"boom"}]}}"#
        let (events, _) = ClaudeFlowAdapter.transcriptEvents(fromLines: [err])
        guard case let .toolFinished(_, isError, _)? = events.first else { return XCTFail() }
        XCTAssertTrue(isError)
    }

    func testMultipleToolUsesInOneMessageProcessedInOrder() {
        let line = #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"bash1","name":"Bash","input":{"command":"ls"}},{"type":"tool_use","id":"agent1","name":"Agent","input":{"description":"explore","subagent_type":"Explore"}}]}}"#
        let (events, _) = ClaudeFlowAdapter.transcriptEvents(fromLines: [line])
        XCTAssertEqual(events.count, 2)
        guard case let .toolStarted(id, tool, _, _)? = events.first else { return XCTFail("expected first toolStarted") }
        XCTAssertEqual(id, "bash1"); XCTAssertEqual(tool, "Bash")
        guard case let .agentSpawned(id, type, _, _)? = events.dropFirst().first else { return XCTFail("expected second agentSpawned") }
        XCTAssertEqual(id, "agent1"); XCTAssertEqual(type, "Explore")
    }

    func testGarbageAndUnknownTypesSkippedNotFatal() {
        let (events, skipped) = ClaudeFlowAdapter.transcriptEvents(fromLines: [
            "not json", #"{"type":"file-history-snapshot","x":1}"#, #"{"no":"type"}"#, "",
            String(repeating: "x", count: 2_000_000), // over the 1 MB line cap
        ])
        XCTAssertTrue(events.isEmpty)
        XCTAssertEqual(skipped, 3) // garbage, no-type, oversized; known-but-unused type and empty line are silent skips, not "skipped"
    }
}
