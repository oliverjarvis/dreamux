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

        controller.notifyFileDrop(urls, inPane: pane)

        XCTAssertEqual(delegate.receivedURLs, urls)
        XCTAssertEqual(delegate.receivedPane, pane)
    }
}

@MainActor
private final class RecordingDelegate: BonsplitDelegate {
    var receivedURLs: [URL]?
    var receivedPane: PaneID?

    func splitTabBar(_ controller: BonsplitController, didReceiveFileDrops urls: [URL], inPane pane: PaneID) {
        receivedURLs = urls
        receivedPane = pane
    }
}
