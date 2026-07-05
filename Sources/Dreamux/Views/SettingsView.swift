import SwiftUI
import AppKit

/// App-wide appearance settings, persisted in UserDefaults and read live
/// by `ContentView` via the same `@AppStorage` keys.
enum AppearanceSettings {
    static let cardShadowKey = "appearanceCardShadow"
    static let edgeInsetsKey = "appearanceEdgeInsets"
    static let cornerRadiusKey = "appearanceCornerRadius"
    /// 1 = raw desktop glass, 0 = solid backdrop color.
    static let backdropTransparencyKey = "appearanceBackdropTransparency"
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

/// Workflow behavior knobs — how plan runs behave, as opposed to how
/// the window looks. Same raw-key pattern as AppearanceSettings.
enum WorkflowSettings {
    static let autoCommitKey = "workflowAutoCommitPerTask"

    /// Default-ON when unset. UserDefaults.bool(forKey:) returns false
    /// for absent keys, which would silently ship the feature off —
    /// every non-SwiftUI read goes through here.
    static var autoCommitEnabled: Bool {
        UserDefaults.standard.object(forKey: autoCommitKey) == nil
            ? true
            : UserDefaults.standard.bool(forKey: autoCommitKey)
    }
}

struct SettingsView: View {
    @AppStorage(AppearanceSettings.cardShadowKey) private var cardShadow = true
    @AppStorage(AppearanceSettings.edgeInsetsKey) private var edgeInsets = true
    @AppStorage(AppearanceSettings.cornerRadiusKey) private var cornerRadius = 16.0
    @AppStorage(AppearanceSettings.backdropTransparencyKey)
    private var backdropTransparency = 0.72
    @AppStorage(AppearanceSettings.backdropTintKey) private var backdropTintHex = ""
    @AppStorage(AppearanceSettings.cardColorKey) private var cardColorHex = ""
    @AppStorage(AppearanceSettings.cardOpacityKey) private var cardOpacity = 1.0
    @AppStorage(WorkflowSettings.autoCommitKey) private var autoCommitPerTask = true

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
                LabeledContent("Backdrop transparency") {
                    HStack(spacing: 10) {
                        Slider(value: $backdropTransparency, in: 0...1)
                            .frame(width: 180)
                        Text("\(Int(backdropTransparency * 100))%")
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 44, alignment: .trailing)
                    }
                }
                ColorPicker(
                    "Backdrop color",
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
                Text("Backdrop transparency runs from solid color (0%) to raw desktop glass (100%). Card transparency lets the backdrop show through the content itself — terminal surfaces pick it up when newly opened. Everything else applies immediately.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Commit after each task", isOn: $autoCommitPerTask)
                Text("Plan agents commit each finished task; the app commits any leftovers when it sees a task complete. Off means plans only commit when the agent chooses to. Takes effect from the next task boundary.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Workflow")
            }
        }
        .formStyle(.grouped)
        .frame(width: 470)
        .fixedSize(horizontal: false, vertical: true)
    }
}
