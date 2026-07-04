import SwiftUI

/// App-wide appearance settings, persisted in UserDefaults and read live
/// by `ContentView` via the same `@AppStorage` keys.
enum AppearanceSettings {
    static let cardShadowKey = "appearanceCardShadow"
    static let edgeInsetsKey = "appearanceEdgeInsets"
}

struct SettingsView: View {
    @AppStorage(AppearanceSettings.cardShadowKey) private var cardShadow = true
    @AppStorage(AppearanceSettings.edgeInsetsKey) private var edgeInsets = true

    var body: some View {
        Form {
            Section {
                Toggle("Drop shadow", isOn: $cardShadow)
                Picker("Edge padding", selection: $edgeInsets) {
                    Text("Inset — floating card with gutters").tag(true)
                    Text("Flush — content runs to the window edge").tag(false)
                }
                .pickerStyle(.radioGroup)
            } header: {
                Text("Appearance")
            } footer: {
                Text("Both apply to the main content card immediately.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
    }
}
