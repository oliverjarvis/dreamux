import SwiftUI

struct WorkspaceSidebar: View {
    @Bindable var store: WorkspaceStore
    @Bindable var repoStore: RepoStore
    @Binding var sidebarMode: SidebarMode

    @State private var showAddFeature = false
    @State private var showAddRepo = false
    @State private var addError: String?
    @State private var isWorking = false
    @State private var pendingClose: Workspace?
    @State private var pendingMerge: Workspace?
    @State private var repositoriesExpanded = false

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 16) {
                runTile
                featuresSection
                Divider()
                repositoriesSection
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 12)
        }
        .sheet(isPresented: $showAddFeature) {
            AddFeatureSheet(
                projectName: repoStore.project.name,
                availableRepos: repoStore.repositories,
                onSubmit: handleCreateFeature,
                onCancel: { showAddFeature = false }
            )
        }
        .sheet(isPresented: $showAddRepo) {
            AddRepoSheet(
                projectName: repoStore.project.name,
                onSubmit: handleAddRepo,
                onCancel: { showAddRepo = false }
            )
        }
        .sheet(
            item: $pendingMerge,
            onDismiss: {}
        ) { workspace in
            MergeFeatureSheet(
                workspace: workspace,
                repos: repoStore.repositories.filter { workspace.linkedRepoIDs.contains($0.name) },
                project: repoStore.project,
                onOpenConflictTab: { url, title in
                    openConflictTab(workspace: workspace, url: url, title: title)
                },
                onDismiss: { pendingMerge = nil }
            )
        }
        .alert(
            "Close \(pendingClose?.name ?? "feature")?",
            isPresented: Binding(
                get: { pendingClose != nil },
                set: { if !$0 { pendingClose = nil } }
            ),
            presenting: pendingClose
        ) { workspace in
            Button("Close & Remove Worktrees", role: .destructive) {
                closeFeature(workspace, removeWorktrees: true)
            }
            Button("Close (Keep Worktrees)") {
                closeFeature(workspace, removeWorktrees: false)
            }
            Button("Cancel", role: .cancel) {}
        } message: { workspace in
            Text(workspace.linkedRepoIDs.isEmpty
                 ? "Close this feature and stop its shells."
                 : "Removing worktrees will run `git worktree remove` and `git branch -D \(workspace.name)` in each linked repo. Pick \"Keep Worktrees\" to leave the on-disk worktrees in place.")
        }
        .alert(
            "Couldn't apply change",
            isPresented: Binding(
                get: { addError != nil },
                set: { if !$0 { addError = nil } }
            ),
            presenting: addError
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { error in
            Text(error)
        }
    }

    // MARK: - Run / Signals

    private var runTile: some View {
        VStack(spacing: 4) {
            modeTile(
                mode: .run,
                title: "Run",
                symbol: "play.fill",
                tint: .green,
                hint: "Configure how to start and stop this project"
            )
            modeTile(
                mode: .signals,
                title: "Signals",
                symbol: "waveform.path.ecg",
                tint: .purple,
                hint: "View log streams from running services"
            )
        }
    }

    private func modeTile(
        mode: SidebarMode,
        title: String,
        symbol: String,
        tint: Color,
        hint: String
    ) -> some View {
        Button {
            sidebarMode = mode
        } label: {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(tint.opacity(sidebarMode == mode ? 0.95 : 0.18))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(tint.opacity(sidebarMode == mode ? 0 : 0.28), lineWidth: 1)
                        )
                    Image(systemName: symbol)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(sidebarMode == mode ? Color.white : tint)
                }
                .frame(width: 28, height: 28)

                Text(title)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(sidebarMode == mode ? .primary : .secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(sidebarMode == mode ? Color.primary.opacity(0.10) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(hint)
    }

    // MARK: - Features

    private var featuresSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Work Items / Features")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 2)

            if store.workspaces.isEmpty, repoStore.repositories.isEmpty {
                Text("Add a repository, then create your first feature.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
            } else {
                ForEach(store.workspaces) { workspace in
                    WorkspaceButton(
                        workspace: workspace,
                        isActive: workspace.id == store.activeID && sidebarMode == .workspace,
                        hasUnread: store.hasUnread(for: workspace),
                        lastActivityMessage: store.lastActivityMessage(for: workspace),
                        onSelect: {
                            // Picking a Work Item flips back to the
                            // terminal view, otherwise the activation
                            // would happen silently while the Run page
                            // stayed on screen.
                            sidebarMode = .workspace
                            store.activate(workspace.id)
                        },
                        onClose: { pendingClose = workspace },
                        onRename: { store.setName($0, for: workspace.id) },
                        onPickSymbol: { store.setIcon($0, for: workspace.id) },
                        onPickTint: { store.setTint($0, for: workspace.id) },
                        onMerge: workspace.linkedRepoIDs.isEmpty ? nil : { pendingMerge = workspace }
                    )
                }

                addFeatureRow
            }
        }
    }

    private var addFeatureRow: some View {
        Button {
            showAddFeature = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: isWorking ? "hourglass" : "plus")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(.quaternary)
                    )
                    .foregroundStyle(.secondary)
                Text(isWorking ? "Adding…" : "Add Feature")
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
        .disabled(repoStore.repositories.isEmpty || isWorking)
        .help(repoStore.repositories.isEmpty
              ? "Add a repository before creating features."
              : "New Feature")
    }

    // MARK: - Repositories

    private var repositoriesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            collapsibleHeader(
                "Repositories",
                isExpanded: $repositoriesExpanded,
                addAction: { showAddRepo = true },
                disabled: isWorking
            )

            if repositoriesExpanded {
                if repoStore.repositories.isEmpty {
                    Text("No repositories in this project yet.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)
                } else {
                    ForEach(repoStore.repositories) { repo in
                        RepoRow(
                            repository: repo,
                            onReveal: {
                                NSWorkspace.shared.activateFileViewerSelecting([repo.rootURL])
                            }
                        )
                    }
                }
            }
        }
    }

    // MARK: - Header

    @ViewBuilder
    private func sectionHeader(
        _ title: String,
        addAction: @escaping () -> Void,
        disabled: Bool,
        disabledHint: String? = nil
    ) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
            Button(action: addAction) {
                Image(systemName: isWorking ? "hourglass" : "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 18, height: 18)
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(disabled)
            .help(disabled ? (disabledHint ?? "Working…") : "Add Repository")
        }
        .padding(.bottom, 2)
    }

    /// Section header with a leading disclosure chevron that toggles the
    /// `isExpanded` binding when clicked. The "Add" button stays on the
    /// trailing edge and is independently clickable — it both expands the
    /// section (so the user can see what they just added) and fires the
    /// add action.
    @ViewBuilder
    private func collapsibleHeader(
        _ title: String,
        isExpanded: Binding<Bool>,
        addAction: @escaping () -> Void,
        disabled: Bool,
        disabledHint: String? = nil
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Button {
                withAnimation(.snappy(duration: 0.18)) {
                    isExpanded.wrappedValue.toggle()
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded.wrappedValue ? 90 : 0))
                    Text(title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                if !isExpanded.wrappedValue {
                    withAnimation(.snappy(duration: 0.18)) {
                        isExpanded.wrappedValue = true
                    }
                }
                addAction()
            } label: {
                Image(systemName: isWorking ? "hourglass" : "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 18, height: 18)
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(disabled)
            .help(disabled ? (disabledHint ?? "Working…") : "Add \(title.dropLast())")
        }
        .padding(.bottom, 2)
    }

    // MARK: - Actions

    private func handleCreateFeature(name: String, repoIDs: [String]) {
        showAddFeature = false
        isWorking = true
        let project = repoStore.project
        let selectedRepos = repoStore.repositories.filter { repoIDs.contains($0.name) }
        Task {
            do {
                let dir = try await FeatureProvisioner.provision(
                    featureName: name,
                    in: project,
                    across: selectedRepos
                )
                store.registerFeature(
                    name: name,
                    featureDirectory: dir,
                    linkedRepoIDs: repoIDs
                )
            } catch {
                addError = error.localizedDescription
            }
            isWorking = false
        }
    }

    private func handleAddRepo(_ intent: AddRepoIntent) {
        showAddRepo = false
        isWorking = true
        Task {
            do {
                switch intent {
                case .clone(let url, let name):
                    _ = try await repoStore.clone(url: url, name: name)
                case .initialize(let name):
                    _ = try await repoStore.initRepo(name: name)
                case .importLocal(let path, let name):
                    _ = try await repoStore.importLocal(path: path, name: name)
                }
            } catch {
                addError = error.localizedDescription
            }
            isWorking = false
        }
    }

    private func openConflictTab(workspace: Workspace, url: URL, title: String) {
        // Make sure the workspace is active so the new tab is the visible
        // one, then use its session to open a tab cd'd into the conflict.
        store.activate(workspace.id)
        guard let session = store.session(for: workspace) as WorkspaceSession? else { return }
        session.openTab(at: url.path, title: title)
    }

    private func closeFeature(_ workspace: Workspace, removeWorktrees: Bool) {
        let project = repoStore.project
        let linkedRepos = repoStore.repositories.filter { workspace.linkedRepoIDs.contains($0.name) }
        store.remove(workspace)
        guard removeWorktrees, !linkedRepos.isEmpty else { return }
        Task {
            await FeatureProvisioner.teardown(
                featureName: workspace.name,
                in: project,
                across: linkedRepos
            )
        }
    }
}

