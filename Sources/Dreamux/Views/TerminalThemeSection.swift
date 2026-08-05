import SwiftUI
import AppKit
import GhosttyTheme

/// Settings › Appearance › Terminal. Edits the app-wide
/// `TerminalThemeStore`; every open terminal restyles behind it.
struct TerminalThemeSection: View {
    /// Defaults to the app's current appearance — you almost always want
    /// to edit the variant you can see.
    @Environment(\.colorScheme) private var colorScheme
    @State private var variant: TerminalAppearanceVariant?
    @State private var isPresetPickerShown = false

    private var store: TerminalThemeStore { TerminalThemeStore.shared }

    private var editing: TerminalAppearanceVariant {
        variant ?? (colorScheme == .dark ? .dark : .light)
    }

    var body: some View {
        Section {
            TerminalThemePreview(spec: store.spec, variant: editing)
            variantPicker
            coreColorRows
            paletteGroup
            fontRow
            fontSizeRow
            cursorRow
            if let issue = store.lastIssue {
                Label(issue, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
            }
            advancedConfRow
            Button("Revert to Ghostty defaults") {
                var spec = store.spec
                spec[editing] = .seed
                store.update(spec)
            }
        } header: {
            Text("Terminal")
        } footer: {
            Text("Colors, font and cursor apply to terminals that are already open. Anything the editor does not expose goes in the advanced ghostty config, which is applied below these settings — if ghostty rejects it, Dreamux drops that file and keeps your theme.")
                .foregroundStyle(.secondary)
        }
    }

    private var variantPicker: some View {
        LabeledContent("Editing") {
            HStack(spacing: 14) {
                Picker("", selection: Binding(
                    get: { editing },
                    set: { variant = $0 }
                )) {
                    ForEach(TerminalAppearanceVariant.allCases, id: \.self) { option in
                        Text(option.label).tag(option)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 160)
                Button("Start from…") { isPresetPickerShown = true }
                    .popover(isPresented: $isPresetPickerShown, arrowEdge: .bottom) {
                        TerminalThemePresetPicker { definition in
                            var spec = store.spec
                            // Seeds ONLY the variant being edited, so
                            // Catppuccin Latte can pair with Mocha.
                            spec[editing] = TerminalThemePresets.colorSpec(from: definition)
                            store.update(spec)
                            isPresetPickerShown = false
                        }
                    }
            }
        }
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

    /// ANSI color names, in ghostty's palette order. Shown as tooltips —
    /// swatches only, because sixteen hex labels do not fit.
    private static let paletteNames = [
        "Black", "Red", "Green", "Yellow",
        "Blue", "Magenta", "Cyan", "White",
        "Bright black", "Bright red", "Bright green", "Bright yellow",
        "Bright blue", "Bright magenta", "Bright cyan", "Bright white",
    ]

    @ViewBuilder private var paletteGroup: some View {
        DisclosureGroup("ANSI palette") {
            VStack(alignment: .leading, spacing: 10) {
                paletteRow(range: 0..<8, caption: "Normal")
                paletteRow(range: 8..<16, caption: "Bright")
            }
            .padding(.vertical, 4)
        }
    }

    private func paletteRow(range: Range<Int>, caption: String) -> some View {
        HStack(spacing: 10) {
            Text(caption)
                .foregroundStyle(.secondary)
                .frame(width: 56, alignment: .leading)
            ForEach(range, id: \.self) { index in
                ColorPicker("", selection: Binding(
                    get: {
                        AppearanceSettings.color(fromHex: store.spec[editing].palette[index])
                            ?? .black
                    },
                    set: { newValue in
                        var spec = store.spec
                        spec[editing].palette[index] = AppearanceSettings.hex(from: newValue)
                        store.update(spec)
                    }
                ), supportsOpacity: false)
                .labelsHidden()
                .help("\(index) — \(Self.paletteNames[index])")
            }
        }
    }

    /// Installed fixed-pitch families. Computed once — walking every
    /// installed family and instantiating a font is not cheap enough to
    /// repeat per body evaluation.
    private static let fixedPitchFamilies: [String] = {
        NSFontManager.shared.availableFontFamilies
            .filter { NSFont(name: $0, size: 12)?.isFixedPitch == true }
            .sorted()
    }()

    private var fontRow: some View {
        Picker("Font", selection: Binding(
            get: { store.spec.fontFamily ?? "" },
            set: { newValue in
                var spec = store.spec
                spec.fontFamily = newValue.isEmpty ? nil : newValue
                store.update(spec)
            }
        )) {
            // Emits no font-family key at all, so ghostty picks its own.
            Text("Ghostty default").tag("")
            Divider()
            ForEach(Self.fixedPitchFamilies, id: \.self) { family in
                Text(family).tag(family)
            }
        }
    }

    private var fontSizeRow: some View {
        LabeledContent("Size") {
            HStack(spacing: 10) {
                Slider(
                    value: Binding(
                        get: { store.spec.fontSize },
                        set: { newValue in
                            var spec = store.spec
                            spec.fontSize = newValue
                            store.update(spec)
                        }
                    ),
                    in: TerminalThemeSpec.fontSizeRange,
                    step: 0.5
                )
                .frame(width: 180)
                Text("\(store.spec.fontSize.formatted(.number.precision(.fractionLength(0...1)))) pt")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 60, alignment: .trailing)
            }
        }
    }

    private var cursorRow: some View {
        LabeledContent("Cursor") {
            HStack(spacing: 14) {
                Picker("", selection: Binding(
                    get: { store.spec.cursorStyle },
                    set: { newValue in
                        var spec = store.spec
                        spec.cursorStyle = newValue
                        store.update(spec)
                    }
                )) {
                    ForEach(TerminalCursorStyleSpec.allCases, id: \.self) { style in
                        Text(style.label).tag(style)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 240)
                Toggle("Blink", isOn: Binding(
                    get: { store.spec.cursorBlink },
                    set: { newValue in
                        var spec = store.spec
                        spec.cursorBlink = newValue
                        store.update(spec)
                    }
                ))
            }
        }
    }

    private var advancedConfRow: some View {
        LabeledContent("Advanced ghostty config") {
            HStack(spacing: 10) {
                Button("Create") {
                    try? store.createAdvancedConf()
                    NSWorkspace.shared.activateFileViewerSelecting([store.advancedConfURL])
                }
                .disabled(store.advancedConfExists)
                Button("Reveal") {
                    NSWorkspace.shared.activateFileViewerSelecting([store.advancedConfURL])
                }
                .disabled(!store.advancedConfExists)
                Button("Reload") { store.reloadAdvancedConf() }
                    .disabled(!store.advancedConfExists)
            }
        }
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

/// Search over all 485 bundled ghostty themes. Seeds one variant.
private struct TerminalThemePresetPicker: View {
    let onPick: (GhosttyThemeDefinition) -> Void
    @State private var query = ""

    private var results: [GhosttyThemeDefinition] {
        TerminalThemePresets.search(query)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Search themes", text: $query)
                .textFieldStyle(.roundedBorder)
            List(results) { definition in
                Button {
                    onPick(definition)
                } label: {
                    HStack(spacing: 10) {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(AppearanceSettings.color(
                                fromHex: definition.background) ?? .black)
                            .frame(width: 22, height: 22)
                            .overlay {
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .strokeBorder(Color.secondary.opacity(0.3))
                            }
                        Text(definition.name)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .listStyle(.plain)
        }
        .padding(12)
        .frame(width: 320, height: 380)
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
