import Foundation
import Observation

/// Pending UI actions the automation server hands to the view layer,
/// one bridge per project window. Views consume (and clear) each value
/// via `.onAppear`/`.onChange`, following the exact precedent of
/// `RunnerManager.pendingIsolation` — the server can't reach a view's
/// `@State`, so it parks intent here and lets SwiftUI's observation
/// pull it in on the next update.
///
/// `pendingIsolation` itself intentionally stays on `RunnerManager`
/// (the Run pane already consumes it); the `isolateRunner` command
/// writes there directly rather than duplicating the channel.
@MainActor
@Observable
final class E2EBridge {
    /// Sidebar pane the project window should switch to. Consumed by
    /// `FeaturesDetail` in ContentView.swift.
    var pendingSidebarMode: SidebarMode?

    /// Workspace whose merge sheet should open. Consumed by
    /// `WorkspaceSidebar`, which owns the sheet's presentation state.
    var pendingMergeWorkspaceID: UUID?

    /// Desired visibility of the right-side file explorer, parked by the
    /// `setFileTree` command and consumed by `ContentView`.
    var pendingFileTreeVisible: Bool?

    /// Lane id the Flows pane should zoom into, parked by the
    /// `zoomFlow` command and consumed by `ContentView` into
    /// `flowsZoomLaneID`. `nil` means "nothing pending" (the
    /// consume-and-clear idiom every other `pending*` field uses); since
    /// `zoomFlow`'s own "clear the zoom" request is itself a `nil`
    /// target, that request is parked as the empty string instead —
    /// the one lane id value that can never be real.
    var pendingFlowsZoomLaneID: String?

    /// When true, the Run pane kicks off its Detect flow (sending the
    /// detect prompt to the `claude` CLI in its embedded terminal) the
    /// moment it's on screen. Consumed by `RunSetupView`.
    var pendingDetect = false

    /// Mirror of the project window's current sidebar mode, written by
    /// `FeaturesDetail` whenever it changes so the `state` command can
    /// report it. Never consumed.
    var currentSidebarMode: SidebarMode = .workspace
}

/// Live handles for one project window. Store references are weak —
/// SwiftUI's `@State` owns the stores, and a closed window must not be
/// kept alive by the harness.
@MainActor
final class E2EProjectHandles {
    let projectID: UUID
    weak var workspaceStore: WorkspaceStore?
    weak var repoStore: RepoStore?
    weak var runners: RunnerManager?
    weak var runConfig: RunConfigStore?
    weak var signals: SignalStore?
    weak var docStore: DocStore?
    weak var planRunner: PlanRunCoordinator?
    weak var planQueue: PlanQueueController?
    weak var nudgeCenter: PlanNudgeCenter?
    weak var flows: FlowStore?
    /// The whole per-project session bundle — the applets commands need
    /// more than a store: `appletSession(for:)`/`closeAppletSession(id:)`
    /// live on `ProjectSession` itself, not on `applets`/`appLibrary`.
    weak var session: ProjectSession?
    let bridge = E2EBridge()

    init(projectID: UUID) {
        self.projectID = projectID
    }
}

/// Lookup table the automation server uses to reach the app's live
/// stores. Views register their stores on appear (and unregister on
/// disappear); every entry point is a no-op unless `E2EMode.isActive`,
/// so a normal launch carries an empty singleton and nothing else.
@MainActor
final class E2ERegistry {
    static let shared = E2ERegistry()

    private(set) var projectStore: ProjectStore?
    private(set) var handlesByProject: [UUID: E2EProjectHandles] = [:]
    /// Project the commands operate on — the most recently registered
    /// project window. Single-window e2e runs never notice; multi-
    /// window scenarios are documented as "last opened wins".
    private(set) var activeProjectID: UUID?

    /// The active window's project-switch action — writes the
    /// WindowGroup's binding, exactly what clicking a project in the
    /// rail does. Re-registered on every window appear; single-window
    /// e2e runs only ever see the current one.
    private(set) var projectSwitcher: ((UUID?) -> Void)?

