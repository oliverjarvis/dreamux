import XCTest
import SwiftUI
@testable import Dreamux

/// The whole point of the launcher: fire twice, get two live sessions.
/// `sendPrompt` is swapped for a capturing closure so assertions can see
/// the prompt without driving a PTY — the same seam
/// `PlanRunCoordinator.sendPrompt` uses. (`PlanningSessionLauncher` had
/// none, which is why its behaviour was untested.)
@MainActor
final class IdeaIntakeLauncherTests: XCTestCase {
    private var sandbox: TestSandbox!
    private var project: Project!

    override func setUpWithError() throws {
        sandbox = try TestSandbox()
        project = try sandbox.makeProject(named: "demo")
    }

    override func tearDown() {
        sandbox?.destroy()
        sandbox = nil
        project = nil
    }

    private struct Rig {
        let store: WorkspaceStore
        let repoStore: RepoStore
        let docStore: DocStore
        let planQueue: PlanQueueController
        let launcher: IdeaIntakeLauncher
    }

    private func makeRig() -> Rig {
        let repoStore = RepoStore(project: project)
        repoStore.refresh()
        let docStore = DocStore(project: project)
        docStore.refresh()
        return Rig(
            store: WorkspaceStore(defaultWorkingDirectory: project.rootPath.path),
            repoStore: repoStore,
            docStore: docStore,
            planQueue: PlanQueueController(project: project),
            launcher: IdeaIntakeLauncher())
    }

    /// `.constant` is fine here: the launcher only ever WRITES
    /// `.workspace` into this binding, and nothing in the test reads it.
    private let mode: Binding<SidebarMode> = .constant(.workspace)

    private func fire(_ rig: Rig, idea: String, onPrompt: @escaping (String) -> Void = { _ in }) {
        rig.launcher.sendPrompt = { prompt, _ in onPrompt(prompt) }
        rig.launcher.fire(
            title: IdeaTitle.tabTitle(for: idea),
            store: rig.store, repoStore: rig.repoStore, docStore: rig.docStore,
            planQueue: rig.planQueue, sidebarMode: mode
        ) { digest in
            PlanPrompts.brainstormKickoff(idea: idea, intakeDigest: digest)
        }
    }

    private func mainSession(_ rig: Rig) throws -> WorkspaceSession {
        let main = try XCTUnwrap(rig.store.workspaces.first(where: \.isMain))
        return rig.store.session(for: main)
    }

    /// One fire → `main` exists, is active, and holds exactly one intake tab.
    func testFireCreatesMainAndOneIntakeTab() throws {
        let rig = makeRig()
        fire(rig, idea: "browser tile")

        let main = try XCTUnwrap(rig.store.workspaces.first(where: \.isMain))
        XCTAssertEqual(rig.store.activeID, main.id)
        XCTAssertEqual(main.workingDirectory, project.rootPath.path,
                       "an intake session's cwd is the project root, so it sees docs/ and repos/")
        XCTAssertEqual(try mainSession(rig).intakeTabTitles, ["idea: browser tile"])
    }

    /// The case that is impossible today: a second idea fired while the
    /// first conversation is live gets its OWN tab, not the first one back.
    func testTwoConsecutiveFiresProduceTwoDistinctTabs() throws {
        let rig = makeRig()
        fire(rig, idea: "browser tile")
        fire(rig, idea: "sidebar hover states")

        XCTAssertEqual(rig.store.workspaces.filter(\.isMain).count, 1,
                       "both ideas land in the ONE main workspace")
        XCTAssertEqual(
            Set(try mainSession(rig).intakeTabTitles),
            ["idea: browser tile", "idea: sidebar hover states"])
    }

    /// The second fire's digest names the first session — and never itself.
    func testSecondFiresDigestNamesTheFirstSessionAndNotItself() throws {
        let rig = makeRig()

        let first = expectation(description: "first prompt")
        fire(rig, idea: "browser tile") { prompt in
            XCTAssertFalse(prompt.contains("Idea sessions in progress"),
                           "the first fire has no siblings")
            first.fulfill()
        }
        wait(for: [first], timeout: 5)

        let second = expectation(description: "second prompt")
        fire(rig, idea: "sidebar hover states") { prompt in
            XCTAssertTrue(prompt.contains("Idea sessions in progress"))
            XCTAssertTrue(prompt.contains("idea: browser tile"))
            XCTAssertFalse(prompt.contains("idea: sidebar hover"),
                           "a session is never named in its own digest")
            second.fulfill()
        }
        wait(for: [second], timeout: 5)
    }

    /// Closing an intake tab drops it from the sibling list.
    func testClosingAnIntakeTabUntracksIt() throws {
        let rig = makeRig()
        fire(rig, idea: "browser tile")
        let session = try mainSession(rig)
        let tabID = try XCTUnwrap(session.lastCreatedTabID)
        _ = session.controller.closeTab(tabID)
        XCTAssertTrue(session.intakeTabTitles.isEmpty)
    }
}
