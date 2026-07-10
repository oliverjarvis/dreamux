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
    /// The full slot being bound, when this sheet is presented from
    /// `ConnectionBindSheet`'s Create-new row — a slot-declared recipe
    /// (`authKind`/`importCommand`, from G1) prefills the manual fields and
    /// picks the landing tab in `.onAppear`. Optional/defaulted so the T7
    /// Settings call site (which has no slot) compiles unchanged.
    var prefillSlot: ConnectionSlot? = nil
    /// Slot-provided provider hint (a connection slot's `suggests`) — when it
    /// maps to a known CLI provider, the sheet opens on the Import-from-CLI
    /// tab with that provider pre-selected. Optional/defaulted so the T7
    /// Settings call site (which has no slot) compiles unchanged. Used as the
    /// no-recipe fallback when `prefillSlot` has neither `authKind` nor
    /// `importCommand`.
    var suggestedProvider: String? = nil
    let onDone: () -> Void

    enum Mode: String, CaseIterable, Identifiable {
        case importFromCLI = "Import from CLI"
        case manual = "Manual"
        var id: String { rawValue }
    }

    /// The four auth shapes exposed in the picker, mapping 1:1 to `AuthKind`
    /// so any token-based service — not just gh/expo's Bearer header — can be
    /// wired up by hand: a freeform header name + value template, HTTP
    /// Basic, a query-string param, or a shell env var.
    enum KindChoice: String, CaseIterable, Identifiable {
        case header = "Header"
        case basic = "Basic"
        case query = "Query param"
        case env = "Env var"
        var id: String { rawValue }
    }

    enum Field {
        case label, headerName, valueTemplate, basicUsername, queryParam, envVarName, hosts, token
        case importCommand
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
    @State private var kindChoice: KindChoice = .header
    @State private var headerName = "Authorization"
    @State private var valueTemplate = "Bearer {token}"
    @State private var basicUsername = ""
    @State private var queryParam = "api_key"
    @State private var envVarName = "TOKEN"
    @State private var hostsText = ""
    @State private var token = ""

    @State private var errorMessage: String?

    // Custom-command import path.
    @State private var importCommand = ""
    @State private var isRunningCommand = false
    @State private var commandImportMessage: String?
    @State private var commandImportFailed = false

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
                    commandImportMessage = nil
                    commandImportFailed = false
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
            // A slot-declared recipe (G1) prefills label/hosts/auth shape
            // BEFORE the no-recipe suggestedProvider fallback below, so a
            // slot with only `suggests` still lands on the import preset.
            if let prefillSlot {
                if label.isEmpty { label = prefillSlot.label }
                hostsText = prefillSlot.hosts.joined(separator: ", ")
                if let authKind = prefillSlot.authKind {
                    applyKind(authKind)
                }
                // importCommand wins the landing tab when both are present —
                // running it is the fast path; the manual fields prefilled
                // above are still there underneath if the user switches.
                if let command = prefillSlot.importCommand {
                    importCommand = command
                    mode = .importFromCLI
                } else if prefillSlot.authKind != nil {
                    mode = .manual
                }
            }
            // If the presenting slot suggests a provider we can import — and
            // no recipe already drove the landing tab above — land the user
            // on that ready-to-import tab; otherwise keep defaults. This is
            // strictly the no-recipe fallback: a slot carrying an `authKind`
            // or `importCommand` keeps its recipe-driven landing (e.g. a
            // recipe's Manual landing isn't silently overwritten by a
            // `suggests` hint that would flip it back to Import).
            let hasRecipe = prefillSlot?.authKind != nil || prefillSlot?.importCommand != nil
            if !hasRecipe, let hint = suggestedProvider, let providerID = Self.resolveProvider(hint) {
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

            Divider()
                .padding(.vertical, 2)

            Text("Or run a command")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                TextField("gh auth token", text: $importCommand)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused, equals: .importCommand)

                Button {
                    runCommandImport()
                } label: {
                    if isRunningCommand {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Run")
                    }
                }
                .buttonStyle(.soft)
                .disabled(isRunningCommand || importCommand.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            Text("Runs at your privilege when you click Run — Dreamux never runs it automatically.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let commandImportMessage {
                Text(commandImportMessage)
                    .font(.caption)
                    .foregroundStyle(commandImportFailed ? .orange : .secondary)
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

    /// Runs an arbitrary user-typed command (e.g. `gh auth token`) to pull a
    /// token from any CLI Dreamux has no built-in provider for. Strictly
    /// user-triggered by the Run button — never invoked from `.onAppear` or
    /// any other automatic path, per the consent rule surfaced in the
    /// caption below the field. Unlike a provider import, a raw command
    /// carries no label/host/kind metadata, so only `token` is filled in;
    /// the user still picks the auth kind and hosts by hand.
    private func runCommandImport() {
        isRunningCommand = true
        commandImportMessage = nil
        commandImportFailed = false
        let command = importCommand
        Task {
            let result = await CLICredentialImporter.runCommand(command)
            isRunningCommand = false
            if let result {
                token = result
                commandImportFailed = false
                commandImportMessage = "Imported from command — review below, then Save."
            } else {
                commandImportFailed = true
                commandImportMessage = "Command produced no token."
            }
        }
    }

    /// Prefills the shared fields from a successful import. `kindChoice`
    /// (plus its associated field(s)) is reverse-mapped from the draft's
    /// `AuthKind` so Save's reconstruction round-trips it exactly — a
    /// Bearer import (gh/eas today) lands as `.header` with headerName
    /// "Authorization" and valueTemplate "Bearer {token}", both editable,
    /// so an import that's close-but-not-quite for some service can be
    /// tweaked in place rather than requiring a fully manual re-entry.
    private func applyDraft(_ draft: CLICredentialImporter.Draft) {
        importedDraft = draft
        importNotFound = false
        errorMessage = nil
        label = draft.label
        hostsText = draft.hosts.joined(separator: ", ")
        token = draft.token
        applyKind(draft.kind)
    }

    /// Maps an `AuthKind` to `kindChoice` + its associated field(s) — the
    /// reverse of `effectiveKind`. Shared by `applyDraft` (a CLI import) and
    /// the `prefillSlot` recipe path (`.onAppear`) so both round-trip
    /// through the exact same mapping rather than duplicating the switch.
    private func applyKind(_ kind: AuthKind) {
        switch kind {
        case .header(let name, let template):
            kindChoice = .header
            headerName = name
            valueTemplate = template
        case .basic(let username):
            kindChoice = .basic
            basicUsername = username
        case .query(let param):
            kindChoice = .query
            queryParam = param
        case .env(let vars):
            kindChoice = .env
            envVarName = vars.first ?? envVarName
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
            case .header:
                field("Header name") {
                    TextField("Authorization", text: $headerName)
                        .textFieldStyle(.roundedBorder)
                        .focused($focused, equals: .headerName)
                }
                VStack(alignment: .leading, spacing: 4) {
                    field("Value template") {
                        TextField("Bearer {token}", text: $valueTemplate)
                            .textFieldStyle(.roundedBorder)
                            .focused($focused, equals: .valueTemplate)
                    }
                    Text("Must contain {token}")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            case .basic:
                field("Username") {
                    TextField("username", text: $basicUsername)
                        .textFieldStyle(.roundedBorder)
                        .focused($focused, equals: .basicUsername)
                }
            case .query:
                field("Query parameter") {
                    TextField("api_key", text: $queryParam)
                        .textFieldStyle(.roundedBorder)
                        .focused($focused, equals: .queryParam)
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

    /// The `.header` check mirrors `ConnectionAuthenticator`'s
    /// `.templateMissingPlaceholder` guard so a template that would fail at
    /// call time can't be saved here in the first place.
    private var kindFieldsValid: Bool {
        switch kindChoice {
        case .header:
            return !headerName.trimmingCharacters(in: .whitespaces).isEmpty
                && valueTemplate.contains("{token}")
        case .basic: return !basicUsername.trimmingCharacters(in: .whitespaces).isEmpty
        case .query: return !queryParam.trimmingCharacters(in: .whitespaces).isEmpty
        case .env: return !envVarName.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    private var canSave: Bool {
        !trimmedLabel.isEmpty && !trimmedToken.isEmpty && !hostsArray.isEmpty && kindFieldsValid
    }

    /// Maps the current picker choice + its typed field(s) to an `AuthKind`
    /// — see `AuthKind`'s doc comment for the general header/template shape.
    /// `.header` is fully freeform now: both the header name and the value
    /// template (which must contain "{token}", enforced by
    /// `kindFieldsValid`) are user-editable, so any header-based service —
    /// Bearer, "token {token}", a custom API-key header, whatever a service
    /// documents — is expressible without new UI.
    private var effectiveKind: AuthKind {
        switch kindChoice {
        case .header:
            return .header(
                headerName: headerName.trimmingCharacters(in: .whitespaces),
                valueTemplate: valueTemplate.trimmingCharacters(in: .whitespaces))
        case .basic:
            return .basic(username: basicUsername.trimmingCharacters(in: .whitespaces))
        case .query:
            return .query(param: queryParam.trimmingCharacters(in: .whitespaces))
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
