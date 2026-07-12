import SwiftUI

/// First-run / zero-projects landing. Shown by `LaunchGate` when the
/// store has no projects to open. It deliberately does *not* list
/// projects (there are none) — it only invites the user to create their
/// first, after which the launch gate routes the window into it.
struct WelcomeView: View {
    let store: ProjectStore
    /// Switch this window to the freshly created project.
    let onOpenProject: (UUID) -> Void

    @State private var showCreate = false

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "folder")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            Text("No projects yet").font(.headline)
            Text("Create your first project to spin up a fresh workspace.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Create Project") { showCreate = true }
                .buttonStyle(.borderedProminent)
                .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
        .onAppear { store.refresh() }
        .focusedSceneValue(\.createProjectPresented, $showCreate)
        .sheet(isPresented: $showCreate) {
            CreateProjectSheet(store: store) { project in
                onOpenProject(project.id)
            }
        }
    }
}
