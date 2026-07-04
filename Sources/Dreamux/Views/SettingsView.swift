import SwiftUI
import AppKit

/// App-wide appearance settings, persisted in UserDefaults and read live
/// by `ContentView` via the same `@AppStorage` keys.
enum AppearanceSettings {
    static let cardShadowKey = "appearanceCardShadow"
    static let edgeInsetsKey = "appearanceEdgeInsets"
    static let cornerRadiusKey = "appearanceCornerRadius"
    static let glassKey = "appearanceGlassBackdrop"
    static let backdropDimKey = "appearanceBackdropDim"
    static let backdropTintKey = "appearanceBackdropTint"  // hex, "" = black
    static let cardColorKey = "appearanceCardColor"        // hex, "" = system
    static let cardOpacityKey = "appearanceCardOpacity"    // 0.5...1

    /// "#RRGGBB" → Color (sRGB). Empty/garbage → nil.
    static func color(fromHex hex: String) -> Color? {
        var raw = hex.trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else { return nil }
        if raw.hasPrefix("#") { raw.removeFirst() }
        guard raw.count == 6, let value = UInt32(raw, radix: 16) else { return nil }
        return Color(
            .sRGB,
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255,
            opacity: 1
        )
    }

    static func hex(from color: Color) -> String {
        guard let srgb = NSColor(color).usingColorSpace(.sRGB) else { return "" }
        let r = Int(round(srgb.redComponent * 255))
        let g = Int(round(srgb.greenComponent * 255))
        let b = Int(round(srgb.blueComponent * 255))
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}

struct SettingsView: View {
    @AppStorage(AppearanceSettings.cardShadowKey) private var cardShadow = true
    @AppStorage(AppearanceSettings.edgeInsetsKey) private var edgeInsets = true
    @AppStorage(AppearanceSettings.cornerRadiusKey) private var cornerRadius = 16.0
    @AppStorage(AppearanceSettings.glassKey) private var glassBackdrop = true
    @AppStorage(AppearanceSettings.backdropDimKey) private var backdropDim = 0.28
    @AppStorage(AppearanceSettings.backdropTintKey) private var backdropTintHex = ""
    @AppStorage(AppearanceSettings.cardColorKey) private var cardColorHex = ""
    @AppStorage(AppearanceSettings.cardOpacityKey) private var cardOpacity = 1.0

    /// ColorPicker bindings bridged onto the persisted hex strings.
    private func colorBinding(_ hex: Binding<String>, fallback: Color) -> Binding<Color> {
        Binding(
            get: { AppearanceSettings.color(fromHex: hex.wrappedValue) ?? fallback },
            set: { hex.wrappedValue = AppearanceSettings.hex(from: $0) }
        )
    }

    var body: some View {
        Form {
            Section("Inset card") {
                Toggle("Drop shadow", isOn: $cardShadow)
                Picker("Edge padding", selection: $edgeInsets) {
                    Text("Inset — floating card with gutters").tag(true)
                    Text("Flush — content runs to the window edge").tag(false)
                }
                .pickerStyle(.radioGroup)
                LabeledContent("Corner radius") {
                    HStack(spacing: 10) {
                        Slider(value: $cornerRadius, in: 6...26, step: 1)
                            .frame(width: 180)
                        Text("\(Int(cornerRadius)) pt")
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 44, alignment: .trailing)
                    }
                }
            }

            Section {
                Toggle("Glass backdrop (desktop blur)", isOn: $glassBackdrop)
                LabeledContent("Backdrop dimming") {
                    HStack(spacing: 10) {
                        Slider(value: $backdropDim, in: 0...0.9)
                            .frame(width: 180)
                            .disabled(!glassBackdrop)
                        Text("\(Int(backdropDim * 100))%")
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 44, alignment: .trailing)
                    }
                }
                ColorPicker(
                    glassBackdrop ? "Backdrop tint" : "Backdrop color",
                    selection: colorBinding($backdropTintHex, fallback: .black),
                    supportsOpacity: false
                )
                LabeledContent("Card transparency") {
                    HStack(spacing: 10) {
                        Slider(value: $cardOpacity, in: 0.5...1.0)
                            .frame(width: 180)
                        Text("\(Int(cardOpacity * 100))%")
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 44, alignment: .trailing)
                    }
                }
                LabeledContent("Card background") {
                    HStack(spacing: 10) {
                        ColorPicker(
                            "",
                            selection: colorBinding(
                                $cardColorHex,
                                fallback: Color(nsColor: .windowBackgroundColor)),
                            supportsOpacity: false
                        )
                        .labelsHidden()
                        Button("Use system color") { cardColorHex = "" }
                            .disabled(cardColorHex.isEmpty)
                    }
                }
            } header: {
                Text("Colors & transparency")
            } footer: {
                Text("With glass off, the backdrop is the solid backdrop color. Card transparency lets the glass show through the content itself — terminal surfaces pick it up when newly opened. Everything else applies immediately.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 470)
        .fixedSize(horizontal: false, vertical: true)
    }
}
