import XCTest
import Bonsplit
@testable import Dreamux

/// Records every chip mutation so tests can assert the marker contract
/// without a Bonsplit controller.
@MainActor
private final class ChipSpy {
    var icons: [PipTarget: String?] = [:]
    var writes: [(PipTarget, String?)] = []

    func marker() -> PipController.ChipMarker {
        PipController.ChipMarker(
            icon: { [weak self] target in self?.icons[target] ?? nil },
            setIcon: { [weak self] target, icon in
                self?.icons[target] = icon
                self?.writes.append((target, icon))
            }
        )
    }
}

@MainActor
final class PipControllerTests: XCTestCase {

    /// Held for the whole test case. `ChipSpy.marker()` captures the spy
    /// weakly, so a temporary `ChipSpy()` would deallocate before the
    /// first `open` ever reached it. Tests that assert on the marker
    /// declare their own local spy instead.
    private let chipSpy = ChipSpy()

    private let workspace = UUID()
    private lazy var tabA = PipTarget.tab(workspaceID: workspace, tabID: TabID())
    private lazy var tabB = PipTarget.tab(workspaceID: workspace, tabID: TabID())

    private func frame(_ x: CGFloat) -> CGRect {
        CGRect(x: x, y: 0, width: 420, height: 280)
    }

    func testOpenAddsAnItemAndMarksTheChip() {
        let spy = ChipSpy()
        spy.icons[tabA] = "terminal.fill"
        let pips = PipController(chip: spy.marker())

        pips.open(tabA, frame: frame(0))

        XCTAssertTrue(pips.isPipped(tabA))
        XCTAssertEqual(pips.items.count, 1)
        XCTAssertEqual(spy.icons[tabA], PipController.pippedChipIcon)
    }

    func testOpenIsIdempotentAndKeepsTheOriginalFrame() {
        let pips = PipController(chip: chipSpy.marker())
        pips.open(tabA, frame: frame(10))
        pips.open(tabA, frame: frame(999))

        XCTAssertEqual(pips.items.count, 1)
        XCTAssertEqual(pips.item(for: tabA)?.frame, frame(10))
    }

    /// The chip's own icon comes back — a pipped shell must not return
    /// wearing the pip glyph.
    func testCloseRestoresTheOriginalChipIcon() {
        let spy = ChipSpy()
        spy.icons[tabA] = "terminal.fill"
        let pips = PipController(chip: spy.marker())

        pips.open(tabA, frame: frame(0))
        pips.close(tabA)

        XCTAssertFalse(pips.isPipped(tabA))
        XCTAssertTrue(pips.items.isEmpty)
        XCTAssertEqual(spy.icons[tabA], "terminal.fill")
    }

    /// A chip that had no icon gets no icon back, not an empty string.
    func testCloseRestoresANilIcon() {
        let spy = ChipSpy()
        spy.icons[tabA] = String?.none
        let pips = PipController(chip: spy.marker())

        pips.open(tabA, frame: frame(0))
        pips.close(tabA)

        XCTAssertEqual(spy.writes.last?.1, String?.none)
    }

    func testItemsKeepCreationOrder() {
        let pips = PipController(chip: chipSpy.marker())
        pips.open(tabA, frame: frame(0))
        pips.open(tabB, frame: frame(1))

        XCTAssertEqual(pips.items.map(\.target), [tabA, tabB])
    }

    /// Closing a tab in the window closes its pip, whichever workspace
    /// it belonged to.
    func testCloseByTabIDClosesTheMatchingPip() {
        let pips = PipController(chip: chipSpy.marker())
        guard case .tab(_, let idA) = tabA else { return XCTFail("tabA is a tab target") }
        pips.open(tabA, frame: frame(0))
        pips.open(tabB, frame: frame(1))

        pips.close(tabID: idA)

        XCTAssertEqual(pips.items.map(\.target), [tabB])
    }

    func testCloseAllInWorkspaceLeavesOtherWorkspacesAlone() {
        let pips = PipController(chip: chipSpy.marker())
        let other = PipTarget.tab(workspaceID: UUID(), tabID: TabID())
        pips.open(tabA, frame: frame(0))
        pips.open(other, frame: frame(1))

        pips.closeAll(inWorkspace: workspace)

        XCTAssertEqual(pips.items.map(\.target), [other])
    }

    func testCloseByAppletIDClosesTheAppletPip() {
        let pips = PipController(chip: chipSpy.marker())
        let appletID = UUID()
        pips.open(.applet(id: appletID), frame: frame(0))

        pips.close(appletID: appletID)

        XCTAssertTrue(pips.items.isEmpty)
    }

    func testCloseAllEmptiesTheRegistry() {
        let pips = PipController(chip: chipSpy.marker())
        pips.open(tabA, frame: frame(0))
        pips.open(.applet(id: UUID()), frame: frame(1))

        pips.closeAll()

        XCTAssertTrue(pips.items.isEmpty)
    }

    func testSetFrameUpdatesTheItem() {
        let pips = PipController(chip: chipSpy.marker())
        pips.open(tabA, frame: frame(0))

        pips.setFrame(frame(77), for: tabA)

        XCTAssertEqual(pips.item(for: tabA)?.frame, frame(77))
    }

    func testApplyTidyRewritesFramesInItemOrder() {
        let pips = PipController(chip: chipSpy.marker())
        pips.open(tabA, frame: frame(0))
        pips.open(tabB, frame: frame(1))

        pips.applyTidy([frame(100), frame(200)])

        XCTAssertEqual(pips.items.map(\.frame), [frame(100), frame(200)])
    }

    /// Fewer frames than pips must not trap — the extra pips keep their
    /// current placement.
    func testApplyTidyToleratesAShortFrameList() {
        let pips = PipController(chip: chipSpy.marker())
        pips.open(tabA, frame: frame(0))
        pips.open(tabB, frame: frame(1))

        pips.applyTidy([frame(100)])

        XCTAssertEqual(pips.items.map(\.frame), [frame(100), frame(1)])
    }

    func testCentroidIsTheMeanOfPipCentres() {
        let pips = PipController(chip: chipSpy.marker())
        pips.open(tabA, frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        pips.open(tabB, frame: CGRect(x: 100, y: 100, width: 100, height: 100))

        XCTAssertEqual(pips.centroid, CGPoint(x: 100, y: 100))
    }

    func testCentroidOfNothingIsZero() {
        XCTAssertEqual(PipController(chip: chipSpy.marker()).centroid, .zero)
    }
}
