import XCTest
@testable import Dreamux

final class FileTreeStoreTests: XCTestCase {
    private var sandbox: TestSandbox!
    private var project: Project!

    override func setUpWithError() throws {
        sandbox = try TestSandbox()
        project = try sandbox.makeProject(named: "proj")
    }

    override func tearDown() {
        sandbox?.destroy()
        sandbox = nil
        project = nil
    }

    /// Lay down `repos/<repo>/<branch>/` with an optional file inside.
    @discardableResult
    private func makeWorktree(repo: String, branch: String, file: String? = nil) throws -> URL {
        let dir = project.rootPath
            .appendingPathComponent("repos/\(repo)/\(branch)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let file {
            try "x".write(to: dir.appendingPathComponent(file), atomically: true, encoding: .utf8)
        }
        return dir
    }

    private func repo(_ name: String) -> Repository {
        Repository(rootURL: project.rootPath.appendingPathComponent("repos/\(name)", isDirectory: true))
    }

    @MainActor
    func testRootsAreLinkedReposWithWorktreesInOrder() throws {
        try makeWorktree(repo: "repoA", branch: "feat")
        try makeWorktree(repo: "repoB", branch: "feat")
        try makeWorktree(repo: "repoC", branch: "feat") // not linked
        let ws = Workspace(name: "feat", linkedRepoIDs: ["repoB", "repoA"])
        let store = FileTreeStore()

        let roots = store.roots(for: ws, repositories: [repo("repoA"), repo("repoB"), repo("repoC")])

        XCTAssertEqual(roots.map(\.name), ["repoB", "repoA"])
        XCTAssertTrue(roots.allSatisfy { $0.isRepoRoot && $0.isDirectory })
    }

    @MainActor
    func testRepoWithoutWorktreeAtBranchIsOmitted() throws {
        try makeWorktree(repo: "repoA", branch: "feat")
        // repoB linked but has no worktree at this branch.
        let ws = Workspace(name: "feat", linkedRepoIDs: ["repoA", "repoB"])
        let store = FileTreeStore()

        let roots = store.roots(for: ws, repositories: [repo("repoA"), repo("repoB")])

        XCTAssertEqual(roots.map(\.name), ["repoA"])
    }

    @MainActor
    func testNilAndOrphanWorkspacesYieldNoRoots() throws {
        let store = FileTreeStore()
        XCTAssertTrue(store.roots(for: nil, repositories: []).isEmpty)
        let orphan = Workspace(name: "scratch", linkedRepoIDs: [])
        XCTAssertTrue(store.roots(for: orphan, repositories: [repo("repoA")]).isEmpty)
    }

    @MainActor
    func testChildrenSortDirsFirstAndHideGitInternals() throws {
        let root = try makeWorktree(repo: "repoA", branch: "feat")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("src"), withIntermediateDirectories: true)
        try "".write(to: root.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        try "".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "gitdir: ...".write(to: root.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".bare"), withIntermediateDirectories: true)
        let store = FileTreeStore()
        let node = FileNode(url: root, name: "repoA", isDirectory: true, isRepoRoot: true)

        let names = store.children(of: node).map(\.name)

        XCTAssertEqual(names, ["src", "a.txt", "b.txt"])
    }
}
