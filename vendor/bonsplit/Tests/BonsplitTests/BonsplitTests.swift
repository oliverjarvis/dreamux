import SwiftUI
import XCTest
@testable import Bonsplit

final class BonsplitTests: XCTestCase {

    @MainActor
    func testControllerCreation() {
        let controller = BonsplitController()
        XCTAssertNotNil(controller.focusedPaneId)
    }

    @MainActor
    func testTabCreation() {
        let controller = BonsplitController()
        let tabId = controller.createTab(title: "Test Tab", icon: "doc")
        XCTAssertNotNil(tabId)
    }

    @MainActor
    func testTabRetrieval() {
        let controller = BonsplitController()
        let tabId = controller.createTab(title: "Test Tab", icon: "doc")!
        let tab = controller.tab(tabId)
        XCTAssertEqual(tab?.title, "Test Tab")
        XCTAssertEqual(tab?.icon, "doc")
    }

    @MainActor
    func testTabUpdate() {
        let controller = BonsplitController()
        let tabId = controller.createTab(title: "Original", icon: "doc")!

        controller.updateTab(tabId, title: "Updated", isDirty: true)

        let tab = controller.tab(tabId)
        XCTAssertEqual(tab?.title, "Updated")
        XCTAssertEqual(tab?.isDirty, true)
    }

    @MainActor
    func testTabClose() {
        let controller = BonsplitController()
        let tabId = controller.createTab(title: "Test Tab", icon: "doc")!

        let closed = controller.closeTab(tabId)

        XCTAssertTrue(closed)
        XCTAssertNil(controller.tab(tabId))
    }

    @MainActor
    func testConfiguration() {
        let config = BonsplitConfiguration(
            allowSplits: false,
            allowCloseTabs: true
        )
        let controller = BonsplitController(configuration: config)

        XCTAssertFalse(controller.configuration.allowSplits)
        XCTAssertTrue(controller.configuration.allowCloseTabs)
    }

    @MainActor
    func testIsTabSelected() {
        let controller = BonsplitController()
        let firstTabId = controller.createTab(title: "First", icon: "doc")!
        let secondTabId = controller.createTab(title: "Second", icon: "doc")!

        // Creating a tab selects it, so the most recently created tab
        // is selected and the earlier one is not.
        XCTAssertTrue(controller.isTabSelected(secondTabId))
        XCTAssertFalse(controller.isTabSelected(firstTabId))

        // A tab id bonsplit has never seen isn't selected.
        XCTAssertFalse(controller.isTabSelected(TabID()))
    }

    @MainActor
    func testNotifyFileDropForwardsToDelegate() {
        let controller = BonsplitController()
        let delegate = RecordingDelegate()
        controller.delegate = delegate

        let pane = controller.allPaneIds.first!
        let urls = [URL(fileURLWithPath: "/tmp/a.txt"), URL(fileURLWithPath: "/tmp/b.txt")]

        controller.notifyFileDrop(urls, inPane: pane, atIndex: 1)

        XCTAssertEqual(delegate.receivedURLs, urls)
        XCTAssertEqual(delegate.receivedPane, pane)
        XCTAssertEqual(delegate.receivedIndex, 1)
    }

    // Note: `BonsplitController()` seeds a "Welcome" tab (see
    // `SplitViewController`'s init) -- these expected orderings include
    // it as the pre-existing tab at index 0.

    @MainActor
    func testMoveTabRepositionsWithinPane() {
        let controller = BonsplitController()
        let pane = controller.allPaneIds.first!
        let first = controller.createTab(title: "First", icon: "doc")!
        _ = controller.createTab(title: "Second", icon: "doc")!
        _ = controller.createTab(title: "Third", icon: "doc")!
        // Initial order: Welcome, First, Second, Third

        controller.moveTab(first, toIndex: 3, inPane: pane)

        let titles = controller.tabs(inPane: pane).map(\.title)
        XCTAssertEqual(titles, ["Welcome", "Second", "First", "Third"])
    }

    @MainActor
    func testMoveTabClampsOutOfRangeIndex() {
        let controller = BonsplitController()
        let pane = controller.allPaneIds.first!
        let first = controller.createTab(title: "First", icon: "doc")!
        _ = controller.createTab(title: "Second", icon: "doc")!
        // Initial order: Welcome, First, Second

        controller.moveTab(first, toIndex: 999, inPane: pane)

        let titles = controller.tabs(inPane: pane).map(\.title)
        XCTAssertEqual(titles, ["Welcome", "Second", "First"])
    }

    @MainActor
    func testMoveTabUnknownTabIsNoOp() {
        let controller = BonsplitController()
        let pane = controller.allPaneIds.first!
        _ = controller.createTab(title: "First", icon: "doc")!
        // Initial order: Welcome, First

        controller.moveTab(TabID(), toIndex: 0, inPane: pane)

        let titles = controller.tabs(inPane: pane).map(\.title)
        XCTAssertEqual(titles, ["Welcome", "First"])
    }

    /// The tab context-menu hook must be genuinely optional: a host that
    /// doesn't pass one gets NO menu, not an empty popup on right-click.
    @MainActor
    func testTabContextMenuIsAbsentByDefault() {
        XCTAssertNil(TabContextMenuBox.none.builder)
    }

    @MainActor
    func testTabContextMenuBoxCarriesItsBuilder() {
        let box = TabContextMenuBox { tab, _ in AnyView(Text(tab.title)) }
        XCTAssertNotNil(box.builder)
    }

    @MainActor
    func testTabAttentionDefaultsToNoneAndRoundTrips() throws {
        let controller = BonsplitController()
        let tabId = try XCTUnwrap(controller.createTab(title: "shell"))
        // Spelled out: against an Optional, a bare `.none` resolves to
        // `Optional.none` (nil), not `TabAttention.none`.
        XCTAssertEqual(controller.tab(tabId)?.attention, TabAttention.none)

        controller.updateTab(tabId, attention: .blocked)
        XCTAssertEqual(controller.tab(tabId)?.attention, .blocked)

        controller.updateTab(tabId, attention: .done)
        XCTAssertEqual(controller.tab(tabId)?.attention, .done)
    }

    @MainActor
    func testUpdatingAttentionLeavesOtherFieldsAlone() throws {
        let controller = BonsplitController()
        let tabId = try XCTUnwrap(
            controller.createTab(title: "shell", icon: "terminal", isDirty: true)
        )
        controller.updateTab(tabId, attention: .blocked)
        let tab = try XCTUnwrap(controller.tab(tabId))
        XCTAssertEqual(tab.title, "shell")
        XCTAssertEqual(tab.icon, "terminal")
        XCTAssertTrue(tab.isDirty)
        XCTAssertEqual(tab.attention, .blocked)
    }

    @MainActor
    func testCreateTabAcceptsAnInitialAttention() throws {
        let controller = BonsplitController()
        let tabId = try XCTUnwrap(controller.createTab(title: "shell", attention: .working))
        XCTAssertEqual(controller.tab(tabId)?.attention, .working)
    }
}

@MainActor
private final class RecordingDelegate: BonsplitDelegate {
    var receivedURLs: [URL]?
    var receivedPane: PaneID?
    var receivedIndex: Int?

    func splitTabBar(_ controller: BonsplitController, didReceiveFileDrops urls: [URL], inPane pane: PaneID, atIndex index: Int) {
        receivedURLs = urls
        receivedPane = pane
        receivedIndex = index
    }
}
