import XCTest
@testable import Dreamux

final class TranscriptAccumulatorTests: XCTestCase {
    private let fixture = """
    {"type":"user","message":{"role":"user","content":"hello"}}
    {"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"hi!"}]}}
    {"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"q1","name":"AskUserQuestion","input":{"questions":[{"question":"Pick one?","header":"Pick","multiSelect":false,"options":[{"label":"A","description":"first"},{"label":"B","description":"second"}]}]}}]}}
    {"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"q1","content":"A"}]}}

    """

    func testChunkedFeedMatchesWholeParseAndBuffersPartialLines() {
        let whole = TranscriptParser.parse(fixture)
        let acc = TranscriptAccumulator()
        let bytes = Array(fixture.utf8)
        // Split at awkward offsets: mid-line, mid-JSON.
        for chunk in [bytes[0..<50], bytes[50..<51], bytes[51..<200], bytes[200...]] {
            acc.feed(Data(chunk))
        }
        XCTAssertEqual(acc.items.count, whole.count)
        // No trailing partial: last line ended with \n.
        XCTAssertNil(acc.pendingQuestion)
    }

    func testPendingQuestionAppearsThenClears() {
        let lines = fixture.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        let acc = TranscriptAccumulator()
        acc.feed(Data((lines[0] + "\n" + lines[1] + "\n").utf8))
        XCTAssertNil(acc.pendingQuestion)
        acc.feed(Data((lines[2] + "\n").utf8))
        let q = acc.pendingQuestion
        XCTAssertEqual(q?.toolUseID, "q1")
        XCTAssertEqual(q?.questions.first?.text, "Pick one?")
        XCTAssertEqual(q?.questions.first?.multiSelect, false)
        XCTAssertEqual(q?.questions.first?.options.map(\.label), ["A", "B"])
        acc.feed(Data((lines[3] + "\n").utf8))
        XCTAssertNil(acc.pendingQuestion)
    }

    func testFeedReturnsOnlyNewItems() {
        let acc = TranscriptAccumulator()
        let first = acc.feed(Data("{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"a\"}}\n".utf8))
        XCTAssertEqual(first.count, 1)
        let none = acc.feed(Data("{\"type\":\"user\",\"message\":".utf8)) // partial
        XCTAssertTrue(none.isEmpty)
        let second = acc.feed(Data("{\"role\":\"user\",\"content\":\"b\"}}\n".utf8))
        XCTAssertEqual(second.count, 1)
        XCTAssertEqual(acc.items.count, 2)
    }
}
