import XCTest
@testable import Dreamux

/// SwiftUI re-exports DeveloperToolsSupport, whose LibraryItem collides
/// with ours in the test target's lookup (not inside the module itself).
private typealias LibraryItem = Dreamux.LibraryItem

/// Context cards on the Context & MCPs page: the context-kind id/kind
/// semantics on `LibraryItem` (this task) and the pure `LibraryContext`
/// mapping enum (next task).
final class LibraryContextTests: XCTestCase {
    private func makeItem(
        kind: LibraryItemKind, name: String, path: String
    ) -> LibraryItem {
        LibraryItem(
            kind: kind, name: name, description: "", scopeLabel: "Project",
            path: URL(fileURLWithPath: path), accessible: true,
            accessReason: "", detail: [])
    }

    func testContextKindsAreFlagged() {
        XCTAssertTrue(LibraryItemKind.plan.isContext)
        XCTAssertTrue(LibraryItemKind.spec.isContext)
        XCTAssertTrue(LibraryItemKind.configFile.isContext)
        XCTAssertFalse(LibraryItemKind.skill.isContext)
        XCTAssertFalse(LibraryItemKind.mcpServer.isContext)
        XCTAssertFalse(LibraryItemKind.plugin.isContext)
    }

    func testContextIDsKeyByPathSoSameTitleDocsStayDistinct() {
        let a = makeItem(kind: .spec, name: "Design", path: "/p/docs/specs/a.md")
        let b = makeItem(kind: .spec, name: "Design", path: "/p/docs/specs/b.md")
        XCTAssertNotEqual(a.id, b.id)
    }

    func testNonContextIDsKeepTheScopeNameShape() {
        let item = makeItem(kind: .mcpServer, name: "srv", path: "/p/.mcp.json")
        XCTAssertEqual(item.id, "mcpServer|Project|srv")
    }
}
