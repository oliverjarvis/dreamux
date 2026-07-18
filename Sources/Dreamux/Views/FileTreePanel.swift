import SwiftUI
import AppKit

/// The right-side file explorer — the card's third column. Presents
/// the active feature's linked-repo worktrees as one tree — each repo a
/// top-level node — opens files as Monaco tabs, and carries the
/// standard file-manager verbs (context menu), drag-out, and
/// open-in-terminal.
struct FileTreePanel: View {
    @Bindable var store: WorkspaceStore
    @Bindable var repoStore: RepoStore
    let tree: FileTreeStore
    let onOpenFile: (URL) -> Void
    /// Opens a new terminal tab cwd'd at the folder — never types into
    /// an existing session, which may be a busy agent.
    let onOpenTerminal: (URL) -> Void

    /// Bumped by the refresh button and after any mutation to force a
    /// fresh disk read of the (uncached) tree.
    @State private var reloadToken = UUID()
    /// The rename sheet's subject.
    @State private var renaming: FileNode?
    /// The create sheet's target directory and kind.
    @State private var creating: CreateTarget?
    /// A just-created file to open once the create sheet has dismissed
    /// — opening from inside the sheet's confirm action would interleave
    /// tab creation with the dismissal transaction.
    @State private var pendingOpen: URL?
    /// Per-root git status (repo-relative path → change kind) for the
    /// rows' badges; reloaded with the tree.
    @State private var gitStatuses: [URL: [String: GitOperations.FileChangeKind]] = [:]

    private var roots: [FileNode] {
        tree.roots(for: store.activeWorkspace, repositories: repoStore.repositories)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if roots.isEmpty {
                emptyState
            } else {
                // Custom rows, not a List: every row shares one font
                // size, one row height, and the app's standard hover
                // wash — and carries a git badge the sidebar list style
                // couldn't.
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(roots) { root in
                            FileTreeRow(
                                node: root,
                                rootURL: root.url,
                                depth: 0,
                                tree: tree,
                                statuses: gitStatuses[root.url] ?? [:],
                                onOpenFile: onOpenFile,
                                onAction: { handle($0, on: $1, rootURL: root.url) })
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 6)
                }
                .id(reloadToken)
            }
        }
        .task(id: statusReloadKey) {
            var next: [URL: [String: GitOperations.FileChangeKind]] = [:]
            for root in roots {
                next[root.url] = await GitOperations.fileStatuses(in: root.url)
            }
            gitStatuses = next
        }
        .sheet(item: $renaming) { node in
            NameSheet(
                title: "Rename \"\(node.name)\"",
                confirmLabel: "Rename",
                initialName: node.name
            ) { newName in
                try FileTreeOperations.rename(node.url, to: newName)
            } onDone: {
                reloadToken = UUID()
            }
        }
        .sheet(item: $creating) { target in
            NameSheet(
                title: target.isDirectory
                    ? "New folder in \(target.directory.lastPathComponent)"
                    : "New file in \(target.directory.lastPathComponent)",
                confirmLabel: "Create",
                initialName: ""
            ) { name in
                if target.isDirectory {
                    try FileTreeOperations.createFolder(named: name, in: target.directory)
                } else {
                    pendingOpen = try FileTreeOperations.createFile(named: name, in: target.directory)
                }
            } onDone: {
                reloadToken = UUID()
                if let url = pendingOpen {
                    pendingOpen = nil
                    onOpenFile(url)
                }
            }
        }
    }

    /// Reload git badges whenever the tree reloads or the root set
    /// changes worktrees.
    private var statusReloadKey: String {
        reloadToken.uuidString + roots.map(\.url.path).joined(separator: "|")
    }

    private func handle(_ action: FileTreeAction, on node: FileNode, rootURL: URL) {
        switch action {
        case .open:
            onOpenFile(node.url)
        case .revealInFinder:
            NSWorkspace.shared.activateFileViewerSelecting([node.url])
        case .copyPath:
            copyToPasteboard(node.url.path)
        case .copyRelativePath:
            copyToPasteboard(FileTreeOperations.relativePath(of: node.url, under: rootURL))
        case .newFile:
            creating = CreateTarget(directory: containerDirectory(for: node), isDirectory: false)
        case .newFolder:
            creating = CreateTarget(directory: containerDirectory(for: node), isDirectory: true)
        case .rename:
            renaming = node
        case .trash:
            do {
                try FileTreeOperations.trash(node.url)
                reloadToken = UUID()
            } catch {
                NSSound.beep()
            }
        case .openInTerminal:
            onOpenTerminal(node.url)
        }
    }

    private func copyToPasteboard(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }

    /// New File/Folder on a folder creates inside it; on a file row it
    /// creates a sibling (the file's parent directory).
    private func containerDirectory(for node: FileNode) -> URL {
        node.isDirectory ? node.url : node.url.deletingLastPathComponent()
    }

    /// Compact — the card's context header above already names the
    /// worktree/commit this tree belongs to; this strip just labels the
    /// column and hosts refresh.
    private var header: some View {
        HStack {
            Text("Files")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.primary)
            Spacer()
            Button { reloadToken = UUID() } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Refresh")
        }
        .padding(.horizontal, 12)
        // Bonsplit's TabBarMetrics.barHeight (40) — the Files strip sits
        // next to the tab bar and their bottom hairlines must align. The
        // hairline rides INSIDE the 40 (an overlay, not a stacked
        // Divider) for the same reason: stacked, it lands at 40..41 and
        // reads one pixel lower than the tab bar's.
        .frame(height: 40)
        .overlay(alignment: .bottom) { Divider() }
    }

    @ViewBuilder
    private var emptyState: some View {
        Text(store.activeWorkspace == nil
             ? "No feature selected."
             : "This feature spans no repositories.")
            .font(.caption)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
    }
}

