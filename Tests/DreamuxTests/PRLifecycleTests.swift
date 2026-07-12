import XCTest
@testable import Dreamux

final class PRLifecycleTests: XCTestCase {
    private func lifecycle(_ json: String) throws -> PRLifecycle {
        let data = json.data(using: .utf8)!
        return try JSONDecoder().decode(GhOperations.PRDetailPayload.self, from: data).lifecycle
    }
    private func json(state: String = "OPEN", draft: Bool = false,
                      review: String = "", rollup: String = "[]") -> String {
        #"{"state":"\#(state)","url":"u","isDraft":\#(draft),"reviewDecision":"\#(review)","statusCheckRollup":\#(rollup)}"#
    }
    func testMergedWinsOverEverything() throws {
        XCTAssertEqual(try lifecycle(json(state: "MERGED", review: "CHANGES_REQUESTED")), .merged)
    }
    func testClosed() throws { XCTAssertEqual(try lifecycle(json(state: "CLOSED")), .closed) }
    func testDraftBeatsFailingChecks() throws {
        XCTAssertEqual(try lifecycle(json(draft: true,
            rollup: #"[{"status":"COMPLETED","conclusion":"FAILURE"}]"#)), .draft)
    }
    func testChangesRequestedBeatsChecks() throws {
        XCTAssertEqual(try lifecycle(json(review: "CHANGES_REQUESTED",
            rollup: #"[{"status":"IN_PROGRESS"}]"#)), .changesRequested)
    }
    func testCheckRunFailure() throws {
        XCTAssertEqual(try lifecycle(json(rollup: #"[{"status":"COMPLETED","conclusion":"SUCCESS"},{"status":"COMPLETED","conclusion":"FAILURE"}]"#)), .checksFailed)
    }
    func testCheckRunRunning() throws {
        XCTAssertEqual(try lifecycle(json(rollup: #"[{"status":"IN_PROGRESS"}]"#)), .checksRunning)
    }
    func testStatusContextFailure() throws {
        XCTAssertEqual(try lifecycle(json(rollup: #"[{"state":"FAILURE"}]"#)), .checksFailed)
    }
    func testApprovedWhenChecksPass() throws {
        XCTAssertEqual(try lifecycle(json(review: "APPROVED",
            rollup: #"[{"status":"COMPLETED","conclusion":"SUCCESS"}]"#)), .approved)
    }
    func testOpenIsDefault() throws { XCTAssertEqual(try lifecycle(json()), .open) }

    func testEveryLifecycleHasSymbolAndLabel() {
        for s in PRLifecycle.allCases {
            XCTAssertFalse(PRStatusGlyph.symbol(s).isEmpty, "\(s)")
            XCTAssertFalse(PRStatusGlyph.label(s).isEmpty, "\(s)")
        }
    }
}
