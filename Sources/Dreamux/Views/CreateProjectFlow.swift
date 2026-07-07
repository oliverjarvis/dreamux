import SwiftUI

/// Repo bootstrap choice offered when creating a project. Every project
/// gets a git repository — the choice is only *how* it's seeded.
enum CreateRepoMode: String, CaseIterable, Identifiable {
    case initialize = "New repo"
    case clone = "Clone"
    case importExisting = "Import"
    var id: String { rawValue }
}

/// Self-contained "New Project" sheet shared by Home and the projects
/// rail. Owns the form state and the create + repo-bootstrap flow so
/// both entry points behave identically; callers provide the store and
/// react to `onCreated` (the sheet dismisses itself first).
///
/// A project always gets a git repository: a fresh one is initialized, a
/// remote is cloned, or an existing folder is imported. When cloning or
/// importing, the project name auto-fills from the source and stays
/// editable; when starting fresh, the typed name is slugified into the
/// repository's folder name (`Pokemon Emulator` → `pokemon-emulator`).
struct CreateProjectSheet: View {
    let store: ProjectStore
    let onCreated: (Project) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var repoMode: CreateRepoMode = .initialize
    @State private var repoURL = ""
    @State private var importPath: URL?
    @State private var error: String?
    @State private var isWorking = false
    /// The name we last auto-filled from the clone URL / imported folder.
    /// Auto-fill keeps flowing while the field still holds this value; once
    /// the user types something else, `name != autoFilledName` and we stop
    /// (this also ignores our own programmatic writes, which would otherwise
    /// look like user edits to `onChange`).
    @State private var autoFilledName = ""

    @FocusState private var focused: Field?

    enum Field { case name, repoURL }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Project")
                .font(.headline)
            Text("A folder is created under ~/Documents/Dreamux with a git repository inside.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                Text("Repository")
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
                            // Sync the name to the URL until the user edits
                            // it by hand.
                            if name.isEmpty || name == autoFilledName {
                                let derived = GitOperations.deriveName(from: newURL)
                                name = derived
                                autoFilledName = derived
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
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Project name")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                TextField(namePlaceholder, text: $name)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused, equals: .name)
                    .disabled(isWorking)
                    .onSubmit(submitIfReady)
                if !repoSummary.isEmpty {
                    Text(repoSummary)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
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
        .onAppear { focused = repoMode == .clone ? .repoURL : .name }
    }

    // MARK: - Derived

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private var trimmedRepoURL: String {
        repoURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The repository folder name that will be created under `repos/`.
    /// New repos slugify the project name; clone/import take the source's
    /// own name.
    private var derivedRepoName: String {
        switch repoMode {
        case .initialize:
            return GitOperations.slug(from: trimmedName)
        case .clone:
            return GitOperations.deriveName(from: trimmedRepoURL)
        case .importExisting:
            return importPath.map { GitOperations.deriveName(from: $0.lastPathComponent) } ?? ""
        }
    }

    private var namePlaceholder: String {
        switch repoMode {
        case .initialize: return "e.g. Pokemon Emulator"
        case .clone: return "Auto-filled from the repository"
        case .importExisting: return "Auto-filled from the folder"
        }
    }

    /// A one-line summary of the repository that will be created, shown
    /// under the name field.
    private var repoSummary: String {
        let repo = derivedRepoName
        guard !repo.isEmpty else { return "" }
        switch repoMode {
        case .initialize:
            return "Initializes a git repository named “\(repo)”."
        case .clone:
            return "Clones into a repository named “\(repo)”."
        case .importExisting:
            return "Imports the folder as a repository named “\(repo)”."
        }
    }

    private var canSubmit: Bool {
        guard !trimmedName.isEmpty else { return false }
        switch repoMode {
        case .initialize:
            // A slug is required so the repo folder is well-formed (a name
            // of only punctuation would slug to empty).
            return !derivedRepoName.isEmpty
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
        let repoIntent = pendingRepoIntent()
        isWorking = true
        error = nil

        Task {
            do {
                let project = try store.createProject(name: projectName)

                // Seed the repository before handing the project back so
                // its window appears with the repo already in place
                // (avoids a "Repositories: empty" flash).
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

    private func pendingRepoIntent() -> AddRepoIntent? {
        let repo = derivedRepoName
        switch repoMode {
        case .initialize:
            guard !repo.isEmpty else { return nil }
            return .initialize(name: repo)
        case .clone:
            let url = trimmedRepoURL
            guard !url.isEmpty else { return nil }
            return .clone(url: url, name: repo)
        case .importExisting:
            guard let path = importPath else { return nil }
            return .importLocal(path: path, name: repo)
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
            if name.isEmpty || name == autoFilledName {
                let derived = GitOperations.deriveName(from: url.lastPathComponent)
                name = derived
                autoFilledName = derived
            }
        }
    }
}
