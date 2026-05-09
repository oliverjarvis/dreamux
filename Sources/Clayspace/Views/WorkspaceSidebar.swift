import SwiftUI

struct WorkspaceSidebar: View {
    @Bindable var store: WorkspaceStore
    @Bindable var repoStore: RepoStore

    @State private var showAddRepo = false
    @State private var addRepoError: String?
    @State private var isAddingRepo = false

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 12) {
                repositoriesSection
                if !orphanedWorkspaces.isEmpty {
                    Divider()
                    orphanedSection
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 12)
        }
        .sheet(isPresented: $showAddRepo) {
            AddRepoSheet(
                projectName: repoStore.project.name,
                onSubmit: handleAddRepo,
                onCancel: { showAddRepo = false }
            )
        }
        .alert(
            "Couldn't add repository",
            isPresented: Binding(
                get: { addRepoError != nil },
                set: { if !$0 { addRepoError = nil } }
            ),
            presenting: addRepoError
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { error in
            Text(error)
        }
    }

    // MARK: - Repositories

    private var repositoriesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Repositories")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 2)

            if repoStore.repositories.isEmpty {
                Text("Add a repository to start creating Work Items inside it.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
            } else {
                ForEach(repoStore.repositories) { repo in
                    RepoSection(
                        repo: repo,
                        workspaces: store.workspaces(under: repo),
                        store: store,
                        onAddWorkItem: { store.addWorkspace(under: repo) }
                    )
                }
            }

            Button {
                showAddRepo = true
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: isAddingRepo ? "hourglass" : "plus")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 28, height: 28)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(.quaternary)
                        )
                        .foregroundStyle(.secondary)
                    Text(isAddingRepo ? "Adding…" : "Add Repository")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isAddingRepo)
        }
    }

    private var orphanedWorkspaces: [Workspace] {
        store.workspaces.filter { workspace in
            guard let repoID = workspace.repoID else { return true }
            return !repoStore.repositories.contains { $0.name == repoID }
        }
    }

    @ViewBuilder
    private var orphanedSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Other Work Items")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 2)

            ForEach(orphanedWorkspaces) { workspace in
                WorkspaceButton(
                    workspace: workspace,
                    isActive: workspace.id == store.activeID,
                    hasUnread: store.hasUnread(for: workspace),
                    lastActivityMessage: store.lastActivityMessage(for: workspace),
                    onSelect: { store.activate(workspace.id) },
                    onClose: { store.remove(workspace) },
                    onRename: { store.setName($0, for: workspace.id) },
                    onPickSymbol: { store.setIcon($0, for: workspace.id) },
                    onPickTint: { store.setTint($0, for: workspace.id) }
                )
            }
        }
    }

    private func handleAddRepo(_ intent: AddRepoIntent) {
        showAddRepo = false
        isAddingRepo = true
        Task {
            do {
                let repo: Repository
                switch intent {
                case .clone(let url, let name):
                    repo = try await repoStore.clone(url: url, name: name)
                case .initialize(let name):
                    repo = try await repoStore.initRepo(name: name)
                case .importLocal(let path, let name):
                    repo = try await repoStore.importLocal(path: path, name: name)
                }
                // Seed a default work item under the freshly-added repo so
                // the user lands in a usable terminal immediately.
                if store.workspaces(under: repo).isEmpty {
                    store.addWorkspace(under: repo)
                }
            } catch {
                addRepoError = error.localizedDescription
            }
            isAddingRepo = false
        }
    }
}

// MARK: - Repo section (header + nested work items)

private struct RepoSection: View {
    let repo: Repository
    let workspaces: [Workspace]
    @Bindable var store: WorkspaceStore
    let onAddWorkItem: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            RepoHeader(repo: repo)

            VStack(spacing: 4) {
                ForEach(workspaces) { workspace in
                    WorkspaceButton(
                        workspace: workspace,
                        isActive: workspace.id == store.activeID,
                        hasUnread: store.hasUnread(for: workspace),
                        lastActivityMessage: store.lastActivityMessage(for: workspace),
                        onSelect: { store.activate(workspace.id) },
                        onClose: { store.remove(workspace) },
                        onRename: { store.setName($0, for: workspace.id) },
                        onPickSymbol: { store.setIcon($0, for: workspace.id) },
                        onPickTint: { store.setTint($0, for: workspace.id) }
                    )
                }

                AddWorkItemRow(action: onAddWorkItem)
            }
            .padding(.leading, 16) // indent under the repo header
        }
    }
}

private struct RepoHeader: View {
    let repo: Repository

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.secondary.opacity(isHovered ? 0.18 : 0.12))
                Image(systemName: "shippingbox.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 0) {
                Text(repo.name)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(repo.defaultBranch)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .help(repo.rootURL.path)
        .contextMenu {
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([repo.rootURL])
            }
        }
    }
}

private struct AddWorkItemRow: View {
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 22, height: 22)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(.quaternary)
                    )
                    .foregroundStyle(.secondary)
                Text("Add Work Item")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isHovered ? Color.primary.opacity(0.04) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

private struct WorkspaceButton: View {
    let workspace: Workspace
    let isActive: Bool
    let hasUnread: Bool
    let lastActivityMessage: String?
    let onSelect: () -> Void
    let onClose: () -> Void
    let onRename: (String) -> Void
    let onPickSymbol: (String) -> Void
    let onPickTint: (Color) -> Void

