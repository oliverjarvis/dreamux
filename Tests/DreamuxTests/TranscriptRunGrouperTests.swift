import XCTest
@testable import Dreamux

final class TranscriptRunGrouperTests: XCTestCase {
    private func item(_ kind: TranscriptItem.Kind) -> TranscriptItem {
        TranscriptItem(kind: kind)
    }

    func testConsecutiveCallsCollapseAndTextBreaksRuns() {
        let items = [
            item(.userText("go")),
            item(.toolUse(id: "1", name: "Bash", input: "{}")),
            item(.toolResult(text: "ok", isError: false)),
            item(.toolUse(id: "2", name: "Read", input: "{}")),
            item(.toolResult(text: "ok", isError: false)),
            item(.assistantText("done")),
            item(.toolUse(id: "3", name: "Edit", input: "{}")),
            item(.toolResult(text: "ok", isError: false)),
        ]
        let blocks = TranscriptRunGrouper.blocks(from: items)
        // user, run(Bash+Read), assistant, then a single call stays two singles.
        XCTAssertEqual(blocks.count, 5)
        guard case .toolRun(let run) = blocks[1] else { return XCTFail("expected run, got \(blocks[1])") }
        XCTAssertEqual(run.count, 4)
        XCTAssertEqual(TranscriptRunGrouper.toolNames(in: run), ["Bash", "Read"])
        guard case .single = blocks[3] else { return XCTFail("single call must stay single") }
        guard case .single = blocks[4] else { return XCTFail("its result must stay single") }
    }

    func testTrailingUnresolvedCallIsTheRunningHint() {
        let run = [
            item(.toolUse(id: "1", name: "Bash", input: "{}")),
            item(.toolResult(text: "ok", isError: false)),
            item(.toolUse(id: "2", name: "Grep", input: "{}")),
        ]
        XCTAssertEqual(TranscriptRunGrouper.unresolvedTrailingCall(in: run), "Grep")
        XCTAssertNil(TranscriptRunGrouper.unresolvedTrailingCall(in: Array(run.prefix(2))))
        // Two calls collapse even while the second is unresolved.
        guard case .toolRun? = TranscriptRunGrouper.blocks(from: run).first else {
            return XCTFail("expected run")
        }
    }

    func testRunIdentityIsStableAcrossAppends() {
        var items = [
            item(.toolUse(id: "1", name: "Bash", input: "{}")),
            item(.toolResult(text: "ok", isError: false)),
            item(.toolUse(id: "2", name: "Read", input: "{}")),
        ]
        let before = TranscriptRunGrouper.blocks(from: items).first!.id
        items.append(item(.toolResult(text: "ok", isError: false)))
        let after = TranscriptRunGrouper.blocks(from: items).first!.id
        XCTAssertEqual(before, after, "expansion state must survive live appends")
    }
}
