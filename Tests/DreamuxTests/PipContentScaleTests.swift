import XCTest
@testable import Dreamux

final class PipContentScaleTests: XCTestCase {

    private let panel = CGSize(width: 420, height: 280)

    // MARK: - scale

    /// The whole point: a 420pt pip draws a 1920-wide render at 21.875%,
    /// so the page is a uniform miniature rather than a re-layout.
    func testScaleShrinksReferenceWidthOntoThePanel() {
        XCTAssertEqual(PipContentScale.scale(forPanelWidth: 420),
                       420.0 / 1920.0, accuracy: 0.0001)
    }

    func testReferenceWidthIsDesktop() {
        XCTAssertEqual(PipContentScale.referenceWidth, 1920)
    }

    /// A panel already at desktop width renders 1:1 — never magnify.
    func testPanelAtReferenceWidthRendersUnscaled() {
        XCTAssertEqual(PipContentScale.scale(forPanelWidth: 1920), 1)
    }

    func testPanelWiderThanReferenceDoesNotMagnify() {
        XCTAssertEqual(PipContentScale.scale(forPanelWidth: 2400), 1)
    }

    /// Absurdly narrow panels stop shrinking: below this the render is a
    /// smear and WebKit still pays to lay out every element.
    func testVeryNarrowPanelClampsToMinimumScale() {
        XCTAssertEqual(PipContentScale.scale(forPanelWidth: 40),
                       PipContentScale.minimumScale)
    }

    /// SwiftUI reports a zero size for one pass on a freshly opened
    /// panel; that must not produce a zero, infinite or NaN scale.
    func testDegenerateWidthsRenderUnscaled() {
        XCTAssertEqual(PipContentScale.scale(forPanelWidth: 0), 1)
        XCTAssertEqual(PipContentScale.scale(forPanelWidth: -100), 1)
    }

    func testNonPositiveReferenceWidthRendersUnscaled() {
        XCTAssertEqual(PipContentScale.scale(forPanelWidth: 420, referenceWidth: 0), 1)
    }

    // MARK: - layoutBounds

    /// The coordinate space the page is given. Width is always the
    /// reference width; height follows the PANEL's aspect ratio, so the
    /// miniature fills the panel edge to edge with no letterboxing.
    func testLayoutBoundsIsReferenceWidthAtThePanelsAspect() {
        let bounds = PipContentScale.layoutBounds(forPanel: panel)
        XCTAssertEqual(bounds.width, 1920, accuracy: 0.0001)
        // 280 / (420/1920) == 1280
        XCTAssertEqual(bounds.height, 1280, accuracy: 0.0001)
    }

    /// Scaling the layout bounds by `scale` must land exactly on the
    /// panel — that identity is what stops the render being cropped or
    /// letterboxed.
    func testLayoutBoundsScaledBackFitsThePanelExactly() {
        let bounds = PipContentScale.layoutBounds(forPanel: panel)
        let scale = PipContentScale.scale(forPanelWidth: panel.width)
        XCTAssertEqual(bounds.width * scale, panel.width, accuracy: 0.0001)
        XCTAssertEqual(bounds.height * scale, panel.height, accuracy: 0.0001)
    }

    /// A tall, narrow pip gets a tall coordinate space, not a cropped one.
    func testTallPanelGetsATallLayoutBounds() {
        let bounds = PipContentScale.layoutBounds(forPanel: CGSize(width: 480, height: 960))
        XCTAssertEqual(bounds.width, 1920, accuracy: 0.0001)
        XCTAssertEqual(bounds.height, 3840, accuracy: 0.0001)
    }

    /// At or above reference width nothing is scaled, so the page simply
    /// gets the panel's own size.
    func testUnscaledPanelLaysOutAtItsOwnSize() {
        let wide = CGSize(width: 2400, height: 1000)
        XCTAssertEqual(PipContentScale.layoutBounds(forPanel: wide), wide)
    }

    func testDegeneratePanelLaysOutAtItsOwnSize() {
        let zero = CGSize(width: 0, height: 0)
        XCTAssertEqual(PipContentScale.layoutBounds(forPanel: zero), zero)
    }
}
