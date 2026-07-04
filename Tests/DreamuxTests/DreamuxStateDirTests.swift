import XCTest
@testable import Dreamux

/// `.dreamux/` runtime state must never travel via git — a committed
/// auto-run toggle without the ledger would auto-launch every parallel
/// plan on a fresh clone. Every state save routes through
/// `DreamuxStateDir.ensure`, which drops a `*` gitignore.
@MainActor
final class DreamuxStateDirTests: XCTestCase {
    var sandbox: TestSandbox!

    override func setUpWithError() throws { sandbox = try TestSandbox() }
    override func tearDown() { sandbox?.destroy(); sandbox = nil }

    func testEnsureCreatesDirAndGitignore() throws {
        let file = sandbox.root
            .appendingPathComponent(".dreamux/plan-queue.json")

        DreamuxStateDir.ensure(containing: file)

        let gitignore = sandbox.root.appendingPathComponent(".dreamux/.gitignore")
        XCTAssertEqual(try String(contentsOf: gitignore, encoding: .utf8), "*\n")
    }

    func testEnsureDoesNotClobberAnExistingGitignore() throws {
        let dir = sandbox.root.appendingPathComponent(".dreamux")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let gitignore = dir.appendingPathComponent(".gitignore")
        try "custom\n".write(to: gitignore, atomically: true, encoding: .utf8)

        DreamuxStateDir.ensure(containing: dir.appendingPathComponent("x.json"))

        XCTAssertEqual(try String(contentsOf: gitignore, encoding: .utf8), "custom\n")
    }

    func testQueueSaveRetrofitsGitignore() throws {
        let project = try sandbox.makeProject(named: "demo")
        let queue = PlanQueueController(project: project)

        queue.enqueue("docs/plans/2026-07-04-x.md")

        let gitignore = project.rootPath
            .appendingPathComponent(".dreamux/.gitignore")
        XCTAssertEqual(try String(contentsOf: gitignore, encoding: .utf8), "*\n")
    }
}
