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

    @MainActor
    func testFileTabSummariesExposeKindAndMode() throws {
        let md = sandbox.root.appendingPathComponent("plan.md")
        try "# t\n".write(to: md, atomically: true, encoding: .utf8)
        let session = WorkspaceSession(
            workspace: Workspace(name: "f", workingDirectory: sandbox.root.path)
        )
        session.openFileTab(at: md)

        let summaries = session.fileTabSummaries
        XCTAssertEqual(summaries.count, 1)
        XCTAssertEqual(summaries[0]["path"], md.resolvingSymlinksInPath().path)
        XCTAssertEqual(summaries[0]["kind"], "markdown")
        XCTAssertEqual(summaries[0]["mode"], "rendered")
        XCTAssertEqual(summaries[0]["dirty"], "false")
    }

    @MainActor
    func testOpenAgentTabReturnsItsTabSession() {
        let session = WorkspaceSession(
            workspace: Workspace(name: "f", workingDirectory: sandbox.root.path)
        )
        let returned = session.openAgentTab(
            at: sandbox.root.path, title: "plan: x", icon: "text.badge.checkmark")
        XCTAssertNotNil(returned)
        XCTAssertEqual(returned?.cwd, sandbox.root.path)
    }

    @MainActor
    func testOpenPlanAgentTabIsReachableForNudges() {
        let session = WorkspaceSession(
            workspace: Workspace(name: "f", workingDirectory: sandbox.root.path)
        )
        XCTAssertNil(session.agentTabSession(), "no agent tab before a plan runs")

        let opened = session.openPlanAgentTab(
            at: sandbox.root.path, title: "plan: x", icon: "text.badge.checkmark")
        // The plan agent tab is tracked, so the nudge center can reach the
        // same live agent to type into.
        XCTAssertNotNil(opened)
        XCTAssertIdentical(session.agentTabSession(), opened)
    }
}
