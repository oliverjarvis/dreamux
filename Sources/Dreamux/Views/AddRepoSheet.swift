import SwiftUI
import AppKit

enum AddRepoIntent {
    case clone(url: String, name: String)
    case initialize(name: String)
    case importLocal(path: URL, name: String)
}

struct AddRepoSheet: View {
    let projectName: String
    let onSubmit: (AddRepoIntent) -> Void
    let onCancel: () -> Void

    @State private var mode: Mode = .clone
    @State private var url: String = ""
    @State private var importPath: URL?
    @State private var name: String = ""
    @State private var didTouchName = false
    @State private var error: String?
    @State private var isWorking = false

    @FocusState private var focused: Field?

    enum Mode: String, CaseIterable, Identifiable {
        case clone = "Clone"
        case initialize = "Initialize"
        case importExisting = "Import"
        var id: String { rawValue }
    }

    enum Field {
        case url, name
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add Repository")
                .font(.title3.weight(.semibold))

            Text("All three flows land at \(projectName)/repos/<name>/ with a bare repo at .bare/ and a worktree on the default branch. Import keeps the source folder untouched — we git clone --bare from it.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Picker("Mode", selection: $mode) {
                ForEach(Mode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if mode == .clone {
                VStack(alignment: .leading, spacing: 6) {
                    Text("URL")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    TextField("git@github.com:owner/repo.git", text: $url)
                        .textFieldStyle(.roundedBorder)
                        .focused($focused, equals: .url)
                        .onChange(of: url) { _, newURL in
                            if !didTouchName {
                                let derived = GitOperations.deriveName(from: newURL)
                                if !derived.isEmpty { name = derived }
                            }
                        }
                }
            } else if mode == .importExisting {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Source folder")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        Text(importPath?.path ?? "Choose a folder…")
                            .font(.callout)
                            .foregroundStyle(importPath == nil ? .tertiary : .primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button("Choose…", action: chooseImportFolder)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Folder name")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                TextField("e.g. backend", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused, equals: .name)
                    .onChange(of: name) { _, _ in didTouchName = true }
            }

            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .disabled(isWorking)
                Button(submitTitle, action: submit)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSubmit || isWorking)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear { focused = mode == .clone ? .url : .name }
        .onChange(of: mode) { _, newMode in
            focused = newMode == .clone ? .url : .name
        }
    }

    private var trimmedURL: String {
        url.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSubmit: Bool {
        switch mode {
        case .clone: return !trimmedURL.isEmpty && !trimmedName.isEmpty
        case .initialize: return !trimmedName.isEmpty
        case .importExisting: return importPath != nil && !trimmedName.isEmpty
        }
    }

    private var submitTitle: String {
        isWorking ? "Working…" : "Add"
    }

    func reportError(_ message: String) {
        error = message
        isWorking = false
    }

    func setWorking(_ value: Bool) {
        isWorking = value
        if value { error = nil }
    }

    private func submit() {
        guard canSubmit else { return }
        switch mode {
        case .clone:
            onSubmit(.clone(url: trimmedURL, name: trimmedName))
        case .initialize:
            onSubmit(.initialize(name: trimmedName))
        case .importExisting:
            guard let importPath else { return }
            onSubmit(.importLocal(path: importPath, name: trimmedName))
        }
    }

    private func chooseImportFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Pick the existing local repository to import."
        if panel.runModal() == .OK, let url = panel.url {
            importPath = url
            if !didTouchName {
                let derived = GitOperations.deriveName(from: url.lastPathComponent)
                if !derived.isEmpty { name = derived }
            }
        }
    }
}
