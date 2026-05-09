import SwiftUI

/// A single project's window. Owns its own `WorkspaceStore` (scoped to the
/// project's root directory) and exposes that store via `FocusedValue` so
/// that the global menu bar's commands route to the front-most project.
struct ProjectWindow: View {
    let project: Project

    @State private var store: WorkspaceStore
    @State private var repoStore: RepoStore

    init(project: Project) {
        self.project = project
        _store = State(
            initialValue: WorkspaceStore(defaultWorkingDirectory: project.rootPath.path)
        )
        _repoStore = State(initialValue: RepoStore(project: project))
    }

    var body: some View {
        ContentView(store: store, repoStore: repoStore)
            .navigationTitle(project.name)
            .navigationSubtitle(project.rootPath.path)
            .onAppear {
                repoStore.refresh()
                seedDefaultWorkspaceIfNeeded()
            }
            .focusedSceneValue(\.activeStore, store)
            .focusedSceneValue(\.activeProject, project)
    }

    /// Cover the "project just got created with a repo" path: when the
    /// window opens for a project whose only repo has no work items yet,
    /// seed one so the user lands in a usable terminal immediately.
    private func seedDefaultWorkspaceIfNeeded() {
        guard store.workspaces.isEmpty,
              let firstRepo = repoStore.repositories.first
        else { return }
        store.addWorkspace(under: firstRepo)
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
