import XCTest
@testable import Dreamux

final class WorkspaceSessionFileTabTests: XCTestCase {
    private var sandbox: TestSandbox!

    override func setUpWithError() throws { sandbox = try TestSandbox() }
    override func tearDown() { sandbox?.destroy(); sandbox = nil }

    @MainActor
    func testOpenFileTabCreatesSessionAndDedupsByPath() throws {
        let a = sandbox.root.appendingPathComponent("a.swift")
        try "let x = 1".write(to: a, atomically: true, encoding: .utf8)
        let session = WorkspaceSession(
            workspace: Workspace(name: "f", workingDirectory: sandbox.root.path)
        )

        session.openFileTab(at: a)
        XCTAssertEqual(session.openFileTabURLs.map(\.lastPathComponent), ["a.swift"])

        // Reopening the same file re-focuses — no second session.
        session.openFileTab(at: a)
        XCTAssertEqual(session.openFileTabURLs.count, 1)

        // A different file opens a distinct session.
        let b = sandbox.root.appendingPathComponent("b.swift")
        try "let y = 2".write(to: b, atomically: true, encoding: .utf8)
        session.openFileTab(at: b)
        XCTAssertEqual(session.openFileTabURLs.count, 2)
    }
}
