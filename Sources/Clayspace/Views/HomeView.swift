import SwiftUI

struct HomeView: View {
    @Bindable var store: ProjectStore
    @Environment(\.openWindow) private var openWindow

    @State private var showCreate = false
    @State private var newProjectName = ""
    @State private var createError: String?

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
                error: createError,
                onCancel: { showCreate = false },
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

                CenteredFlowLayout(spacing: 12, lineSpacing: 12) {
                    ForEach(store.projects) { project in
                        ProjectCard(
                            project: project,
                            onOpen: { openWindow(value: project.id) },
                            onDelete: { pendingDelete = project }
                        )
                        .frame(width: 180)
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
    }

    // MARK: - Actions

    private func showCreateSheet() {
        resetCreateState()
        showCreate = true
    }

    private func resetCreateState() {
        newProjectName = ""
        createError = nil
    }

    private func createProject() {
        do {
            let project = try store.createProject(name: newProjectName)
            showCreate = false
            openWindow(value: project.id)
        } catch {
            createError = error.localizedDescription
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
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(.tint)
                    .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: 2) {
                    Text(project.name)
                        .font(.body.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(project.createdAt, format: .dateTime.year().month(.abbreviated).day())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .frame(height: 110, alignment: .topLeading)
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isHovered ? Color.primary.opacity(0.08) : Color.primary.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.primary.opacity(isHovered ? 0.12 : 0.06), lineWidth: 1)
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

// MARK: - Centered flow layout

/// Wraps subviews left-to-right, then centers each row horizontally.
/// `LazyVGrid`'s adaptive columns always pack into the leading edge,
/// leaving empty trailing columns when items don't fill the row —
/// this layout instead measures each row and centers it.
private struct CenteredFlowLayout: Layout {
    var spacing: CGFloat = 12
    var lineSpacing: CGFloat = 12

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let result = arrangement(in: width, subviews: subviews)
        return CGSize(width: width.isFinite ? width : result.usedWidth, height: result.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrangement(in: bounds.width, subviews: subviews)
        for (index, frame) in result.frames.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: frame.width, height: frame.height)
            )
        }
    }

    private func arrangement(in width: CGFloat, subviews: Subviews) -> (frames: [CGRect], height: CGFloat, usedWidth: CGFloat) {
        guard !subviews.isEmpty else { return ([], 0, 0) }

        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }

        // Greedy pack into rows of indices.
        var rows: [[Int]] = [[]]
        var rowWidth: CGFloat = 0
        for (i, size) in sizes.enumerated() {
            let prefix = rows[rows.count - 1].isEmpty ? 0 : spacing
            if rowWidth + prefix + size.width > width && !rows[rows.count - 1].isEmpty {
                rows.append([])
                rowWidth = 0
            }
            rows[rows.count - 1].append(i)
            let nextPrefix = rows[rows.count - 1].count == 1 ? 0 : spacing
            rowWidth += nextPrefix + size.width
        }

        var frames = [CGRect](repeating: .zero, count: subviews.count)
        var y: CGFloat = 0
        var usedWidth: CGFloat = 0

        for row in rows {
            let contentWidth = row.reduce(0) { $0 + sizes[$1].width } + CGFloat(max(0, row.count - 1)) * spacing
            usedWidth = max(usedWidth, contentWidth)
            let rowHeight = row.map { sizes[$0].height }.max() ?? 0
            var x = max(0, (width - contentWidth) / 2)
            for i in row {
                frames[i] = CGRect(x: x, y: y, width: sizes[i].width, height: sizes[i].height)
                x += sizes[i].width + spacing
            }
            y += rowHeight + lineSpacing
        }

        return (frames, max(0, y - lineSpacing), usedWidth)
    }
}

// MARK: - Create sheet

private struct CreateProjectSheet: View {
    @Binding var name: String
    let error: String?
    let onCancel: () -> Void
    let onCreate: () -> Void

    @FocusState private var isNameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Project")
                .font(.headline)
            Text("A folder will be created under ~/Documents/Clayspace.")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextField("Project name", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($isNameFocused)
                .onSubmit(submit)

            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Create", action: submit)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedName.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear { isNameFocused = true }
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func submit() {
        guard !trimmedName.isEmpty else { return }
        onCreate()
    }
}
