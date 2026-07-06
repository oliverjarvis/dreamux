import XCTest
@testable import Dreamux

final class ClaudeFixturesTests: XCTestCase {
    func testTranscriptLinesAreSubstantialAndWellFormed() throws {
        let lines = try ClaudeFixtures.transcriptLines()
        XCTAssertGreaterThan(lines.count, 100)

        var sawAgentToolUse = false
        for line in lines {
            let data = try XCTUnwrap(line.data(using: .utf8))
            let json = try XCTUnwrap(
                try JSONSerialization.jsonObject(with: data) as? [String: Any]
            )
            XCTAssertNotNil(json["type"], "every kept line should carry a type")
            if line.contains("\"Agent\"") {
                sawAgentToolUse = true
            }
        }
        XCTAssertTrue(sawAgentToolUse, "fixture should retain at least one Agent tool_use")
    }

    func testSubagentMetaURLs() throws {
        let urls = try ClaudeFixtures.subagentMetaURLs()
        XCTAssertGreaterThanOrEqual(urls.count, 2)
        for url in urls {
            XCTAssertTrue(url.lastPathComponent.hasSuffix(".meta.json"))
        }
    }

    func testAgentTranscriptLinesParse() throws {
        let lines = try ClaudeFixtures.agentTranscriptLines()
        XCTAssertGreaterThan(lines.count, 0)
        for line in lines {
            let data = try XCTUnwrap(line.data(using: .utf8))
            XCTAssertNotNil(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
    }

    func testRedactionHeld() throws {
        let transcript = try ClaudeFixtures.transcriptLines()
        let agentLines = try ClaudeFixtures.agentTranscriptLines()
        for line in transcript + agentLines {
            XCTAssertFalse(line.contains("@"), "redacted fixture should never contain \"@\"")
        }
    }
}
