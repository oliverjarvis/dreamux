import SwiftUI
import AppKit

/// A single entry in the project sidebar's native selection: the Home
/// landing page or one specific project. Both share the `List`'s selection
/// so exactly one row highlights at a time.
private enum SidebarItem: Hashable {
    case home
    case project(UUID)
}

/// Outermost project-switcher sidebar, rendered as a native macOS source
/// list — it's the sidebar column of the project window's
/// NavigationSplitView, so it inherits the system vibrancy, the titlebar
/// collapse toggle, and the standard selection highlight for free.
///
/// It lists every project in the user's ProjectStore and lets the user:
///   • click a row to swap the current window to that project,
///   • right-click a row for "Open in New Window", "Show in Finder", and
///     "Move to Trash…",
///   • hit "New Project", pinned to the bottom, to create one.
struct ProjectsRail: View {
    let projects: ProjectStore
    let currentProjectID: UUID
    @Binding var showingHome: Bool
    let onSelect: (UUID) -> Void

    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var showCreate = false
    @State private var pendingDelete: Project?
    @State private var deleteError: String?

    var body: some View {
        List(selection: selectionBinding) {
            // Home is an in-window destination: selecting it swaps the
            // detail pane to the Home landing page (handled in ContentView)
            // rather than opening a separate window.
            Label("Home", systemImage: "house")
                .tag(SidebarItem.home)
                .help("Show Home")

            Section("Projects") {
                ForEach(projects.projects) { project in
                    Label(project.name, systemImage: "folder")
                        .tag(SidebarItem.project(project.id))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(project.rootPath.path)
                        .contextMenu {
                            Button("Open in New Window") {
                                openInNewWindow(project.id)
                            }
                            Button("Show in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([project.rootPath])
                            }
                            Divider()
                            Button("Move to Trash…", role: .destructive) {
                                pendingDelete = project
                            }
                        }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            newProjectBar
        }
        .onAppear { projects.refresh() }
        .sheet(isPresented: $showCreate) {
            CreateProjectSheet(store: projects) { project in
                onSelect(project.id)
            }
        }
        .alert(
            "Move \(pendingDelete?.name ?? "project") to Trash?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            presenting: pendingDelete
        ) { project in
            Button("Move to Trash", role: .destructive) {
                deleteProject(project)
            }
            Button("Cancel", role: .cancel) {}
        } message: { project in
            Text("The folder at \(project.rootPath.path) will be moved to the Trash. You can recover it from Finder if you change your mind.")
        }
        .alert(
            "Couldn't delete project",
            isPresented: Binding(
                get: { deleteError != nil },
                set: { if !$0 { deleteError = nil } }
            ),
            presenting: deleteError
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { error in
            Text(error)
        }
    }

    /// Two-way bridge between the native List selection and the window's
    /// state. The getter reflects whether Home or a project is showing; the
    /// setter routes the pick: Home flips the detail to the landing page in
    /// place, a *different* project goes through `onSelect` (which rewrites
    /// the WindowGroup binding and rebuilds the window), and re-picking the
    /// current project from Home just dismisses Home — no rebuild, so its
    /// terminals stay live.
    private var selectionBinding: Binding<SidebarItem?> {
        Binding(
            get: { showingHome ? .home : .project(currentProjectID) },
            set: { newValue in
                switch newValue {
                case .home:
                    showingHome = true
                case .project(let id):
                    showingHome = false
                    if id != currentProjectID { onSelect(id) }
                case .none:
                    break
                }
            }
        )
    }

    /// "＋ New Project" pinned beneath the list as a native bottom bar.
    private var newProjectBar: some View {
        VStack(spacing: 0) {
            Divider()
            Button {
                showCreate = true
            } label: {
                Label("New Project", systemImage: "plus")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .padding(.horizontal, 18)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.plain)
            .help("Create a new project")
        }
        .background(.bar)
    }

    /// Delete and, when the row was the project this window is showing,
    /// move the window somewhere sensible: the first remaining project,
    /// or Home when the list just emptied (a project window can't exist
    /// without a project). Other windows showing the deleted project
    /// fall back to MissingProjectView on their own.
    private func deleteProject(_ project: Project) {
        let wasCurrent = project.id == currentProjectID
        do {
            try projects.deleteProject(project)
        } catch {
            deleteError = error.localizedDescription
            return
        }
        guard wasCurrent else { return }
        if let fallback = projects.projects.first {
            onSelect(fallback.id)
        } else {
            openWindow(id: "home")
            dismissWindow(id: "project", value: project.id)
        }
    }

    /// Snapshot the existing project-window list before asking SwiftUI to
    /// open a window, then bring whichever NSWindow appears afterwards to
    /// the front. SwiftUI's `openWindow(value:)` dedupes by binding value
    /// so opening the *current* window's project just brings it forward;
    /// opening any other project creates a fresh window, but in our
    /// testing that window sometimes ends up behind the existing one —
    /// the explicit activate + makeKeyAndOrderFront fixes that.
    private func openInNewWindow(_ id: UUID) {
        let before = Set(NSApp.windows.map(ObjectIdentifier.init))
        openWindow(id: "project", value: id)
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            let after = NSApp.windows
            if let newWindow = after.first(where: { !before.contains(ObjectIdentifier($0)) }) {
                newWindow.makeKeyAndOrderFront(nil)
            } else {
                NSApp.keyWindow?.orderFront(nil)
            }
        }
    }
}