/// The verbs a row can ask the panel to perform. The panel owns the
/// sheets/pasteboard/terminal plumbing; rows just name the action.
enum FileTreeAction {
    case open, revealInFinder, copyPath, copyRelativePath
    case newFile, newFolder, rename, trash, openInTerminal
}

/// Sheet target for New File / New Folder.
private struct CreateTarget: Identifiable {
    let directory: URL
    let isDirectory: Bool
    var id: String { "\(directory.path)|\(isDirectory)" }
}

/// One row in the tree. Every row — repo root, folder, file — shares one
/// 14pt label, one row height, and the app's standard hover wash;
/// folders expand in place (children read from disk only while
/// expanded), files open an editor tab. A trailing badge carries the
/// row's git state: a status letter for files, a dot for containers
/// with changed descendants. Every row drags as its file URL and
/// carries the file-manager context menu.
private struct FileTreeRow: View {
    let node: FileNode
    /// The repo worktree root this row lives under (Copy Relative Path's
    /// base and the key into `statuses`). Repo roots pass their own url
    /// down.
    let rootURL: URL
    let depth: Int
    let tree: FileTreeStore
    /// Repo-relative path → change kind for this row's worktree.
    let statuses: [String: GitOperations.FileChangeKind]
    let onOpenFile: (URL) -> Void
    let onAction: (FileTreeAction, FileNode) -> Void
    @State private var expanded: Bool
    @State private var isHovered = false