// MARK: - Workspace pill

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
    var onMerge: (() -> Void)? = nil

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

                VStack(alignment: .leading, spacing: 2) {
                    Text(workspace.name)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundStyle(isActive ? .primary : .secondary)
                    if !workspace.linkedRepoIDs.isEmpty {
                        repoChips
                    }
                    if let lastActivityMessage, !lastActivityMessage.isEmpty {
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
        .help(workspace.workingDirectory ?? workspace.name)
        .contextMenu {
            Button("Customize…") { isPickerPresented = true }
            if !workspace.linkedRepoIDs.isEmpty, let onMerge {
                Button("Merge…", action: onMerge)
            }
            Divider()
            Button("Close \"\(workspace.name)\"", role: .destructive, action: onClose)
        }
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

    private var repoChips: some View {
        HStack(spacing: 4) {
            ForEach(workspace.linkedRepoIDs.prefix(3), id: \.self) { repo in
                Text(repo)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(
                        Capsule().fill(Color.secondary.opacity(0.15))
                    )
            }
            if workspace.linkedRepoIDs.count > 3 {
                Text("+\(workspace.linkedRepoIDs.count - 3)")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

// MARK: - Repo row (passive, in the Repositories footer)

private struct RepoRow: View {
    let repository: Repository
    let onReveal: () -> Void

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
                Text(repository.name)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(repository.defaultBranch)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isHovered ? Color.primary.opacity(0.04) : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .help(repository.rootURL.path)
        .contextMenu {
            Button("Show in Finder", action: onReveal)
        }
    }
}

// MARK: - Customize sheet

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
        "terminal.fill", "house.fill", "chevron.left.forwardslash.chevron.right",
        "doc.text.magnifyingglass", "circle.grid.3x3.fill", "square.stack.3d.up.fill",
        "globe", "bolt.fill", "leaf.fill", "hammer.fill",
        "wrench.and.screwdriver.fill", "server.rack", "cloud.fill", "cpu.fill",
        "externaldrive.fill", "shippingbox.fill", "graduationcap.fill",
        "briefcase.fill", "paintpalette.fill", "gamecontroller.fill",
        "music.note", "flag.fill", "star.fill", "heart.fill",
    ]

    private static let tints: [Color] = [
        .blue, .purple, .pink, .red, .orange, .yellow, .green, .teal, .indigo, .gray,
    ]

    private let columns = Array(repeating: GridItem(.fixed(36), spacing: 10), count: 6)

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Customize Feature")
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
