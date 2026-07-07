import SwiftUI

/// Icon + color picker for a project's rail glyph. Selection is tracked
/// locally so the preview and highlight update live; each pick also fires
/// its callback so the store persists immediately. A nil symbol falls
/// back to the initial-letter glyph; a nil tint falls back to the stable
/// name-derived color — both reachable via the leading "Auto" cell in
/// each row.
struct CustomizeProjectSheet: View {
    let projectName: String
    let selectedSymbol: String?
    let selectedTintHex: String?
    let onPickSymbol: (String?) -> Void
    let onPickTintHex: (String?) -> Void
    let onDismiss: () -> Void

    @State private var symbol: String?
    @State private var tintHex: String?

    init(
        projectName: String,
        selectedSymbol: String?,
        selectedTintHex: String?,
        onPickSymbol: @escaping (String?) -> Void,
        onPickTintHex: @escaping (String?) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.projectName = projectName
        self.selectedSymbol = selectedSymbol
        self.selectedTintHex = selectedTintHex
        self.onPickSymbol = onPickSymbol
        self.onPickTintHex = onPickTintHex
        self.onDismiss = onDismiss
        _symbol = State(initialValue: selectedSymbol)
        _tintHex = State(initialValue: selectedTintHex)
    }

    /// Filled-first SF Symbols — the user asked for filled glyphs where a
    /// filled variant exists.
    private static let symbols: [String] = [
        "folder.fill", "hammer.fill", "wrench.and.screwdriver.fill",
        "chevron.left.forwardslash.chevron.right", "terminal.fill",
        "cube.fill", "shippingbox.fill", "square.stack.3d.up.fill",
        "cpu.fill", "server.rack", "cloud.fill", "globe",
        "bolt.fill", "sparkles", "wand.and.stars", "flask.fill",
        "gamecontroller.fill", "paintpalette.fill", "camera.fill",
        "music.note", "book.fill", "graduationcap.fill", "briefcase.fill",
        "cart.fill", "creditcard.fill", "chart.bar.fill", "map.fill",
        "leaf.fill", "flame.fill", "star.fill", "heart.fill", "flag.fill",
    ]

    private static let tints: [Color] = [
        .blue, .purple, .pink, .red, .orange, .yellow,
        .green, .mint, .teal, .cyan, .indigo, .gray,
    ]

    private let columns = Array(repeating: GridItem(.fixed(38), spacing: 10), count: 6)

    /// The tint the preview should show for the current selection.
    private var previewTint: Color {
        if let tintHex, let color = AppearanceSettings.color(fromHex: tintHex) {
            return color
        }
        return ProjectGlyph.derivedTint(for: projectName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                ProjectGlyph(name: projectName, size: 52,
                             symbol: symbol, tint: previewTint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Customize Project")
                        .font(.title3.weight(.semibold))
                    Text(projectName)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Icon")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                LazyVGrid(columns: columns, spacing: 10) {
                    letterCell
                    ForEach(Self.symbols, id: \.self) { name in
                        iconCell(name)
                    }
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Color")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    autoTintCell
                    ForEach(Self.tints, id: \.self) { tint in
                        tintCell(tint)
                    }
                }
            }

            HStack {
                Spacer()
                Button("Done", action: onDismiss)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    // MARK: - Icon cells

    /// The "initial letter" default — clears the custom symbol.
    private var letterCell: some View {
        Button {
            symbol = nil
            onPickSymbol(nil)
        } label: {
            Text(String(projectName.prefix(1)).uppercased())
                .font(.system(size: 16, weight: .heavy, design: .rounded))
                .frame(width: 38, height: 38)
                .background(cellBackground(isSelected: symbol == nil))
                .foregroundStyle(symbol == nil ? Color.white : .primary)
        }
        .buttonStyle(.plain)
        .help("Use the project's initial")
    }

    private func iconCell(_ name: String) -> some View {
        let isSelected = symbol == name
        return Button {
            symbol = name
            onPickSymbol(name)
        } label: {
            Image(systemName: name)
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 38, height: 38)
                .background(cellBackground(isSelected: isSelected))
                .foregroundStyle(isSelected ? Color.white : .primary)
        }
        .buttonStyle(.plain)
    }

    private func cellBackground(isSelected: Bool) -> some View {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(isSelected ? previewTint : Color.secondary.opacity(0.12))
    }

    // MARK: - Tint cells

    /// The "auto" default — clears the custom tint, restoring the stable
    /// name-derived color.
    private var autoTintCell: some View {
        Button {
            tintHex = nil
            onPickTintHex(nil)
        } label: {
            ZStack {
                Circle()
                    .fill(AngularGradient(
                        colors: [.red, .orange, .yellow, .green, .blue, .purple, .red],
                        center: .center))
                Image(systemName: "sparkles")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: 26, height: 26)
            .overlay(
                Circle().strokeBorder(
                    Color.primary.opacity(tintHex == nil ? 0.9 : 0), lineWidth: 2))
        }
        .buttonStyle(.plain)
        .help("Auto color (from the project name)")
    }

    private func tintCell(_ tint: Color) -> some View {
        let hex = AppearanceSettings.hex(from: tint)
        let isSelected = tintHex?.caseInsensitiveCompare(hex) == .orderedSame
        return Button {
            tintHex = hex
            onPickTintHex(hex)
        } label: {
            Circle()
                .fill(tint)
                .frame(width: 26, height: 26)
                .overlay(
                    Circle().strokeBorder(
                        Color.primary.opacity(isSelected ? 0.9 : 0), lineWidth: 2))
        }
        .buttonStyle(.plain)
    }
}
