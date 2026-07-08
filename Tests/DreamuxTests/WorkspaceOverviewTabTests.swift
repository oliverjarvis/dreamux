import XCTest
@testable import Dreamux

final class WorkspaceOverviewTabTests: XCTestCase {
    private var sandbox: TestSandbox!

    override func setUpWithError() throws { sandbox = try TestSandbox() }
    override func tearDown() { sandbox?.destroy(); sandbox = nil }

    @MainActor
    func testBootstrapCreatesOverviewFirstAndNonClosable() throws {
        let session = WorkspaceSession(
            workspace: Workspace(name: "f", workingDirectory: sandbox.root.path)
        )

        session.bootstrapIfNeeded()

        XCTAssertNotNil(session.overviewTabId)
        guard let pane = session.controller.focusedPaneId else {
            return XCTFail("expected a focused pane after bootstrap")
        }
        let tabs = session.controller.tabs(inPane: pane)
        XCTAssertGreaterThanOrEqual(tabs.count, 2, "overview + shell")
        XCTAssertEqual(tabs.first?.id, session.overviewTabId)
    }

    @MainActor
    func testOverviewTabRefusesToClose() throws {
        let session = WorkspaceSession(
            workspace: Workspace(name: "f", workingDirectory: sandbox.root.path)
        )
        session.bootstrapIfNeeded()

        guard let pane = session.controller.focusedPaneId else {
            return XCTFail("expected a focused pane after bootstrap")
        }
        let tabs = session.controller.tabs(inPane: pane)
        guard let overviewTab = tabs.first(where: { $0.id == session.overviewTabId }),
              let shellTab = tabs.first(where: { $0.id != session.overviewTabId }) else {
            return XCTFail("expected both an overview tab and a shell tab")
        }

        XCTAssertFalse(
            session.splitTabBar(session.controller, shouldCloseTab: overviewTab, inPane: pane)
        )
        XCTAssertTrue(
            session.splitTabBar(session.controller, shouldCloseTab: shellTab, inPane: pane)
        )
    }

    @MainActor
    func testIsOverviewTab() throws {
        let session = WorkspaceSession(
            workspace: Workspace(name: "f", workingDirectory: sandbox.root.path)
        )
        session.bootstrapIfNeeded()

        guard let overviewTabId = session.overviewTabId else {
            return XCTFail("expected overviewTabId to be set after bootstrap")
        }
        XCTAssertTrue(session.isOverviewTab(overviewTabId))

        guard let pane = session.controller.focusedPaneId,
              let shellTab = session.controller.tabs(inPane: pane).first(where: { $0.id != overviewTabId }) else {
            return XCTFail("expected a shell tab distinct from the overview tab")
        }
        XCTAssertFalse(session.isOverviewTab(shellTab.id))
    }
}