    init(
        node: FileNode,
        rootURL: URL,
        depth: Int,
        tree: FileTreeStore,
        statuses: [String: GitOperations.FileChangeKind],
        onOpenFile: @escaping (URL) -> Void,
        onAction: @escaping (FileTreeAction, FileNode) -> Void
    ) {
        self.node = node
        self.rootURL = rootURL
        self.depth = depth
        self.tree = tree
        self.statuses = statuses
        self.onOpenFile = onOpenFile
        self.onAction = onAction
        _expanded = State(initialValue: node.isRepoRoot)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            row
            if node.isDirectory, expanded {
                ForEach(tree.children(of: node)) { child in
                    FileTreeRow(
                        node: child,
                        rootURL: rootURL,
                        depth: depth + 1,
                        tree: tree,
                        statuses: statuses,
                        onOpenFile: onOpenFile,
                        onAction: onAction)
                }
            }
        }
    }

    private var row: some View {
        Button {
            if node.isDirectory {
                withAnimation(.snappy(duration: 0.18)) { expanded.toggle() }
            } else {
                onOpenFile(node.url)
            }
        } label: {
            HStack(spacing: 7) {
                Group {
                    if node.isDirectory {
                        PhosphorIcon.caretRightFill
                            .renderingMode(.template)
                            .scaledToFit()
                            .frame(width: 9, height: 9)
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                    } else {
                        Color.clear
                    }
                }
                .frame(width: 12, height: 12)

                Image(systemName: iconName)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)

                Text(node.name)
                    .font(.system(size: 14, weight: node.isRepoRoot ? .medium : .regular))
                    .foregroundStyle(nameColor)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 4)

                statusBadge
            }
            .padding(.leading, CGFloat(depth) * 14 + 6)
            .padding(.trailing, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background {
            if isHovered {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
            }
        }
        .onHover { isHovered = $0 }
        .onDrag { NSItemProvider(object: node.url as NSURL) }
        .contextMenu { menu }
    }

    private var iconName: String {
        if node.isRepoRoot { return "shippingbox.fill" }
        return node.isDirectory ? "folder.fill" : "doc.text"
    }

    /// This row's path relative to its worktree root — the key shape
    /// `git status --porcelain` reports.
    private var relativePath: String {
        FileTreeOperations.relativePath(of: node.url, under: rootURL)
    }

    private var fileChange: GitOperations.FileChangeKind? {
        node.isDirectory ? nil : statuses[relativePath]
    }

    /// A folder "contains changes" when any porcelain path lives under
    /// it; the repo root rolls up the whole worktree.
    private var containsChanges: Bool {
        guard node.isDirectory else { return false }
        if node.isRepoRoot { return !statuses.isEmpty }
        let prefix = relativePath + "/"
        return statuses.keys.contains { $0.hasPrefix(prefix) }
    }

    private var nameColor: Color {
        if let fileChange { return fileChange.tint }
        return .primary
    }

    @ViewBuilder
    private var statusBadge: some View {
        if let fileChange {
            Text(fileChange.letter)
                .font(.system(size: 11, weight: .semibold).monospaced())
                .foregroundStyle(fileChange.tint)
        } else if containsChanges {
            Circle()
                .fill(Color.orange.opacity(0.75))
                .frame(width: 6, height: 6)
        }
    }

    /// Files: Open · Reveal · Copy paths · New (sibling) · Rename ·
    /// Trash. Folders: the same minus Open, New targets the folder
    /// itself, plus Open in Terminal. Repo roots can't be renamed or
    /// trashed — they're worktrees, not tree content.
    @ViewBuilder
    private var menu: some View {
        if !node.isDirectory {
            Button("Open") { onAction(.open, node) }
            Divider()
        }
        Button("Reveal in Finder") { onAction(.revealInFinder, node) }
        Button("Copy Path") { onAction(.copyPath, node) }
        Button("Copy Relative Path") { onAction(.copyRelativePath, node) }
        Divider()
        Button("New File…") { onAction(.newFile, node) }
        Button("New Folder…") { onAction(.newFolder, node) }
        if node.isDirectory {
            Button("Open in Terminal") { onAction(.openInTerminal, node) }
        }
        if !node.isRepoRoot {
            Divider()
            Button("Rename…") { onAction(.rename, node) }
            Button("Move to Trash", role: .destructive) { onAction(.trash, node) }
        }
    }
}

/// VS Code's badge language: a letter per change kind, tinted.
private extension GitOperations.FileChangeKind {
    var letter: String {
        switch self {
        case .modified: return "M"
        case .added: return "A"
        case .untracked: return "U"
        case .deleted: return "D"
        case .renamed: return "R"
        case .conflicted: return "!"
        }
    }

    var tint: Color {
        switch self {
        case .modified, .renamed: return .orange
        case .added, .untracked: return .green
        case .deleted, .conflicted: return .red
        }
    }
}

/// Shared one-field sheet for Rename / New File / New Folder. Runs the
/// throwing operation on Confirm; a FileTreeOperationError renders
/// inline and keeps the sheet open for correction.
private struct NameSheet: View {
    let title: String
    let confirmLabel: String
    let initialName: String
    let perform: (String) throws -> Void
    let onDone: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String = ""
    @State private var errorText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(confirm)
            if let errorText {
                Text(errorText)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(confirmLabel, action: confirm)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.isEmpty)
            }
        }
        .padding(16)
        .frame(width: 320)
        .onAppear { name = initialName }
    }

    private func confirm() {
        do {
            try perform(name)
            dismiss()
            onDone()
        } catch {
            errorText = error.localizedDescription
        }
    }
}
