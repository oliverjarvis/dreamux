import SwiftUI

/// Sheet for adding a `Connection` — either import a token from an existing
/// CLI login (gh/eas) or type one in by hand. Both paths share one set of
/// fields (label/kind/hosts/token) below a mode switch; importing prefills
/// them from the `CLICredentialImporter.Draft`, and Save reads whatever the
/// fields currently hold. The token is entered ONLY via `SecureField` and
/// is never echoed back after Save — `store.add` writes it straight to the
/// Keychain and this view discards its own copy on dismiss.
struct AddConnectionSheet: View {
    let store: ConnectionStore
    /// Slot-provided provider hint (a connection slot's `suggests`) — when it
    /// maps to a known CLI provider, the sheet opens on the Import-from-CLI
    /// tab with that provider pre-selected. Optional/defaulted so the T7
    /// Settings call site (which has no slot) compiles unchanged.
    var suggestedProvider: String? = nil
    let onDone: () -> Void

    enum Mode: String, CaseIterable, Identifiable {
        case importFromCLI = "Import from CLI"
        case manual = "Manual"
        var id: String { rawValue }
    }

    /// The four auth shapes exposed in the picker. `.query` exists on
    /// `AuthKind` but isn't offered here — no current provider (manual or
    /// CLI) needs it, so leaving it out of the UI is YAGNI, not an omission.
    enum KindChoice: String, CaseIterable, Identifiable {
        case bearer = "Bearer header"
        case apiKey = "API-key header"
        case basic = "Basic"
        case env = "Env var"
        var id: String { rawValue }
    }

    enum Field {
        case label, headerName, basicUsername, envVarName, hosts, token
    }

    @State private var mode: Mode = .importFromCLI

    // Import path.
    @State private var selectedProviderID = CLICredentialImporter.providers.first?.id ?? ""
    @State private var isImporting = false
    @State private var importNotFound = false
    /// Set once a CLI import succeeds; carries the exact `source` +
    /// `preferredID` Save uses for the import path. Cleared when the user
    /// switches to Manual, so a stale import can't masquerade as this
    /// session's provenance after they've moved on.
    @State private var importedDraft: CLICredentialImporter.Draft?

    // Shared fields — prefilled by an import, or typed by hand.
    @State private var label = ""
    @State private var kindChoice: KindChoice = .bearer
    @State private var headerName = "X-API-Key"
    @State private var basicUsername = ""
    @State private var envVarName = "TOKEN"
    @State private var hostsText = ""
    @State private var token = ""

    @State private var errorMessage: String?

    @FocusState private var focused: Field?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add Connection")
                .font(.title3.weight(.semibold))

