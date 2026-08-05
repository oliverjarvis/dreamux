import XCTest
@testable import Dreamux

final class FlowWiringTests: XCTestCase {
    private let root = URL(fileURLWithPath: "/proj")

    private func repo(_ name: String, defaultBranch: String = "main") -> Repository {
        Repository(
            rootURL: root.appendingPathComponent("repos/\(name)", isDirectory: true),
            defaultBranch: defaultBranch
        )
    }

    func testMatchesAggregationDirAndWorktreePaths() {
        let ws = Workspace(
            name: "auth-refresh",
            workingDirectory: "/proj/features/auth-refresh",
            linkedRepoIDs: ["dreamux"]
        )
        let repos = [repo("dreamux")]

        // Exact aggregation dir and children of it.
        XCTAssertEqual(
            FlowWiring.workspaceID(forCwd: "/proj/features/auth-refresh",
                                   workspaces: [ws], repositories: repos),
            ws.id
        )
        XCTAssertEqual(
            FlowWiring.workspaceID(forCwd: "/proj/features/auth-refresh/sub",
                                   workspaces: [ws], repositories: repos),
            ws.id
        )
        // Per-repo worktree path: <root>/repos/<repo>/<workspace-name>.
        XCTAssertEqual(
            FlowWiring.workspaceID(forCwd: "/proj/repos/dreamux/auth-refresh/Sources",
                                   workspaces: [ws], repositories: repos),
            ws.id
        )
        // Prefix must respect path boundaries.
        XCTAssertNil(
            FlowWiring.workspaceID(forCwd: "/proj/features/auth-refresh-2",
                                   workspaces: [ws], repositories: repos)
        )
        XCTAssertNil(
            FlowWiring.workspaceID(forCwd: "/elsewhere",
                                   workspaces: [ws], repositories: repos)
        )
    }

    /// The main workspace's NAME is only the FIRST repo's default branch
    /// (`WorkspaceSidebar.openMainWorkspace` passes
    /// `repositories.first?.defaultBranch`), so composing
    /// `repos/<repo>/<workspace.name>` was wrong for every other repo.
    ///
    /// `workingDirectory` is deliberately left nil here. The real main
    /// workspace's working directory is the project root, and the
    /// function's first candidate is `workingDirectory` matched with
    /// `hasPrefix` — which would swallow every cwd in the project and
    /// mask whether the per-repo candidate resolved at all.
    func testMainWorkspaceMatchesEachRepoOwnDefaultBranch() {
        let ws = Workspace(name: "main", linkedRepoIDs: ["web", "api"], isMain: true)
        let repos = [repo("web", defaultBranch: "main"), repo("api", defaultBranch: "master")]

        XCTAssertEqual(
            FlowWiring.workspaceID(forCwd: "/proj/repos/web/main",
                                   workspaces: [ws], repositories: repos),
            ws.id
        )
        XCTAssertEqual(
            FlowWiring.workspaceID(forCwd: "/proj/repos/api/master/Sources",
                                   workspaces: [ws], repositories: repos),
            ws.id,
            "a second repo defaulting to master must still map to the main workspace"
        )
        // The old composition — repos/<repo>/<workspace.name> — must not
        // be what matches.
        XCTAssertNil(
            FlowWiring.workspaceID(forCwd: "/proj/repos/api/main",
                                   workspaces: [ws], repositories: repos)
        )
    }

    func testLinkedRepoTheProjectNoLongerHasIsDropped() {
        let ws = Workspace(name: "feat", linkedRepoIDs: ["gone"])
        XCTAssertNil(
            FlowWiring.workspaceID(forCwd: "/proj/repos/gone/feat",
                                   workspaces: [ws], repositories: [repo("web")])
        )
    }
}
