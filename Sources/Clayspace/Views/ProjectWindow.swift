import SwiftUI

/// A single project's window. Owns its own `WorkspaceStore` (scoped to the
/// project's root directory) and exposes that store via `FocusedValue` so
/// that the global menu bar's commands route to the front-most project.
struct ProjectWindow: View {
    let project: Project

    @State private var store: WorkspaceStore

    init(project: Project) {
        self.project = project
        _store = State(
            initialValue: WorkspaceStore(defaultWorkingDirectory: project.rootPath.path)
        )
    }

    var body: some View {
        ContentView(store: store)
            .navigationTitle(project.name)
            .navigationSubtitle(project.rootPath.path)
            .focusedSceneValue(\.activeStore, store)
    }
}

// MARK: - Focused value plumbing

private struct ActiveStoreKey: FocusedValueKey {
    typealias Value = WorkspaceStore
}

extension FocusedValues {
    var activeStore: WorkspaceStore? {
        get { self[ActiveStoreKey.self] }
        set { self[ActiveStoreKey.self] = newValue }
    }
}
