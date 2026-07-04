import SwiftUI

/// A single project's window. The WindowGroup's binding is the source of
/// truth for which project this window shows — the rail's "switch
/// project" action writes back through `onSwitchProject` so SwiftUI's
/// window dedup also moves with the switch (otherwise opening the
/// originally-bound project in a new window would just bring this one
/// forward).
///
/// Per-project state (terminals, dev servers, doc watchers, the plan
/// queue) lives in `ProjectSession` bundles cached in a window-scoped
/// registry. Switching projects rebuilds the *views* (the `.id` below)
/// but reuses the bundle, so shells keep their scrollback and running
/// work is never interrupted; bundles die with the window.
struct ProjectWindow: View {
    let project: Project
    let onSwitchProject: (UUID?) -> Void

    @Environment(ProjectStore.self) private var projectStore
    @State private var sessions = ProjectSessionRegistry()

    var body: some View {
        ProjectWindowContents(
            session: sessions.session(for: project),
            projects: projectStore,
            onSwitchProject: onSwitchProject
        )
        .id(project.id)
    }
}

/// Inner view keyed off the current project's id so SwiftUI resets its
/// view state (sidebar mode, file-tree visibility, …) when the user picks
/// a different project in the rail. The stores it renders come from the
/// long-lived `ProjectSession`, not from here.
private struct ProjectWindowContents: View {
    let session: ProjectSession
    let projects: ProjectStore
    let onSwitchProject: (UUID?) -> Void

    var body: some View {
        ContentView(
            session: session,
            projects: projects,
            onSwitchProject: onSwitchProject
        )
        .onAppear {
            // Remember where the user was so the next launch can land
            // here instead of the Home grid.
            LastOpenedProject.record(session.project.id)
            session.repoStore.refresh()
            // First appear only: reconstruct the feature list from the
            // worktrees on disk. Switch-backs skip it — reloading over
            // live workspaces would disturb their running terminals.
            session.bootstrapIfNeeded()
            // e2e only (no-op otherwise): point the automation server at
            // this window's live stores and switch action.
            session.registerWithE2E()
            E2ERegistry.shared.registerProjectSwitcher(onSwitchProject)
            // App-context only (UNUserNotificationCenter is unavailable
            // to SPM test processes): auto-run failures notify — the
            // launch is unattended by nature.
            session.onAutoRunFailure = { title, message in
                NotificationManager.shared.notify(
                    title: "Couldn't auto-run \(title)", body: message)
            }
        }
        .onDisappear {
            // e2e bookkeeping (handles are weak; the bundle lives on in
            // the registry). Scoped to THIS project only: whether an
            // `.id()` swap runs the old view's onDisappear before or
            // after the new view's onAppear is underspecified, and a
            // blanket unregister in the late ordering would wipe the
            // incoming project's fresh registration.
            E2ERegistry.shared.unregister(projectID: session.project.id)
        }
        .focusedSceneValue(\.activeStore, session.store)
        .focusedSceneValue(\.activeProject, session.project)
    }
}

// MARK: - Focused value plumbing

private struct ActiveStoreKey: FocusedValueKey {
    typealias Value = WorkspaceStore
}

private struct ActiveProjectKey: FocusedValueKey {
    typealias Value = Project
}

extension FocusedValues {
    var activeStore: WorkspaceStore? {
        get { self[ActiveStoreKey.self] }
        set { self[ActiveStoreKey.self] = newValue }
    }

    var activeProject: Project? {
        get { self[ActiveProjectKey.self] }
        set { self[ActiveProjectKey.self] = newValue }
    }
}
