import SwiftUI

/// Repo bootstrap choice offered when creating a project.
enum CreateRepoMode: String, CaseIterable, Identifiable {
    case none = "Skip"
    case initialize = "Initialize"
    case clone = "Clone"
    case importExisting = "Import"
    var id: String { rawValue }
}

/// Self-contained "New Project" sheet shared by Home and the projects
/// rail. Owns the form state and the create + repo-bootstrap flow so
/// both entry points behave identically; callers provide the store and
/// react to `onCreated` (the sheet dismisses itself first).
struct CreateProjectSheet: View {
    let store: ProjectStore
    let onCreated: (Project) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var repoMode: CreateRepoMode = .none
    @State private var repoURL = ""
    @State private var repoName = ""
    @State private var importPath: URL?
    @State private var error: String?
    @State private var isWorking = false
    @State private var didTouchRepoName = false

    @FocusState private var focused: Field?

    enum Field { case name, repoURL, repoName }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Project")
                .font(.headline)
            Text("A folder will be created under ~/Documents/Clayspace.")
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 6) {
                Text("Project name")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                TextField("e.g. mobile-app", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused, equals: .name)
                    .disabled(isWorking)
                    .onSubmit(submitIfReady)
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Repository (optional)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Picker("Repository", selection: $repoMode) {
                    ForEach(CreateRepoMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .disabled(isWorking)

                if repoMode == .clone {
                    TextField("git@github.com:owner/repo.git", text: $repoURL)
                        .textFieldStyle(.roundedBorder)
                        .focused($focused, equals: .repoURL)
                        .disabled(isWorking)
                        .onChange(of: repoURL) { _, newURL in
                            if !didTouchRepoName {
                                let derived = GitOperations.deriveName(from: newURL)
                                if !derived.isEmpty { repoName = derived }
                            }
                        }
                }

                if repoMode == .importExisting {
                    HStack(spacing: 8) {
                        Text(importPath?.path ?? "Choose source folder…")
                            .font(.callout)
                            .foregroundStyle(importPath == nil ? .tertiary : .primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button("Choose…", action: chooseImportFolder)
                            .disabled(isWorking)
                    }
                }

                if repoMode != .none {
                    TextField(
                        repoNamePlaceholder,
                        text: $repoName
                    )
                    .textFieldStyle(.roundedBorder)
                    .focused($focused, equals: .repoName)
                    .disabled(isWorking)
                    .onChange(of: repoName) { _, _ in didTouchRepoName = true }
                }

                Text("All repos use a bare-with-worktrees layout: .bare/ for git data plus a worktree for the default branch under repos/<name>/. Import keeps the source folder untouched (we git clone --bare from it).")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                if isWorking {
                    ProgressView()
                        .controlSize(.small)
                    Text(workingLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isWorking)
                Button(isWorking ? "Creating…" : "Create", action: submitIfReady)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSubmit || isWorking)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear { focused = .name }
    }

    // MARK: - Validation

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private var trimmedRepoURL: String {
        repoURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSubmit: Bool {
        guard !trimmedName.isEmpty else { return false }
        switch repoMode {
        case .none, .initialize:
            return true
        case .clone:
            return !trimmedRepoURL.isEmpty
        case .importExisting:
            return importPath != nil
        }
    }

    private var workingLabel: String {
        switch repoMode {
        case .clone: return "Cloning repository…"
        case .initialize: return "Initializing repository…"
        case .importExisting: return "Importing repository…"
        case .none: return "Creating project…"
        }
    }

    private var repoNamePlaceholder: String {
        switch repoMode {
        case .clone: return "Folder name (auto-detected)"
        case .initialize: return "Folder name (defaults to project name)"
        case .importExisting: return "Folder name (defaults to source folder)"
        case .none: return "Folder name"
        }
    }

    // MARK: - Actions

    private func submitIfReady() {
        guard canSubmit else { return }
        createProject()
    }

    private func createProject() {
        guard !isWorking else { return }
        let projectName = trimmedName
        let repoIntent = pendingRepoIntent(forProjectName: projectName)
        isWorking = true
        error = nil

        Task {
            do {
                let project = try store.createProject(name: projectName)

                // Run the optional repo bootstrap before handing the
                // project back so its window appears with the repo
                // already in place (avoids a "Repositories: empty"
                // flash).
                if let repoIntent {
                    try await runRepoIntent(repoIntent, in: project)
                }

                isWorking = false
                dismiss()
                onCreated(project)
            } catch {
                self.error = error.localizedDescription
                isWorking = false
            }
        }
    }

    private func pendingRepoIntent(forProjectName projectName: String) -> AddRepoIntent? {
        switch repoMode {
        case .none:
            return nil
        case .initialize:
            let trimmed = repoName.trimmingCharacters(in: .whitespacesAndNewlines)
            return .initialize(name: trimmed.isEmpty ? projectName : trimmed)
        case .clone:
            let url = trimmedRepoURL
            guard !url.isEmpty else { return nil }
            let trimmed = repoName.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = trimmed.isEmpty ? GitOperations.deriveName(from: url) : trimmed
            return .clone(url: url, name: name)
        case .importExisting:
            guard let path = importPath else { return nil }
            let trimmed = repoName.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = trimmed.isEmpty ? GitOperations.deriveName(from: path.lastPathComponent) : trimmed
            return .importLocal(path: path, name: name)
        }
    }

    private func runRepoIntent(_ intent: AddRepoIntent, in project: Project) async throws {
        switch intent {
        case .clone(let url, let name):
            _ = try await GitOperations.cloneBare(url: url, into: project.rootPath, name: name)
        case .initialize(let name):
            _ = try await GitOperations.initBare(into: project.rootPath, name: name)
        case .importLocal(let path, let name):
            // Same engine — `git clone --bare` from a local path treats
            // it as a URL, mirroring the source's history into our .bare/.
            _ = try await GitOperations.cloneBare(url: path.path, into: project.rootPath, name: name)
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
            if !didTouchRepoName {
                let derived = GitOperations.deriveName(from: url.lastPathComponent)
                if !derived.isEmpty { repoName = derived }
            }
        }
    }
}
