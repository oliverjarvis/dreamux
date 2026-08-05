import XCTest
@testable import Dreamux

final class AttentionGlyphTests: XCTestCase {

    func testBlockedIsAFilledGlyph() throws {
        let glyph = try XCTUnwrap(AttentionGlyph(
            .blocked(Blocked(reason: .permission, message: nil, toolName: nil, requestID: nil))
        ))
        XCTAssertEqual(glyph, .blocked)
        XCTAssertTrue(glyph.isFilled)
        XCTAssertEqual(glyph.accessibilityLabel, "Agent needs your attention")
    }

    func testDoneIsAHollowGlyph() throws {
        let glyph = try XCTUnwrap(AttentionGlyph(.done(message: "ok")))
        XCTAssertEqual(glyph, .done)
        XCTAssertFalse(glyph.isFilled)
        XCTAssertEqual(glyph.accessibilityLabel, "Agent finished")
    }

    func testWorkingAndNoneDrawNothing() {
        XCTAssertNil(AttentionGlyph(.working))
        XCTAssertNil(AttentionGlyph(.none))
    }
}
