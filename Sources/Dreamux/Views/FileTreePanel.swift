import SwiftUI

/// The right-side file explorer (a native `.inspector` panel). Presents
/// the active feature's linked-repo worktrees as one tree — each repo a
/// top-level node — and opens a file as a Monaco editor tab on click.
struct FileTreePanel: View {
    @Bindable var store: WorkspaceStore
    @Bindable var repoStore: RepoStore
    let tree: FileTreeStore
    let onOpenFile: (URL) -> Void

    /// Bumped by the refresh button to force a fresh disk read of the
    /// (uncached) tree.
    @State private var reloadToken = UUID()

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
                        FileTreeRow(node: root, tree: tree, onOpenFile: onOpenFile)
                    }
                }
                .listStyle(.sidebar)
                .id(reloadToken)
            }
        }
    }

    private var header: some View {
        HStack {
            Text(store.activeWorkspace?.name ?? "Files")
                .font(.system(size: 12, weight: .semibold))
                .kerning(0.6)
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            Button { reloadToken = UUID() } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Refresh")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
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

/// One row in the tree. Directories are lazy `DisclosureGroup`s (children
/// read from disk only while expanded); files are buttons that open an
/// editor tab. Repo roots default to expanded.
private struct FileTreeRow: View {
    let node: FileNode
    let tree: FileTreeStore
    let onOpenFile: (URL) -> Void
    @State private var expanded: Bool

    init(node: FileNode, tree: FileTreeStore, onOpenFile: @escaping (URL) -> Void) {
        self.node = node
        self.tree = tree
        self.onOpenFile = onOpenFile
        _expanded = State(initialValue: node.isRepoRoot)
    }

    var body: some View {
        if node.isDirectory {
            DisclosureGroup(isExpanded: $expanded) {
                if expanded {
                    ForEach(tree.children(of: node)) { child in
                        FileTreeRow(node: child, tree: tree, onOpenFile: onOpenFile)
                    }
                }
            } label: {
                Label(node.name, systemImage: node.isRepoRoot ? "shippingbox.fill" : "folder.fill")
                    .font(.callout)
                    .lineLimit(1)
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
        }
    }
}
