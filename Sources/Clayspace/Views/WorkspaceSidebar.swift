import SwiftUI

struct WorkspaceSidebar: View {
    @Bindable var store: WorkspaceStore

    var body: some View {
        VStack(spacing: 8) {
            ForEach(store.workspaces) { workspace in
                WorkspaceButton(
                    workspace: workspace,
                    isActive: workspace.id == store.activeID,
                    onSelect: { store.activeID = workspace.id },
                    onClose: { store.remove(workspace) }
                )
            }

            Button {
                store.addWorkspace()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 44, height: 44)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(.quaternary)
                    )
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("New Workspace (⌘T)")

            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 12)
    }
}

private struct WorkspaceButton: View {
    let workspace: Workspace
    let isActive: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onSelect) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(workspace.tint.opacity(isActive ? 0.95 : (isHovered ? 0.35 : 0.18)))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(workspace.tint.opacity(isActive ? 0 : 0.3), lineWidth: 1)
                    )
                Image(systemName: workspace.symbol)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(isActive ? Color.white : workspace.tint)
            }
            .frame(width: 44, height: 44)
            .overlay(alignment: .leading) {
                // Active-pill indicator on the left edge.
                Capsule()
                    .fill(.primary)
                    .frame(width: 3, height: isActive ? 24 : 0)
                    .offset(x: -10)
                    .animation(.snappy(duration: 0.18), value: isActive)
            }
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(workspace.name)
        .contextMenu {
            Button("Close \"\(workspace.name)\"", role: .destructive, action: onClose)
        }
    }
}
