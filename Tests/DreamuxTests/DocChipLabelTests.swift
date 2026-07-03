import XCTest
@testable import Dreamux

/// The chip label is the one piece of the section's presentation that is
/// pure logic, so it is table-tested directly rather than through the view.
final class DocChipLabelTests: XCTestCase {
    func testSpecAlwaysReadsSpec() {
        // The spec's own title never leaks into the chip — even a spec
        // whose title mentions a roadmap still reads "spec".
        XCTAssertEqual(DocChipLabel.label(title: "Game Boy Emulator — Design", isSpec: true), "spec")
        XCTAssertEqual(DocChipLabel.label(title: "Product Roadmap", isSpec: true), "spec")
    }

    func testRoadmapMatchIsCaseInsensitive() {
        XCTAssertEqual(DocChipLabel.label(title: "Game Boy Emulator Roadmap", isSpec: false), "roadmap")
        XCTAssertEqual(DocChipLabel.label(title: "ROADMAP", isSpec: false), "roadmap")
        XCTAssertEqual(DocChipLabel.label(title: "Delivery roadmap 2026", isSpec: false), "roadmap")
    }

    func testFallsBackToFirstWordLowercased() {
        XCTAssertEqual(DocChipLabel.label(title: "Architecture Notes", isSpec: false), "architecture")
        XCTAssertEqual(DocChipLabel.label(title: "Notes on the parser", isSpec: false), "notes")
        XCTAssertEqual(DocChipLabel.label(title: "  Leading spaces here", isSpec: false), "leading")
    }

    func testEmptyTitleFallsBackToEmpty() {
        XCTAssertEqual(DocChipLabel.label(title: "", isSpec: false), "")
    }
}
