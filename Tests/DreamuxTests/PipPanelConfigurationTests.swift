import AppKit
import XCTest
@testable import Dreamux

/// These assert *constants*, not a live window: an SPM test process has
/// no window server, and the point is to pin the four settings that are
/// easy to get wrong and invisible when wrong.
final class PipPanelConfigurationTests: XCTestCase {

    /// The trap. `NSPanel` defaults `hidesOnDeactivate` to true, which
    /// would make every pip vanish the moment the user clicks into
    /// another app — i.e. exactly when a pip is supposed to be useful.
    func testPipsDoNotHideWhenDreamuxDeactivates() {
        XCTAssertFalse(PipPanelConfiguration.hidesOnDeactivate)
    }

    /// `.titled` is what lets a panel become key, which is what lets a
    /// pipped terminal receive keystrokes.
    func testPanelCanBecomeKey() {
        XCTAssertTrue(PipPanelConfiguration.styleMask.contains(.titled))
        XCTAssertTrue(PipPanelConfiguration.styleMask.contains(.resizable))
        XCTAssertTrue(PipPanelConfiguration.styleMask.contains(.fullSizeContentView))
    }

    func testPanelFloatsAboveOtherApps() {
        XCTAssertEqual(PipPanelConfiguration.level, .floating)
    }

    /// Every Space, and over a fullscreen app — the scenario the whole
    /// feature exists for.
    func testPanelJoinsEverySpaceAndSurvivesFullscreen() {
        XCTAssertTrue(PipPanelConfiguration.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertTrue(PipPanelConfiguration.collectionBehavior.contains(.fullScreenAuxiliary))
    }
}
