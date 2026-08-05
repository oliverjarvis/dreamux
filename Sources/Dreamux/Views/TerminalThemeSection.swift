import SwiftUI
import AppKit

/// Settings › Appearance › Terminal. Edits the app-wide
/// `TerminalThemeStore`; every open terminal restyles behind it.
struct TerminalThemeSection: View {
    /// Defaults to the app's current appearance — you almost always want
    /// to edit the variant you can see.
    @Environment(\.colorScheme) private var colorScheme
    @State private var variant: TerminalAppearanceVariant?

    private var store: TerminalThemeStore { TerminalThemeStore.shared }

    private var editing: TerminalAppearanceVariant {
        variant ?? (colorScheme == .dark ? .dark : .light)
    }

    var body: some View {
        Section {
            TerminalThemePreview(spec: store.spec, variant: editing)
            variantPicker
            coreColorRows
            Button("Revert to Ghostty defaults") {
                var spec = store.spec
                spec[editing] = .seed
                store.update(spec)
            }
        } header: {
            Text("Terminal")
        }
    }

    private var variantPicker: some View {
        Picker("Editing", selection: Binding(
            get: { editing },
            set: { variant = $0 }
        )) {
            ForEach(TerminalAppearanceVariant.allCases, id: \.self) { option in
                Text(option.label).tag(option)
            }
        }
        .pickerStyle(.segmented)
    }

    @ViewBuilder private var coreColorRows: some View {
        requiredColorRow("Background", \.background)
        requiredColorRow("Foreground", \.foreground)
        optionalColorRow("Cursor", \.cursorColor, automaticSource: \.foreground)
        optionalColorRow("Cursor text", \.cursorText, automaticSource: \.background)
        optionalColorRow("Selection", \.selectionBackground, automaticSource: \.foreground)
        optionalColorRow("Selection text", \.selectionForeground, automaticSource: \.background)
        optionalColorRow("Bold", \.boldColor, automaticSource: \.foreground)
    }

    // MARK: - Rows

    private func requiredColorRow(
        _ label: String,
        _ keyPath: WritableKeyPath<TerminalColorSpec, String>
    ) -> some View {
        LabeledContent(label) {
            HStack(spacing: 10) {
                ColorPicker("", selection: Binding(
                    get: {
                        AppearanceSettings.color(fromHex: store.spec[editing][keyPath: keyPath])
                            ?? .black
                    },
                    set: { newValue in
                        var spec = store.spec
                        spec[editing][keyPath: keyPath] = AppearanceSettings.hex(from: newValue)
                        store.update(spec)
                    }
                ), supportsOpacity: false)
                .labelsHidden()
                Text(store.spec[editing][keyPath: keyPath])
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .frame(width: 76, alignment: .leading)
            }
        }
    }

    /// A color ghostty has no default for. Automatic (nil) omits the key
    /// and lets ghostty derive it from fg/bg — which is what terminals
    /// have always done here, so it must stay reachable.
    private func optionalColorRow(
        _ label: String,
        _ keyPath: WritableKeyPath<TerminalColorSpec, String?>,
        automaticSource: KeyPath<TerminalColorSpec, String>
    ) -> some View {
        let current = store.spec[editing][keyPath: keyPath]
        return LabeledContent(label) {
            HStack(spacing: 10) {
                ColorPicker("", selection: Binding(
                    get: {
                        let hex = current ?? store.spec[editing][keyPath: automaticSource]
                        return AppearanceSettings.color(fromHex: hex) ?? .black
                    },
                    set: { newValue in
                        var spec = store.spec
                        spec[editing][keyPath: keyPath] = AppearanceSettings.hex(from: newValue)
                        store.update(spec)
                    }
                ), supportsOpacity: false)
                .labelsHidden()
                Text(current ?? "Automatic")
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .frame(width: 76, alignment: .leading)
                Button("Automatic") {
                    var spec = store.spec
                    spec[editing][keyPath: keyPath] = nil
                    store.update(spec)
                }
                .disabled(current == nil)
            }
        }
    }
}

/// Plain SwiftUI text drawn with the spec's colors — not a ghostty
/// surface. It exists because the Settings window is usually covering
/// the terminal being themed.
private struct TerminalThemePreview: View {
    let spec: TerminalThemeSpec
    let variant: TerminalAppearanceVariant

    private var colors: TerminalColorSpec { spec[variant] }

    private func color(_ hex: String) -> Color {
        AppearanceSettings.color(fromHex: hex) ?? .primary
    }

    private var previewFont: Font {
        if let family = spec.fontFamily {
            return .custom(family, size: spec.fontSize)
        }
        return .system(size: spec.fontSize, design: .monospaced)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 0) {
                Text("~/dev/dreamux ").foregroundStyle(color(colors.palette[4]))
                Text("$ ").foregroundStyle(color(colors.palette[2]))
                Text("ls --color").foregroundStyle(color(colors.foreground))
            }
            HStack(spacing: 0) {
                Text("Sources/  Tests/  docs/  ").foregroundStyle(color(colors.palette[6]))
                Text("README.md").foregroundStyle(color(colors.foreground))
            }
            HStack(spacing: 12) {
                Text("214 passed").foregroundStyle(color(colors.palette[2]))
                Text("3 failed").foregroundStyle(color(colors.palette[1]))
                Text("selected text")
                    .foregroundStyle(color(
                        colors.selectionForeground ?? colors.background))
                    .padding(.horizontal, 3)
                    .background(color(colors.selectionBackground ?? colors.foreground))
            }
        }
        .font(previewFont)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(color(colors.background))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.3))
        }
    }
}
