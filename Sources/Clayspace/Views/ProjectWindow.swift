import SwiftUI

/// A single project's window. The WindowGroup's binding is the source of
/// truth for which project this window shows — the rail's "switch
/// project" action writes back through `onSwitchProject` so SwiftUI's
/// window dedup also moves with the switch (otherwise opening the
/// originally-bound project in a new window would just bring this one
/// forward). `WorkspaceStore` and `RepoStore` are scoped to the
/// project's root directory and are rebuilt fresh when the project
/// changes (via the `.id` modifier on the inner contents view).
struct ProjectWindow: View {
    let project: Project
    let onSwitchProject: (UUID) -> Void

    @Environment(ProjectStore.self) private var projectStore

    var body: some View {
        ProjectWindowContents(
            project: project,
            projects: projectStore,
            onSwitchProject: onSwitchProject
        )
        .id(project.id)
    }
}

/// Inner view keyed off the current project's id so SwiftUI re-runs its
/// `init` (and therefore the `@State` initializers for the stores) when
/// the user picks a different project in the rail.
private struct ProjectWindowContents: View {
    let project: Project
    let projects: ProjectStore
    let onSwitchProject: (UUID) -> Void

    @State private var store: WorkspaceStore
    @State private var repoStore: RepoStore

    init(
        project: Project,
        projects: ProjectStore,
        onSwitchProject: @escaping (UUID) -> Void
    ) {
        self.project = project
        self.projects = projects
        self.onSwitchProject = onSwitchProject
        _store = State(
            initialValue: WorkspaceStore(defaultWorkingDirectory: project.rootPath.path)
        )
        _repoStore = State(initialValue: RepoStore(project: project))
    }

    var body: some View {
        ContentView(
            store: store,
            repoStore: repoStore,
            projects: projects,
            currentProjectID: project.id,
            onSwitchProject: onSwitchProject
        )
        // Title/subtitle live in ContentView now so they can track the
        // in-window Home destination (the sidebar can show Home in place
        // of the project's workspace).
        .onAppear {
            // Remember where the user was so the next launch can land
            // here instead of the Home grid.
            LastOpenedProject.record(project.id)
            HomeView.disarmLaunchRedirect()
            // e2e only (no-op otherwise): expose this window's live
            // stores to the automation server, keyed by project id.
            E2ERegistry.shared.registerWindowStores(
                projectID: project.id,
                workspaceStore: store,
                repoStore: repoStore
            )
            repoStore.refresh()
            Task {
                // Reconstruct the feature list from the worktrees
                // we find on disk so a relaunch comes back to the
                // same set of work items the user closed with.
                await store.reloadFeatures(in: project, repoStore: repoStore)
            }
        }
        .onDisappear {
            E2ERegistry.shared.unregister(projectID: project.id)
        }
        .focusedSceneValue(\.activeStore, store)
        .focusedSceneValue(\.activeProject, project)
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