    @State private var isHovered = false
    @State private var isPickerPresented = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(workspace.tint.opacity(isActive ? 0.95 : (isHovered ? 0.32 : 0.18)))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(workspace.tint.opacity(isActive ? 0 : 0.28), lineWidth: 1)
                        )
                    Image(systemName: workspace.symbol)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(isActive ? Color.white : workspace.tint)
                }
                .frame(width: 28, height: 28)
                .overlay(alignment: .topTrailing) {
                    // Attention badge — anchored to the icon's corner.
                    Circle()
                        .fill(Color.red)
                        .frame(width: 9, height: 9)
                        .overlay(
                            Circle()
                                .strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5)
                        )
                        .offset(x: 3, y: -3)
                        .opacity(hasUnread ? 1 : 0)
                        .animation(.snappy(duration: 0.18), value: hasUnread)
                        .accessibilityHidden(true)
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text(workspace.name)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundStyle(isActive ? .primary : .secondary)
                    if let lastActivityMessage, !lastActivityMessage.isEmpty {
                        // Most recent agent notification — gives the user
                        // a peek at what the badge is for without having
                        // to switch into the workspace.
                        Text(lastActivityMessage)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(
                        isActive
                            ? Color.primary.opacity(0.10)
                            : (isHovered ? Color.primary.opacity(0.05) : Color.clear)
                    )
            )
            .overlay(alignment: .leading) {
                // Active-pill indicator hugging the leading edge of the row.
                Capsule()
                    .fill(.primary)
                    .frame(width: 3, height: isActive ? 22 : 0)
                    .offset(x: -8)
                    .animation(.snappy(duration: 0.18), value: isActive)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(workspace.name)
        .contextMenu {
            Button("Customize…") { isPickerPresented = true }
            Divider()
            Button("Close \"\(workspace.name)\"", role: .destructive, action: onClose)
        }
        // Sheet (not popover) — a popover anchored to a tile near the
        // window's leading edge gets clipped by neighbouring rails. A
        // sheet floats above the whole window, centered, with no
        // hierarchy-clipping concerns.
        .sheet(isPresented: $isPickerPresented) {
            CustomizeWorkspaceSheet(
                initialName: workspace.name,
                selectedSymbol: workspace.symbol,
                selectedTint: workspace.tint,
                onRename: onRename,
                onPickSymbol: onPickSymbol,
                onPickTint: onPickTint,
                onDismiss: { isPickerPresented = false }
            )
        }
    }
}

private struct CustomizeWorkspaceSheet: View {
    let initialName: String
    let selectedSymbol: String
    let selectedTint: Color
    let onRename: (String) -> Void
    let onPickSymbol: (String) -> Void
    let onPickTint: (Color) -> Void
    let onDismiss: () -> Void

    @State private var name: String = ""
    @FocusState private var nameFocused: Bool

    private static let symbols: [String] = [
        "terminal.fill",
        "house.fill",
        "chevron.left.forwardslash.chevron.right",
        "doc.text.magnifyingglass",
        "circle.grid.3x3.fill",
        "square.stack.3d.up.fill",
        "globe",
        "bolt.fill",
        "leaf.fill",
        "hammer.fill",
        "wrench.and.screwdriver.fill",
        "server.rack",
        "cloud.fill",
        "cpu.fill",
        "externaldrive.fill",
        "shippingbox.fill",
        "graduationcap.fill",
        "briefcase.fill",
        "paintpalette.fill",
        "gamecontroller.fill",
        "music.note",
        "flag.fill",
        "star.fill",
        "heart.fill"
    ]

    private static let tints: [Color] = [
        .blue, .purple, .pink, .red, .orange, .yellow, .green, .teal, .indigo, .gray
    ]

    private let columns = Array(repeating: GridItem(.fixed(36), spacing: 10), count: 6)

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Customize Workspace")
                .font(.title3.weight(.semibold))

            VStack(alignment: .leading, spacing: 6) {
                Text("Name")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                TextField("Feature name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .focused($nameFocused)
                    .onSubmit { commitName(); onDismiss() }
                    .onChange(of: name) { _, _ in commitName() }
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Icon")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                    LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(Self.symbols, id: \.self) { symbol in
                        Button {
                            onPickSymbol(symbol)
                        } label: {
                            Image(systemName: symbol)
                                .font(.system(size: 15, weight: .semibold))
                                .frame(width: 36, height: 36)
                                .background(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(symbol == selectedSymbol ? selectedTint.opacity(0.85) : Color.secondary.opacity(0.12))
                                )
                                .foregroundStyle(symbol == selectedSymbol ? Color.white : .primary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Tint")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                HStack(spacing: 10) {
                    ForEach(Self.tints, id: \.self) { tint in
                        Button {
                            onPickTint(tint)
                        } label: {
                            Circle()
                                .fill(tint)
                                .frame(width: 24, height: 24)
                                .overlay(
                                    Circle()
                                        .strokeBorder(Color.primary.opacity(tint == selectedTint ? 0.9 : 0), lineWidth: 2)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            HStack {
                Spacer()
                Button("Done") {
                    commitName()
                    onDismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear {
            name = initialName
            nameFocused = true
        }
    }

    private func commitName() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != initialName else { return }
        onRename(trimmed)
    }
}
