import XCTest
import SwiftUI
@testable import Dreamux

final class WorkspaceOrderingTests: XCTestCase {
    private var sandbox: TestSandbox!
    private var project: Project!

    override func setUpWithError() throws {
        sandbox = try TestSandbox()
        project = try sandbox.makeProject(named: "proj")
    }

    override func tearDown() {
        sandbox?.destroy(); sandbox = nil; project = nil
    }

    private func feature(_ name: String) -> Workspace {
        Workspace(name: name, symbol: "s", tint: .blue, workingDirectory: nil, linkedRepoIDs: ["r"])
    }

    private func orphan(_ name: String) -> Workspace {
        Workspace(name: name, symbol: "s", tint: .blue, workingDirectory: nil, linkedRepoIDs: [])
    }

    @MainActor func testPersistFeatureOrderRecordsLinkedNamesOnly() {
        let store = WorkspaceStore()
        store.layout = SidebarLayoutStore(project: project)
        store.workspaces = [feature("a"), feature("b"), orphan("scratch")]

        store.persistFeatureOrder()

        XCTAssertEqual(store.layout?.featureOrder, ["a", "b"])
    }
}
