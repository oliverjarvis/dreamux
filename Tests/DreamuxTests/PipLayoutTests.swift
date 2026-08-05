import XCTest
@testable import Dreamux

/// Screen used by every test: 1000 × 800 at the origin, so expected
/// values are readable arithmetic rather than magic numbers.
private let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
private let size = CGSize(width: 420, height: 280)

final class PipLayoutTests: XCTestCase {

    // MARK: - initialFrame

    /// The first pip sits in the bottom-right corner, inset by 24.
    func testInitialFrameSitsBottomRightWithInset() {
        let frame = PipLayout.initialFrame(index: 0, size: size, screen: screen)
        XCTAssertEqual(frame, CGRect(x: 1000 - 24 - 420, y: 24, width: 420, height: 280))
    }

    /// Each successive pip steps up and to the left so a second pip can
    /// never land exactly on the first.
    func testInitialFrameCascadesUpAndLeft() {
        let second = PipLayout.initialFrame(index: 1, size: size, screen: screen)
        XCTAssertEqual(second.origin, CGPoint(x: 556 - 28, y: 24 + 28))
    }

    /// A cascade far enough to leave the screen is pulled back inside it.
    func testInitialFrameStaysOnScreen() {
        let far = PipLayout.initialFrame(index: 40, size: size, screen: screen)
        XCTAssertGreaterThanOrEqual(far.minX, screen.minX)
        XCTAssertLessThanOrEqual(far.maxY, screen.maxY)
    }

    // MARK: - snap

    func testSnapsToScreenLeftEdgeWithinThreshold() {
        let proposed = CGRect(x: 6, y: 300, width: 420, height: 280)
        let snapped = PipLayout.snap(proposed: proposed, neighbours: [], screen: screen)
        XCTAssertEqual(snapped.minX, 0)
    }

    func testDoesNotSnapBeyondThreshold() {
        let proposed = CGRect(x: 20, y: 300, width: 420, height: 280)
        let snapped = PipLayout.snap(proposed: proposed, neighbours: [], screen: screen)
        XCTAssertEqual(snapped.minX, 20)
    }

    /// x can snap while y is left alone — the axes resolve independently.
    func testAxesResolveIndependently() {
        let proposed = CGRect(x: 6, y: 300, width: 420, height: 280)
        let snapped = PipLayout.snap(proposed: proposed, neighbours: [], screen: screen)
        XCTAssertEqual(snapped.minX, 0)
        XCTAssertEqual(snapped.minY, 300)
        XCTAssertEqual(snapped.size, proposed.size)
    }

    /// Aligning left edges with a neighbour.
    func testSnapsToNeighbourAlignedLeftEdge() {
        let neighbour = CGRect(x: 100, y: 500, width: 420, height: 280)
        let proposed = CGRect(x: 106, y: 200, width: 420, height: 280)
        let snapped = PipLayout.snap(proposed: proposed, neighbours: [neighbour], screen: screen)
        XCTAssertEqual(snapped.minX, 100)
    }

    /// Abutting a neighbour leaves exactly one gutter, so a snapped pair
    /// looks like a tidied pair.
    func testSnapsToAbutNeighbourWithOneGutter() {
        let neighbour = CGRect(x: 100, y: 500, width: 420, height: 280)
        let proposed = CGRect(x: 528, y: 200, width: 420, height: 280)
        let snapped = PipLayout.snap(proposed: proposed, neighbours: [neighbour], screen: screen)
        XCTAssertEqual(snapped.minX, 520 + PipLayout.gutter)
    }

    /// Two candidates inside the threshold: the nearer one wins.
    func testNearestCandidateWins() {
        let neighbour = CGRect(x: 5, y: 500, width: 420, height: 280)
        let proposed = CGRect(x: 3, y: 200, width: 420, height: 280)
        let snapped = PipLayout.snap(proposed: proposed, neighbours: [neighbour], screen: screen)
        XCTAssertEqual(snapped.minX, 5)
    }

    func testSnapsToScreenTopEdge() {
        let proposed = CGRect(x: 300, y: 800 - 280 - 5, width: 420, height: 280)
        let snapped = PipLayout.snap(proposed: proposed, neighbours: [], screen: screen)
        XCTAssertEqual(snapped.maxY, 800)
    }

    // MARK: - tidy

    /// Two pips fit per column on this screen: (800 − 24 + 12) / 292 = 2.
    func testTidyPacksAColumnFromTheNearestCorner() {
        let frames = PipLayout.tidy(count: 2, size: size, screen: screen,
                                    centroid: CGPoint(x: 100, y: 700))
        XCTAssertEqual(frames.count, 2)
        XCTAssertEqual(frames[0], CGRect(x: 12, y: 508, width: 420, height: 280))
        XCTAssertEqual(frames[1], CGRect(x: 12, y: 216, width: 420, height: 280))
    }

    func testTidyLeavesEqualGutters() {
        let frames = PipLayout.tidy(count: 2, size: size, screen: screen,
                                    centroid: CGPoint(x: 100, y: 700))
        XCTAssertEqual(frames[0].minY - frames[1].maxY, PipLayout.gutter)
    }

    /// A third pip cannot fit the first column, so it starts a second one.
    func testTidyWrapsToASecondColumn() {
        let frames = PipLayout.tidy(count: 3, size: size, screen: screen,
                                    centroid: CGPoint(x: 100, y: 700))
        XCTAssertEqual(frames[2], CGRect(x: 12 + 420 + 12, y: 508, width: 420, height: 280))
    }

    /// A bottom-right centroid tidies into the bottom-right corner.
    func testTidyPicksTheCornerNearestTheCentroid() {
        let frames = PipLayout.tidy(count: 1, size: size, screen: screen,
                                    centroid: CGPoint(x: 900, y: 100))
        XCTAssertEqual(frames[0], CGRect(x: 1000 - 12 - 420, y: 12, width: 420, height: 280))
    }

    func testTidyOfNothingIsEmpty() {
        XCTAssertTrue(PipLayout.tidy(count: 0, size: size, screen: screen,
                                     centroid: .zero).isEmpty)
    }

    // MARK: - clamped

    func testClampedPullsAnOffScreenFrameBack() {
        let stray = CGRect(x: 900, y: 700, width: 420, height: 280)
        XCTAssertEqual(PipLayout.clamped(stray, into: screen),
                       CGRect(x: 580, y: 520, width: 420, height: 280))
    }

    func testClampedShrinksAFrameLargerThanTheScreen() {
        let huge = CGRect(x: -50, y: -50, width: 2000, height: 2000)
        XCTAssertEqual(PipLayout.clamped(huge, into: screen), screen)
    }
}
