import XCTest
@testable import Dreamux

final class FuzzyMatcherTests: XCTestCase {
    func testNonSubsequenceReturnsNil() {
        XCTAssertNil(FuzzyMatcher.match("xyz", in: "main"))
    }

    func testSubsequenceMatches() {
        XCTAssertNotNil(FuzzyMatcher.match("wsp", in: "workspace"))
    }

    func testQueryLongerThanTargetReturnsNil() {
        XCTAssertNil(FuzzyMatcher.match("planning", in: "plan"))
    }

    func testEmptyQueryMatchesWithZeroScore() {
        XCTAssertEqual(FuzzyMatcher.match("", in: "anything"),
                       FuzzyMatch(score: 0, matchedOffsets: []))
    }

    func testCaseInsensitive() {
        XCTAssertNotNil(FuzzyMatcher.match("READ", in: "readme.md"))
    }

    func testMatchedOffsets() {
        XCTAssertEqual(FuzzyMatcher.match("rm", in: "readme")?.matchedOffsets, [0, 4])
    }

    func testPrefixBeatsMidWord() {
        let prefix = FuzzyMatcher.match("pla", in: "plans.md")!
        let midWord = FuzzyMatcher.match("pla", in: "templates.md")!
        XCTAssertGreaterThan(prefix.score, midWord.score)
    }

    func testBoundaryBeatsScattered() {
        let boundary = FuzzyMatcher.match("np", in: "new plan")!
        let scattered = FuzzyMatcher.match("np", in: "snapshot")!
        XCTAssertGreaterThan(boundary.score, scattered.score)
    }

    func testShorterTargetWinsTie() {
        let short = FuzzyMatcher.match("plan", in: "plan.md")!
        let long = FuzzyMatcher.match("plan", in: "plan-archive-2024.md")!
        XCTAssertGreaterThan(short.score, long.score)
    }
}
