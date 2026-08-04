import XCTest
import SwiftUI
@testable import Dreamux

/// The bar says which of its two jobs it is about to do. Pure — the pill's
/// label and the field's placeholder are derived, not hand-set per branch.
@MainActor
final class ComposerTargetTests: XCTestCase {
    private let alpha = Workspace(name: "alpha", workingDirectory: "/tmp/alpha")

    func testIdeaIsTheDefaultAndReadsAsIntake() {
        XCTAssertEqual(ComposerTarget.idea.label(workspaces: []), "Idea")
        XCTAssertEqual(ComposerTarget.idea.placeholder(workspaces: []), "Describe an idea…")
    }

    func testAutoReadsAsAMessage() {
        XCTAssertEqual(ComposerTarget.auto.label(workspaces: []), "Auto")
        XCTAssertEqual(ComposerTarget.auto.placeholder(workspaces: []), "Message Claude…")
    }

    func testNamedWorkspaceReadsAsItsOwnClaude() {
        let target = ComposerTarget.workspace(alpha.id)
        XCTAssertEqual(target.label(workspaces: [alpha]), "alpha")
        XCTAssertEqual(target.placeholder(workspaces: [alpha]), "Message alpha's claude…")
    }

    /// A pinned workspace can be closed out from under the pill; fall back
    /// to Auto rather than rendering a dangling name.
    func testVanishedWorkspaceFallsBackToAuto() {
        let target = ComposerTarget.workspace(UUID())
        XCTAssertEqual(target.label(workspaces: [alpha]), "Auto")
        XCTAssertEqual(target.placeholder(workspaces: [alpha]), "Message Claude…")
    }
}
