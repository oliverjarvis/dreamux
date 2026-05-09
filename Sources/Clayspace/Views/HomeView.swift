import SwiftUI

struct HomeView: View {
    @Bindable var store: ProjectStore
    @Environment(\.openWindow) private var openWindow

    @State private var showCreate = false
    @State private var newProjectName = ""
    @State private var newProjectRepoMode: CreateRepoMode = .none
    @State private var newProjectRepoURL = ""
    @State private var newProjectRepoName = ""
    @State private var createError: String?
    @State private var isCreating = false

    @State private var pendingDelete: Project?
    @State private var deleteError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
        }
        .frame(minWidth: 560, minHeight: 420)
        .onAppear { store.refresh() }
        .sheet(isPresented: $showCreate, onDismiss: resetCreateState) {
            CreateProjectSheet(
                name: $newProjectName,
                repoMode: $newProjectRepoMode,
                repoURL: $newProjectRepoURL,
                repoName: $newProjectRepoName,
                error: createError,
                isWorking: isCreating,
                onCancel: { if !isCreating { showCreate = false } },
                onCreate: createProject
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

    // MARK: - Sections

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Clayspace").font(.title2.weight(.semibold))
                Text("Anything in \(store.projectsRoot.path) shows up here.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
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
                            onOpen: { openWindow(value: project.id) },
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
        resetCreateState()
        showCreate = true
    }

    private func resetCreateState() {
        newProjectName = ""
        newProjectRepoMode = .none
        newProjectRepoURL = ""
        newProjectRepoName = ""
        createError = nil
        isCreating = false
    }

    private func createProject() {
        guard !isCreating else { return }
        let projectName = newProjectName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !projectName.isEmpty else { return }

        let repoIntent = pendingRepoIntent(forProjectName: projectName)
        isCreating = true
        createError = nil

        Task {
            do {
                let project = try store.createProject(name: projectName)

                // Run the optional repo bootstrap before opening the window
                // so the project window appears with the repo already in
                // place (avoids a "Repositories: empty" flash).
                if let repoIntent {
                    try await runRepoIntent(repoIntent, in: project)
                }

                showCreate = false
                isCreating = false
                openWindow(value: project.id)
            } catch {
                createError = error.localizedDescription
                isCreating = false
            }
        }
    }

    private func pendingRepoIntent(forProjectName projectName: String) -> AddRepoIntent? {
        switch newProjectRepoMode {
        case .none:
            return nil
        case .initialize:
            let trimmed = newProjectRepoName.trimmingCharacters(in: .whitespacesAndNewlines)
            return .initialize(name: trimmed.isEmpty ? projectName : trimmed)
        case .clone:
            let url = newProjectRepoURL.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !url.isEmpty else { return nil }
            let trimmed = newProjectRepoName.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = trimmed.isEmpty ? GitOperations.deriveName(from: url) : trimmed
            return .clone(url: url, name: name)
        }
    }

    private func runRepoIntent(_ intent: AddRepoIntent, in project: Project) async throws {
        switch intent {
        case .clone(let url, let name):
            _ = try await GitOperations.cloneBare(url: url, into: project.rootPath, name: name)
        case .initialize(let name):
            _ = try await GitOperations.initBare(into: project.rootPath, name: name)
        }
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


// MARK: - Create sheet

enum CreateRepoMode: String, CaseIterable, Identifiable {
    case none = "Skip"
    case initialize = "Initialize new"
    case clone = "Clone existing"
    var id: String { rawValue }
}

private struct CreateProjectSheet: View {
    @Binding var name: String
    @Binding var repoMode: CreateRepoMode
    @Binding var repoURL: String
    @Binding var repoName: String
    let error: String?
    let isWorking: Bool
    let onCancel: () -> Void
    let onCreate: () -> Void

    @FocusState private var focused: Field?
    @State private var didTouchRepoName = false

    enum Field { case name, repoURL, repoName }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Project")
                .font(.headline)
            Text("A folder will be created under ~/Documents/Clayspace.")
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 6) {
                Text("Project name")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                TextField("e.g. mobile-app", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused, equals: .name)
                    .disabled(isWorking)
                    .onSubmit(submitIfReady)
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Repository (optional)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Picker("Repository", selection: $repoMode) {
                    ForEach(CreateRepoMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .disabled(isWorking)

                if repoMode == .clone {
                    TextField("git@github.com:owner/repo.git", text: $repoURL)
                        .textFieldStyle(.roundedBorder)
                        .focused($focused, equals: .repoURL)
                        .disabled(isWorking)
                        .onChange(of: repoURL) { _, newURL in
                            if !didTouchRepoName {
                                let derived = GitOperations.deriveName(from: newURL)
                                if !derived.isEmpty { repoName = derived }
                            }
                        }
                }

                if repoMode != .none {
                    TextField(
                        repoMode == .clone ? "Folder name (auto-detected)" : "Folder name (defaults to project name)",
                        text: $repoName
                    )
                    .textFieldStyle(.roundedBorder)
                    .focused($focused, equals: .repoName)
                    .disabled(isWorking)
                    .onChange(of: repoName) { _, _ in didTouchRepoName = true }
                }

                Text("All repos use a bare-with-worktrees layout: .bare/ for git data plus a worktree for the default branch under repos/<name>/.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                if isWorking {
                    ProgressView()
                        .controlSize(.small)
                    Text(workingLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .disabled(isWorking)
                Button(isWorking ? "Creating…" : "Create", action: submitIfReady)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSubmit || isWorking)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear { focused = .name }
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private var trimmedRepoURL: String {
        repoURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSubmit: Bool {
        guard !trimmedName.isEmpty else { return false }
        if repoMode == .clone, trimmedRepoURL.isEmpty { return false }
        return true
    }

    private var workingLabel: String {
        switch repoMode {
        case .clone: return "Cloning repository…"
        case .initialize: return "Initializing repository…"
        case .none: return "Creating project…"
        }
    }

    private func submitIfReady() {
        guard canSubmit else { return }
        onCreate()
    }
}
