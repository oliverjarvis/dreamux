import SwiftUI

struct HomeView: View {
    @Bindable var store: ProjectStore
    /// How to open a project when one of its cards is clicked. `nil` — the
    /// standalone Home *window* — opens a dedicated project window. When
    /// supplied, Home is embedded inside a project window's sidebar and
    /// switches that window in place; its presence also suppresses the
    /// launch redirect and the standalone min-size frame.
    var onOpenProject: ((UUID) -> Void)? = nil

    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    @State private var showCreate = false
    @State private var pendingDelete: Project?
    @State private var deleteError: String?

    /// One-shot per process: true exactly once, for the launch
    /// presentation of Home. Static because the view struct is
    /// recreated on every render and the window can be reopened.
    @MainActor private static var didAttemptLaunchRedirect = false

    @MainActor private static func consumeLaunchRedirect() -> Bool {
        if didAttemptLaunchRedirect { return false }
        didAttemptLaunchRedirect = true
        return true
    }

    /// A project window appearing means launch already landed somewhere
    /// — any later Home presentation is deliberate, so the redirect
    /// must not fire. Called from ProjectWindowContents.onAppear.
    @MainActor static func disarmLaunchRedirect() {
        didAttemptLaunchRedirect = true
    }

    /// The standalone Home window wants a sensible minimum size; embedded
    /// Home inherits the project window's bounds, so it imposes none.
    private var minSize: CGSize? {
        onOpenProject == nil ? CGSize(width: 560, height: 420) : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
        }
        .frame(minWidth: minSize?.width, minHeight: minSize?.height)
        .onAppear { store.refresh() }
        .task {
            // Embedded Home (inside a project window) is a deliberate
            // destination — skip the launch redirect and e2e auto-open.
            guard onOpenProject == nil else { return }
            // e2e harness convenience: jump straight into the named
            // project's window so drivers don't have to script the
            // project grid. No-op when the name doesn't match a
            // discovered project.
            if let name = E2EMode.autoOpenProjectName {
                store.refresh()
                if let project = store.projects.first(where: { $0.name == name }) {
                    openProject(project.id)
                }
                return
            }
            // Normal launches skip the grid: the first Home presentation
            // per process redirects into the last-opened project (or the
            // first one) so the user lands in a workspace, not a menu.
            // Later presentations (⇧⌘0, the rail's Home row) show Home
            // normally. E2E runs keep the grid scriptable unless the
            // auto-open env var asked otherwise.
            guard !E2EMode.isActive, HomeView.consumeLaunchRedirect() else { return }
            store.refresh()
            if case .project(let id) = LaunchDestination.resolve(
                lastOpenedID: LastOpenedProject.load(),
                projects: store.projects
            ) {
                openProject(id)
            }
        }
        .sheet(isPresented: $showCreate) {
            CreateProjectSheet(store: store) { project in
                openProject(project.id)
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

    // MARK: - Sections

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Clayspace")
                .font(.system(size: 34, weight: .bold))
            Spacer()
            Button {
                store.refresh()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .keyboardShortcut("r", modifiers: [.command])
            .help("Rescan the projects folder")

            Button(action: showCreateSheet) {
                Label("New Project", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut("n", modifiers: [.command])
        }
        .padding(20)
    }

    @ViewBuilder
    private var content: some View {
        if store.projects.isEmpty {
            emptyState
        } else {
            projectList
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "folder")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            Text("No projects yet").font(.headline)
            Text("Create your first project to spin up a fresh workspace.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("Create Project", action: showCreateSheet)
                .buttonStyle(.bordered)
                .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    private var projectList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text("Projects")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .padding(.top, 16)
                    .padding(.bottom, 4)

                LazyVGrid(columns: gridColumns, spacing: 12) {
                    ForEach(store.projects) { project in
                        ProjectCard(
                            project: project,
                            onOpen: { openProject(project.id) },
                            onDelete: { pendingDelete = project }
                        )
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
    }

    private var gridColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 200), spacing: 12, alignment: .top)]
    }

    // MARK: - Actions

    private func showCreateSheet() {
        showCreate = true
    }

    private func openProject(_ id: UUID) {
        if let onOpenProject {
            onOpenProject(id)
            return
        }
        openWindow(value: id)
        dismissWindow(id: "home")
    }

    private func deleteProject(_ project: Project) {
        do {
            try store.deleteProject(project)
        } catch {
            deleteError = error.localizedDescription
        }
    }
}

// MARK: - Row

private struct ProjectCard: View {
    let project: Project
    let onOpen: () -> Void
    let onDelete: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 0) {
                // Icon area takes the top half of the card and centers
                // a large folder icon so the visual weight balances the
                // text below.
                Image(systemName: "folder.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(.tint)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                VStack(alignment: .leading, spacing: 2) {
                    Text(project.name)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(project.createdAt, format: .dateTime.year().month(.abbreviated).day())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(16)
            .frame(height: 150)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isHovered ? Color.primary.opacity(0.09) : Color.primary.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(isHovered ? 0.14 : 0.06), lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(project.rootPath.path)
        .contextMenu {
            Button("Open in New Window", action: onOpen)
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([project.rootPath])
            }
            Divider()
            Button("Move to Trash…", role: .destructive, action: onDelete)
        }
    }
}
