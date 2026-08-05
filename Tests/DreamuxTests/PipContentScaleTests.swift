import XCTest
@testable import Dreamux

final class PipContentScaleTests: XCTestCase {

    /// The point of the feature: a 420pt pip lays the page out at the
    /// full reference width and renders it shrunk, so you see the whole
    /// desktop site rather than its narrow/mobile layout.
    func testDefaultPipWidthLaysOutAtReferenceWidth() {
        let zoom = PipContentScale.zoom(forPanelWidth: 420)
        XCTAssertEqual(zoom, 420.0 / 1920.0, accuracy: 0.0001)
        // The CSS viewport the page sees is width / zoom.
        XCTAssertEqual(420 / zoom, PipContentScale.referenceWidth, accuracy: 0.5)
    }

    func testReferenceWidthIsDesktop() {
        XCTAssertEqual(PipContentScale.referenceWidth, 1920)
    }

    /// A panel already at desktop width renders 1:1 — never magnify.
    func testPanelAtReferenceWidthDoesNotZoom() {
        XCTAssertEqual(PipContentScale.zoom(forPanelWidth: 1920), 1)
    }

    func testPanelWiderThanReferenceDoesNotMagnify() {
        XCTAssertEqual(PipContentScale.zoom(forPanelWidth: 2400), 1)
    }

    /// Absurdly narrow panels stop shrinking, or the page becomes a
    /// smear of sub-pixel text and WebKit does a lot of work for nothing.
    func testVeryNarrowPanelClampsToMinimumZoom() {
        XCTAssertEqual(PipContentScale.zoom(forPanelWidth: 40),
                       PipContentScale.minimumZoom)
    }

    /// A zero-size panel happens for one layout pass before SwiftUI has
    /// measured the panel; it must not produce a zero or NaN zoom.
    func testDegenerateWidthsRenderUnscaled() {
        XCTAssertEqual(PipContentScale.zoom(forPanelWidth: 0), 1)
        XCTAssertEqual(PipContentScale.zoom(forPanelWidth: -100), 1)
    }

    /// Zoom rises smoothly as the user resizes the panel wider.
    func testZoomGrowsWithPanelWidth() {
        let narrow = PipContentScale.zoom(forPanelWidth: 420)
        let wide = PipContentScale.zoom(forPanelWidth: 840)
        XCTAssertGreaterThan(wide, narrow)
        XCTAssertEqual(wide, narrow * 2, accuracy: 0.0001)
    }

    /// The reference width is injectable so a caller can ask for a
    /// different target layout (a phone-width preview, say).
    func testCustomReferenceWidth() {
        XCTAssertEqual(PipContentScale.zoom(forPanelWidth: 390, referenceWidth: 780),
                       0.5, accuracy: 0.0001)
    }

    func testNonPositiveReferenceWidthRendersUnscaled() {
        XCTAssertEqual(PipContentScale.zoom(forPanelWidth: 420, referenceWidth: 0), 1)
    }
}
