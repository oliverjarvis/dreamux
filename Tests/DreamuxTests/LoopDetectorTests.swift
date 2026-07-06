import XCTest
@testable import Dreamux

final class LoopDetectorTests: XCTestCase {
    private func completion(_ signature: String, error: Bool) -> ToolCompletion {
        ToolCompletion(signature: signature, isError: error, at: nil)
    }

    func testSignatureDerivation() {
        XCTAssertEqual(LoopDetector.signature(tool: "Bash", summary: "swift test --filter X"), "Bash:swift")
        XCTAssertEqual(LoopDetector.signature(tool: "Bash", summary: nil), "Bash")
        XCTAssertEqual(LoopDetector.signature(tool: "Bash", summary: "   "), "Bash")
        XCTAssertEqual(LoopDetector.signature(tool: "Edit", summary: "/a/b.swift"), "Edit")
        XCTAssertEqual(LoopDetector.signature(tool: "Read", summary: "whatever"), "Read")
    }

    func testSignatureNormalizesPathInvokedCommandsToBasename() {
        XCTAssertEqual(LoopDetector.signature(tool: "Bash", summary: "/Users/x/bin/foo --flag"), "Bash:foo")
        XCTAssertEqual(LoopDetector.signature(tool: "Bash", summary: "~/bin/run.sh go"), "Bash:run.sh")
        XCTAssertEqual(LoopDetector.signature(tool: "Bash", summary: "swift test"), "Bash:swift")
    }

    func testEditTestLoopDetectsDespiteInterleaving() {
        // edit → test(fail) → edit → test(fail) → edit → test(fail)
        let window = [
            completion("Edit", error: false), completion("Bash:swift", error: true),
            completion("Edit", error: false), completion("Bash:swift", error: true),
            completion("Edit", error: false), completion("Bash:swift", error: true),
        ]
        XCTAssertEqual(LoopDetector.detect(window: window), DetectedLoop(signature: "Bash:swift", count: 3))
    }

    func testTwoOccurrencesIsNotALoop() {
        let window = [
            completion("Bash:swift", error: true), completion("Edit", error: false),
            completion("Bash:swift", error: true),
        ]
        XCTAssertNil(LoopDetector.detect(window: window))
    }

    func testNeedsTwoErrorsAmongOccurrences() {
        // 3 occurrences but only the last errored — a command that mostly
        // works isn't a loop yet.
        let window = [
            completion("Bash:swift", error: false), completion("Bash:swift", error: false),
            completion("Bash:swift", error: true),
        ]
        XCTAssertNil(LoopDetector.detect(window: window))
    }

    func testClearedWhenNewestOccurrenceSucceeds() {
        // Failing streak then a pass: the loop resolved.
        let window = [
            completion("Bash:swift", error: true), completion("Bash:swift", error: true),
            completion("Bash:swift", error: true), completion("Bash:swift", error: false),
        ]
        XCTAssertNil(LoopDetector.detect(window: window))
    }

    func testCountIsOccurrencesInWindow() {
        let window = [
            completion("Bash:swift", error: true), completion("Bash:swift", error: true),
            completion("Bash:swift", error: true), completion("Bash:swift", error: true),
        ]
        XCTAssertEqual(LoopDetector.detect(window: window)?.count, 4)
    }

    func testMostOccurrencesWinsTieMostRecent() {
        // Two qualifying signatures: npm has 3, swift has 3; swift completed
        // more recently → swift wins the tie.
        let window = [
            completion("Bash:npm", error: true), completion("Bash:swift", error: true),
            completion("Bash:npm", error: true), completion("Bash:swift", error: true),
            completion("Bash:npm", error: true), completion("Bash:swift", error: true),
        ]
        XCTAssertEqual(LoopDetector.detect(window: window)?.signature, "Bash:swift")
        // And a clear majority beats recency:
        let window2 = window + [completion("Bash:npm", error: true)]
        XCTAssertEqual(LoopDetector.detect(window: window2)?.signature, "Bash:npm")
        XCTAssertEqual(LoopDetector.detect(window: window2)?.count, 4)
    }

    func testEmptyWindowIsNil() {
        XCTAssertNil(LoopDetector.detect(window: []))
    }
}
