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

    private var roots: [FileNode] {
        tree.roots(for: store.activeWorkspace, repositories: repoStore.repositories)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if roots.isEmpty {
                emptyState
            } else {
                List {
                    ForEach(roots) { root in
                        FileTreeRow(
                            node: root,
                            rootURL: root.url,
                            tree: tree,
                            onOpenFile: onOpenFile,
                            onAction: { handle($0, on: $1, rootURL: root.url) })
                    }
                }
                .listStyle(.sidebar)
                // No material of its own — the tree lives inside the
                // card and shares its fill/transparency.
                .scrollContentBackground(.hidden)
                .id(reloadToken)
            }
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
                .font(.system(size: 11, weight: .semibold))
                .kerning(0.6)
                .textCase(.uppercase)
                .foregroundStyle(.tertiary)
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
        // Bonsplit's TabBarMetrics.barHeight — the FILES strip sits next
        // to the tab bar and their bottom hairlines must align.
        .frame(height: 33)
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

/// One row in the tree. Directories are lazy `DisclosureGroup`s (children
/// read from disk only while expanded); files are buttons that open an
/// editor tab. Repo roots default to expanded. Every row drags as its
/// file URL and carries the file-manager context menu.
private struct FileTreeRow: View {
    let node: FileNode
    /// The repo worktree root this row lives under (Copy Relative Path's
    /// base). Repo roots pass their own url down.
    let rootURL: URL
    let tree: FileTreeStore
    let onOpenFile: (URL) -> Void
    let onAction: (FileTreeAction, FileNode) -> Void
    @State private var expanded: Bool

    init(
        node: FileNode,
        rootURL: URL,
        tree: FileTreeStore,
        onOpenFile: @escaping (URL) -> Void,
        onAction: @escaping (FileTreeAction, FileNode) -> Void
    ) {
        self.node = node
        self.rootURL = rootURL
        self.tree = tree
        self.onOpenFile = onOpenFile
        self.onAction = onAction
        _expanded = State(initialValue: node.isRepoRoot)
    }

    var body: some View {
        if node.isDirectory {
            DisclosureGroup(isExpanded: $expanded) {
                if expanded {
                    ForEach(tree.children(of: node)) { child in
                        FileTreeRow(
                            node: child,
                            rootURL: rootURL,
                            tree: tree,
                            onOpenFile: onOpenFile,
                            onAction: onAction)
                    }
                }
            } label: {
                Label(node.name, systemImage: node.isRepoRoot ? "shippingbox.fill" : "folder.fill")
                    .font(.callout)
                    .lineLimit(1)
                    .contentShape(Rectangle())
                    .onDrag { NSItemProvider(contentsOf: node.url) ?? NSItemProvider() }
                    .contextMenu { menu }
            }
        } else {
            Button { onOpenFile(node.url) } label: {
                Label(node.name, systemImage: "doc.text")
                    .font(.callout)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onDrag { NSItemProvider(contentsOf: node.url) ?? NSItemProvider() }
            .contextMenu { menu }
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
