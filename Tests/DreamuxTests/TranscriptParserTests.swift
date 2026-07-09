import XCTest
@testable import Dreamux

final class TranscriptParserTests: XCTestCase {
    /// A representative Claude transcript: string + block user content,
    /// assistant thinking/text/tool_use, a tool_result, a summary, a skipped
    /// metadata line, and a malformed line.
    func testParsesTheTranscriptShapes() {
        let jsonl = """
        {"type":"user","message":{"role":"user","content":"hello there"}}
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"thinking","thinking":"let me think"},{"type":"text","text":"hi!"},{"type":"tool_use","name":"Bash","id":"t1","input":{"command":"ls"}}]}}
        {"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"file.txt","is_error":false}]}}
        {"type":"summary","summary":"A short chat"}
        {"type":"mode","mode":"x"}
        {not valid json}
        """
        let items = TranscriptParser.parse(jsonl)
        let kinds = items.map(\.kind)

        // mode line is skipped; every other line contributes.
        XCTAssertEqual(items.count, 7)

        guard case .userText(let u) = kinds[0], u == "hello there" else {
            return XCTFail("expected user text, got \(kinds[0])")
        }
        guard case .thinking = kinds[1] else { return XCTFail("expected thinking, got \(kinds[1])") }
        guard case .assistantText(let a) = kinds[2], a == "hi!" else {
            return XCTFail("expected assistant text, got \(kinds[2])")
        }
        guard case .toolUse(let name, let input) = kinds[3], name == "Bash" else {
            return XCTFail("expected tool_use Bash, got \(kinds[3])")
        }
        XCTAssertTrue(input.contains("\"command\""))
        XCTAssertTrue(input.contains("ls"))
        guard case .toolResult(let text, let isError) = kinds[4], text == "file.txt", !isError else {
            return XCTFail("expected tool_result, got \(kinds[4])")
        }
        guard case .summary(let s) = kinds[5], s == "A short chat" else {
            return XCTFail("expected summary, got \(kinds[5])")
        }
        guard case .raw = kinds[6] else { return XCTFail("expected raw for malformed line, got \(kinds[6])") }
    }

    /// A non-transcript JSONL still renders — each line becomes a raw entry.
    func testGenericJsonlFallsBackToRaw() {
        let items = TranscriptParser.parse("""
        {"a":1,"b":2}
        {"c":3}
        """)
        XCTAssertEqual(items.count, 2)
        for item in items {
            guard case .raw = item.kind else { return XCTFail("expected raw, got \(item.kind)") }
        }
    }
}
