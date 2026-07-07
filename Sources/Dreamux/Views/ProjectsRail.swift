import SwiftUI
import AppKit

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
    let onSelect: (UUID?) -> Void
    /// Collapses the rail — the toggle sits in the rail's top zone, next
    /// to the floating traffic lights (there is no window toolbar).
    let onToggleRail: () -> Void

    @Environment(\.openWindow) private var openWindow
    @State private var showCreate = false
    @State private var pendingDelete: Project?
    @State private var deleteError: String?
    @State private var customizing: Project?

    var body: some View {
        List(selection: selectionBinding) {
            ForEach(projects.projects) { project in
                Label {
                    Text(project.name)
                } icon: {
                    ProjectGlyph(name: project.name, size: 18,
                                 symbol: project.symbol, tint: project.glyphTint())
                }
                .tag(project.id)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(project.rootPath.path)
                .contextMenu {
                    Button("Customize…") { customizing = project }
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
            // New Project rides directly below the last project, one of
            // the rows rather than a pinned bottom bar.
            Button {
                showCreate = true
            } label: {
                Label("New Project", systemImage: "plus")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Create a new project")
        }
        .listStyle(.sidebar)
        // The rail sits flat on the window's inset backdrop, like the
        // reference chrome — no material of its own, no hairlines.
        .scrollContentBackground(.hidden)
        // Top zone: the traffic lights float over the leading edge (the
        // rail runs to the very top of the window); the collapse toggle
        // sits at the far right of the Projects header row.
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Color.clear.frame(height: 30)
                HStack {
                    Text("Projects")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Button(action: onToggleRail) {
                        Image(systemName: "sidebar.left")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Color.secondary)
                            .frame(width: 26, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Toggle projects sidebar")
                }
                .padding(.leading, 12)
                .padding(.trailing, 10)
                .padding(.bottom, 6)
            }
        }
        .onAppear { projects.refresh() }
        .sheet(isPresented: $showCreate) {
            CreateProjectSheet(store: projects) { project in
                onSelect(project.id)
            }
        }
        .sheet(item: $customizing) { project in
            CustomizeProjectSheet(
                projectName: project.name,
                selectedSymbol: project.symbol,
                selectedTintHex: project.tintHex,
                onPickSymbol: { projects.setSymbol($0, for: project.id) },
                onPickTintHex: { projects.setTintHex($0, for: project.id) },
                onDismiss: { customizing = nil }
            )
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

    /// Bridges the native list selection to the window's current project.
    /// Picking a *different* project routes through `onSelect`, which
    /// rewrites the WindowGroup binding and rebuilds the window.
    private var selectionBinding: Binding<UUID?> {
        Binding(
            get: { currentProjectID },
            set: { newValue in
                if let id = newValue, id != currentProjectID { onSelect(id) }
            }
        )
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
            // No projects left — clear this window so the launch gate
            // re-resolves to the Welcome screen. A project window can't
            // exist without a project.
            onSelect(nil)
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