    private init() {}

    func registerProjectStore(_ store: ProjectStore) {
        guard E2EMode.isActive else { return }
        projectStore = store
    }

    func registerProjectSwitcher(_ switcher: @escaping (UUID?) -> Void) {
        guard E2EMode.isActive else { return }
        projectSwitcher = switcher
    }

    /// Called from `ProjectWindowContents.onAppear` — the window-level
    /// stores exist before the Features section ever renders.
    func registerWindowStores(
        projectID: UUID,
        workspaceStore: WorkspaceStore,
        repoStore: RepoStore
    ) {
        guard E2EMode.isActive else { return }
        let handles = handles(forProject: projectID)
        handles.workspaceStore = workspaceStore
        handles.repoStore = repoStore
        activeProjectID = projectID
    }

    /// Called from `FeaturesDetail.onAppear` — these stores are created
    /// per Features section, one layer below the window stores.
    func registerRunStores(
        projectID: UUID,
        runners: RunnerManager,
        runConfig: RunConfigStore,
        signals: SignalStore
    ) {
        guard E2EMode.isActive else { return }
        let handles = handles(forProject: projectID)
        handles.runners = runners
        handles.runConfig = runConfig
        handles.signals = signals
    }

    /// Called from ContentView.onAppear alongside the run stores. The nudge
    /// center rides along so the `state` dump can report `pendingNudges` per
    /// plan and `courseCorrect` can park into the same live center the sheet
    /// delivers through.
    func registerDocStores(
        projectID: UUID,
        docStore: DocStore,
        planRunner: PlanRunCoordinator,
        planQueue: PlanQueueController,
        nudgeCenter: PlanNudgeCenter
    ) {
        guard E2EMode.isActive else { return }
        let handles = handles(forProject: projectID)
        handles.docStore = docStore
        handles.planRunner = planRunner
        handles.planQueue = planQueue
        handles.nudgeCenter = nudgeCenter
    }

    /// Called from `ProjectSession.registerWithE2E()` alongside the other
    /// per-project stores — the flows store lives on `ProjectSession`
    /// itself, one layer below the Features/Docs sections.
    func registerFlowStore(projectID: UUID, flows: FlowStore) {
        guard E2EMode.isActive else { return }
        let handles = handles(forProject: projectID)
        handles.flows = flows
    }

    /// Called from `ProjectSession.registerWithE2E()` alongside the other
    /// per-project registrations — the applets commands (`createApplet`/
    /// `openApplet`/`adoptApplet`/`removeApplet`/`appletsState`) reach
    /// `session.applets`/`session.appLibrary` plus the session-scoped
    /// `appletSession(for:)`/`closeAppletSession(id:)`.
    func registerSession(projectID: UUID, session: ProjectSession) {
        guard E2EMode.isActive else { return }
        let handles = handles(forProject: projectID)
        handles.session = session
    }

    func unregister(projectID: UUID) {
        guard E2EMode.isActive else { return }
        handlesByProject.removeValue(forKey: projectID)
        if activeProjectID == projectID {
            activeProjectID = handlesByProject.keys.first
        }
    }

    /// Bridge for a project window, or `nil` when the harness is off —
    /// the views' consumption modifiers all hang off this, so inactive
    /// runs short-circuit to nothing. Creates the handles entry on
    /// first access so view-side reads and server-side writes always
    /// land on the same bridge instance regardless of ordering.
    func bridge(forProject id: UUID) -> E2EBridge? {
        guard E2EMode.isActive else { return nil }
        return handles(forProject: id).bridge
    }

    private func handles(forProject id: UUID) -> E2EProjectHandles {
        if let existing = handlesByProject[id] { return existing }
        let fresh = E2EProjectHandles(projectID: id)
        handlesByProject[id] = fresh
        return fresh
    }
}
