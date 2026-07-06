import XCTest
@testable import Dreamux

final class FlowWiringTests: XCTestCase {
    func testMatchesAggregationDirAndWorktreePaths() {
        let ws = Workspace(
            name: "auth-refresh",
            workingDirectory: "/proj/features/auth-refresh",
            linkedRepoIDs: ["dreamux"]
        )
        let root = URL(fileURLWithPath: "/proj")

        // Exact aggregation dir and children of it.
        XCTAssertEqual(
            FlowWiring.workspaceID(forCwd: "/proj/features/auth-refresh", workspaces: [ws], projectRoot: root),
            ws.id
        )
        XCTAssertEqual(
            FlowWiring.workspaceID(forCwd: "/proj/features/auth-refresh/sub", workspaces: [ws], projectRoot: root),
            ws.id
        )
        // Per-repo worktree path: <root>/repos/<repo>/<workspace-name>.
        XCTAssertEqual(
            FlowWiring.workspaceID(forCwd: "/proj/repos/dreamux/auth-refresh/Sources", workspaces: [ws], projectRoot: root),
            ws.id
        )
        // Prefix must respect path boundaries.
        XCTAssertNil(
            FlowWiring.workspaceID(forCwd: "/proj/features/auth-refresh-2", workspaces: [ws], projectRoot: root)
        )
        XCTAssertNil(
            FlowWiring.workspaceID(forCwd: "/elsewhere", workspaces: [ws], projectRoot: root)
        )
    }
}
