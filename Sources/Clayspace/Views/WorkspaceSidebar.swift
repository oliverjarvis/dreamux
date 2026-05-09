import SwiftUI

struct WorkspaceSidebar: View {
    @Bindable var store: WorkspaceStore

    var body: some View {
        VStack(spacing: 8) {
            Text("Work Items")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 4)

            ForEach(store.workspaces) { workspace in
                WorkspaceButton(
                    workspace: workspace,
                    isActive: workspace.id == store.activeID,
                    hasUnread: store.hasUnread(for: workspace),
                    onSelect: { store.activeID = workspace.id },
                    onClose: { store.remove(workspace) },
                    onRename: { store.setName($0, for: workspace.id) },
                    onPickSymbol: { store.setIcon($0, for: workspace.id) },
                    onPickTint: { store.setTint($0, for: workspace.id) }
                )
            }

            Button {
                store.addWorkspace()
            } label: {
                VStack(spacing: 4) {
                    Image(systemName: "plus")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(width: 44, height: 44)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(.quaternary)
                        )
                        .foregroundStyle(.secondary)
                    // Reserve the same caption-line space the named tiles
                    // use, so the +-button's icon aligns vertically with
                    // them instead of bouncing up.
                    Color.clear.frame(height: 12)
                }
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
    let hasUnread: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    let onRename: (String) -> Void
    let onPickSymbol: (String) -> Void
    let onPickTint: (Color) -> Void

    @State private var isHovered = false
    @State private var isPickerPresented = false

    var body: some View {
        Button(action: onSelect) {
            VStack(spacing: 4) {
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
                .overlay(alignment: .topTrailing) {
                    // Attention badge — drawn outside the rounded square
                    // so it notches the corner. Hidden when no unread.
                    Circle()
                        .fill(Color.red)
                        .frame(width: 10, height: 10)
                        .overlay(
                            Circle()
                                .strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5)
                        )
                        .offset(x: 4, y: -4)
                        .opacity(hasUnread ? 1 : 0)
                        .animation(.snappy(duration: 0.18), value: hasUnread)
                        .accessibilityHidden(true)
                }
                .overlay(alignment: .leading) {
                    // Active-pill indicator on the left edge.
                    Capsule()
                        .fill(.primary)
                        .frame(width: 3, height: isActive ? 24 : 0)
                        .offset(x: -10)
                        .animation(.snappy(duration: 0.18), value: isActive)
                }

                Text(workspace.name)
                    .font(.caption2.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(isActive ? .primary : .secondary)
                    .frame(maxWidth: .infinity)
            }
            .frame(maxWidth: .infinity)
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
