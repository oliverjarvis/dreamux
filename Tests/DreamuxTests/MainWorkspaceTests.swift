import XCTest
@testable import Dreamux

/// The reserved main workspace: find-or-create stability, survival
/// across feature reloads, and immunity to removal — the row is
/// permanent, so the workspace behind it must be too.
@MainActor
final class MainWorkspaceTests: XCTestCase {

    private func makeStore() -> WorkspaceStore {
        WorkspaceStore()
    }

    /// Same inputs → same workspace instance (stable id), no duplicates
    /// no matter how often the row is clicked.
    func testMainWorkspaceFindOrCreateIsIdempotent() {
        let store = makeStore()
        let first = store.mainWorkspace(
            name: "main", workingDirectory: "/tmp/proj", linkedRepoIDs: ["web"])
        let second = store.mainWorkspace(
            name: "main", workingDirectory: "/tmp/proj", linkedRepoIDs: ["web"])
        XCTAssertEqual(first.id, second.id)
        XCTAssertEqual(store.workspaces.filter(\.isMain).count, 1)
        XCTAssertTrue(first.isMain)
        XCTAssertEqual(first.workingDirectory, "/tmp/proj")
    }

    /// Linked repos can change between launches (repo added to the
    /// project) — find-or-create refreshes them on the existing entry.
    func testMainWorkspaceRefreshesLinkedRepos() {
        let store = makeStore()
        _ = store.mainWorkspace(
            name: "main", workingDirectory: "/tmp/proj", linkedRepoIDs: ["web"])
        let updated = store.mainWorkspace(
            name: "main", workingDirectory: "/tmp/proj", linkedRepoIDs: ["web", "api"])
        XCTAssertEqual(updated.linkedRepoIDs, ["web", "api"])
        XCTAssertEqual(store.workspaces.filter(\.isMain).count, 1)
    }

    /// The existing-entry refresh path must keep any live session's
    /// cached workspace in sync, or a session that's already open would
    /// keep opening new tabs at the stale `workingDirectory`.
    func testMainWorkspaceRefreshSyncsLiveSession() {
        let store = makeStore()
        let main = store.mainWorkspace(
            name: "main", workingDirectory: "/tmp/proj", linkedRepoIDs: ["web"])
        let session = store.session(for: main)
        XCTAssertEqual(session.workspace.workingDirectory, "/tmp/proj")

        _ = store.mainWorkspace(
            name: "main", workingDirectory: "/tmp/proj2", linkedRepoIDs: ["web"])

        XCTAssertEqual(session.workspace.workingDirectory, "/tmp/proj2")
    }

    /// remove() must refuse the main workspace — nothing in the UI
    /// offers it, but the guard is the invariant, not the UI.
    func testRemoveRefusesMainWorkspace() {
        let store = makeStore()
        let main = store.mainWorkspace(
            name: "main", workingDirectory: "/tmp/proj", linkedRepoIDs: [])
        store.remove(main)
        XCTAssertTrue(store.workspaces.contains { $0.id == main.id })
    }

    /// `reloadFeatures(in:repoStore:)` rebuilds `workspaces` from on-disk
    /// worktree discovery. No existing test drives it end-to-end, but the
    /// real call path is reachable without mocks: a `TestSandbox` project
    /// with no `repos/` directory gives a `RepoStore` with zero
    /// repositories, so `discoverFeatures()` returns an empty mapping and
    /// the only thing that can survive into the rebuilt array is whatever
    /// the orphan-preservation predicate carries over. That's the exact
    /// seam `isMain` needs to hook into (it has non-empty `linkedRepoIDs`,
    /// so the orphan-only check wouldn't otherwise catch it), so this
    /// drives the production method itself rather than a stand-in.
    func testReloadPreservesMainWorkspace() async throws {
        let sandbox = try TestSandbox()
        defer { sandbox.destroy() }
        let project = try sandbox.makeProject(named: "proj")
        let repoStore = RepoStore(project: project)
        XCTAssertTrue(repoStore.repositories.isEmpty)

        let store = makeStore()
        let main = store.mainWorkspace(
            name: "main", workingDirectory: project.rootPath.path, linkedRepoIDs: ["web"])

        await store.reloadFeatures(in: project, repoStore: repoStore)

        XCTAssertTrue(store.workspaces.contains { $0.id == main.id && $0.isMain })
    }
}