            Text("Applets call authenticated APIs through connections. Import an existing gh/eas login, or type one in — the token is stored in the Keychain, never in project files.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Picker("Mode", selection: $mode) {
                ForEach(Mode.allCases) { m in
                    Text(m.rawValue).tag(m)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .onChange(of: mode) { _, newMode in
                if newMode == .manual {
                    importedDraft = nil
                    importNotFound = false
                }
            }

            if mode == .importFromCLI {
                importSection
            }

            manualFieldsSection

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel", action: onDone)
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear {
            // If the presenting slot suggests a provider we can import, land
            // the user on that ready-to-import tab; otherwise keep defaults.
            if let hint = suggestedProvider, let providerID = Self.resolveProvider(hint) {
                mode = .importFromCLI
                selectedProviderID = providerID
            }
            focused = .label
        }
    }

    /// Maps a slot's `suggests` hint to a known `CLICredentialImporter`
    /// provider id, accepting both manifest conventions for each pair
    /// (`"github"`/`"gh"` → `"gh"`, `"expo"`/`"eas"` → `"expo"`), then falling
    /// back to a direct provider-id match. Returns nil when nothing lines up,
    /// so the sheet keeps its default tab/provider rather than guessing.
    private static func resolveProvider(_ hint: String) -> String? {
        switch hint.lowercased() {
        case "github", "gh": return "gh"
        case "expo", "eas": return "expo"
        default:
            return CLICredentialImporter.providers.contains { $0.id == hint } ? hint : nil
        }
    }

    // MARK: - Import section

    private var importSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            field("Provider") {
                Picker("Provider", selection: $selectedProviderID) {
                    ForEach(CLICredentialImporter.providers, id: \.id) { provider in
                        Text(provider.label).tag(provider.id)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }

            HStack(spacing: 10) {
                Button {
                    runImport()
                } label: {
                    if isImporting {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Import")
                    }
                }
                .buttonStyle(.soft)
                .disabled(isImporting || selectedProviderID.isEmpty)

                if importNotFound {
                    Text("Not logged in, or no token found for this provider.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else if importedDraft != nil {
                    Text("Imported — review the fields below, then Save.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.03))
        )
    }

    private func runImport() {
        isImporting = true
        importNotFound = false
        let provider = selectedProviderID
        Task {
            let draft = await CLICredentialImporter.importFromCLI(provider: provider)
            isImporting = false
            if let draft {
                applyDraft(draft)
            } else {
                importedDraft = nil
                importNotFound = true
            }
        }
    }

    /// Prefills the shared fields from a successful import. `kindChoice`
    /// (plus its one associated field) is reverse-mapped from the draft's
    /// `AuthKind` so Save's reconstruction round-trips it exactly for
    /// today's providers (both gh and eas hand back a Bearer header).
    private func applyDraft(_ draft: CLICredentialImporter.Draft) {
        importedDraft = draft
        importNotFound = false
        errorMessage = nil
        label = draft.label
        hostsText = draft.hosts.joined(separator: ", ")
        token = draft.token
        switch draft.kind {
        case .header(let name, let template):
            if name == "Authorization", template.contains("Bearer") {
                kindChoice = .bearer
            } else {
                kindChoice = .apiKey
                headerName = name
            }
        case .basic(let username):
            kindChoice = .basic
            basicUsername = username
        case .env(let vars):
            kindChoice = .env
            envVarName = vars.first ?? envVarName
        case .query:
            // Unreachable for gh/eas today; fall back rather than drop the
            // import silently.
            kindChoice = .apiKey
            headerName = "Authorization"
        }
    }

    // MARK: - Manual / shared fields

    private var manualFieldsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            field("Label") {
                TextField("e.g. GitHub", text: $label)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused, equals: .label)
            }

            field("Auth kind") {
                Picker("Auth kind", selection: $kindChoice) {
                    ForEach(KindChoice.allCases) { choice in
                        Text(choice.rawValue).tag(choice)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }

            switch kindChoice {
            case .bearer:
                EmptyView()
            case .apiKey:
                field("Header name") {
                    TextField("X-API-Key", text: $headerName)
                        .textFieldStyle(.roundedBorder)
                        .focused($focused, equals: .headerName)
                }
            case .basic:
                field("Username") {
                    TextField("username", text: $basicUsername)
                        .textFieldStyle(.roundedBorder)
                        .focused($focused, equals: .basicUsername)
                }
            case .env:
                field("Env variable name") {
                    TextField("GH_TOKEN", text: $envVarName)
                        .textFieldStyle(.roundedBorder)
                        .focused($focused, equals: .envVarName)
                }
            }

            field("Hosts") {
                TextField("api.github.com, api.expo.dev", text: $hostsText)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused, equals: .hosts)
            }

            field("Token") {
                SecureField("Paste token", text: $token)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused, equals: .token)
            }
        }
    }

    private func field<Content: View>(
        _ title: String, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }

    // MARK: - Save

    private var trimmedLabel: String {
        label.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A pasted token often carries a trailing newline/space; trim it so it
    /// can't silently corrupt the header/basic/env value it's substituted
    /// into. The CLI-import path already hands back a trimmed token.
    private var trimmedToken: String {
        token.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hostsArray: [String] {
        hostsText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private var kindFieldsValid: Bool {
        switch kindChoice {
        case .bearer: return true
        case .apiKey: return !headerName.trimmingCharacters(in: .whitespaces).isEmpty
        case .basic: return !basicUsername.trimmingCharacters(in: .whitespaces).isEmpty
        case .env: return !envVarName.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    private var canSave: Bool {
        !trimmedLabel.isEmpty && !trimmedToken.isEmpty && !hostsArray.isEmpty && kindFieldsValid
    }

    /// Maps the current picker choice + its one typed field to an
    /// `AuthKind` — see `AuthKind`'s doc comment for the header/template
    /// shapes (Bearer: "Authorization"/"Bearer {token}"; API key:
    /// user-typed header name / "{token}").
    private var effectiveKind: AuthKind {
        switch kindChoice {
        case .bearer:
            return .header(headerName: "Authorization", valueTemplate: "Bearer {token}")
        case .apiKey:
            return .header(
                headerName: headerName.trimmingCharacters(in: .whitespaces),
                valueTemplate: "{token}")
        case .basic:
            return .basic(username: basicUsername.trimmingCharacters(in: .whitespaces))
        case .env:
            return .env(vars: [envVarName.trimmingCharacters(in: .whitespaces)])
        }
    }

    private var effectiveSource: Connection.Source {
        if mode == .importFromCLI, let importedDraft {
            return importedDraft.source
        }
        return .manual
    }

    private var effectivePreferredID: String {
        if mode == .importFromCLI, let importedDraft {
            return importedDraft.preferredID
        }
        return trimmedLabel
    }

    private func save() {
        guard canSave else { return }
        do {
            _ = try store.add(
                label: trimmedLabel,
                kind: effectiveKind,
                hosts: hostsArray,
                token: trimmedToken,
                source: effectiveSource,
                preferredID: effectivePreferredID
            )
            onDone()
        } catch {
            errorMessage = "Couldn't save: \(error.localizedDescription)"
        }
    }
}
