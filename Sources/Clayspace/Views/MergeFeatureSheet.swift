import SwiftUI
import AppKit

/// Per-repo state of merging the feature branch into its default
/// branch. Local to the sheet; resets every time the sheet is opened.
enum MergeRepoState: Equatable {
    case pending
    case working
    case upToDate
    case merged
    case conflicted(paths: [String])
    case failed(message: String)

    var isTerminal: Bool {
        switch self {
        case .pending, .working: return false
        default: return true
        }
    }

    var canMerge: Bool {
        switch self {
        case .pending, .failed: return true
        default: return false
        }
    }
}

struct MergeFeatureSheet: View {
    let workspace: Workspace
    let repos: [Repository]
    /// Opens a new tab in the workspace at the given absolute path,
    /// with a tab title indicating the conflict.
    let onOpenConflictTab: (URL, String) -> Void
    let onDismiss: () -> Void

    @State private var states: [String: MergeRepoState] = [:]
    @State private var isBatchRunning = false
    @State private var pollTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            VStack(spacing: 8) {
                ForEach(repos) { repo in
                    repoRow(repo)
                }
            }

            Divider()

            HStack {
                Button {
                    Task { await mergeAllPending() }
                } label: {
                    if isBatchRunning {
                        HStack {
                            ProgressView().controlSize(.small)
                            Text("Merging…")
                        }
                    } else {
                        Text("Merge All Pending")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isBatchRunning || !hasPending)

                Spacer()

                Button("Done", action: onDismiss)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 540)
        .onAppear {
            initializeStates()
            startPolling()
        }
        .onDisappear { pollTask?.cancel() }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Merge \(workspace.name)")
                .font(.title3.weight(.semibold))
            Text("Merges \(workspace.name) into each repo's default branch from the existing default-branch worktree. The feature branch and worktree stay until you clean up.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Per-repo row

    @ViewBuilder
    private func repoRow(_ repo: Repository) -> some View {
        let state = states[repo.name] ?? .pending
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "shippingbox.fill")
                    .foregroundStyle(.secondary)
                Text(repo.name).font(.callout.weight(.semibold))
                Text("\(workspace.name) → \(repo.defaultBranch)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
                stateBadge(state)
            }

            if case .conflicted(let paths) = state {
                conflictDetails(repo: repo, paths: paths)
            } else if case .failed(let message) = state {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                if state.canMerge {
                    Button("Merge") {
                        Task { await runMerge(for: repo) }
                    }
                    .buttonStyle(.bordered)
                }
                if case .conflicted = state {
                    Button("Open in Terminal") {
                        let path = baseWorktreeURL(for: repo)
                        onOpenConflictTab(path, "\(repo.name) merge")
                    }
                    .buttonStyle(.bordered)
                    Button("Copy Resolution Prompt") {
                        copyPrompt(for: repo, paths: conflictedPaths(state))
                    }
                    .buttonStyle(.bordered)
                    Button("Abort Merge") {
                        Task { await abortMerge(for: repo) }
                    }
                    .buttonStyle(.bordered)
                }
                if case .merged = state {
                    Button("Cleanup Worktree & Branch") {
                        Task { await cleanup(repo) }
                    }
                    .buttonStyle(.bordered)
                }
                if case .upToDate = state {
                    Button("Cleanup Worktree & Branch") {
                        Task { await cleanup(repo) }
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
    }

    @ViewBuilder
    private func conflictDetails(repo: Repository, paths: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Conflicts in \(paths.count) file\(paths.count == 1 ? "" : "s"):")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)
            Text(paths.joined(separator: ", "))
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .truncationMode(.middle)
            Text("Worktree: \(baseWorktreeURL(for: repo).path)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    @ViewBuilder
    private func stateBadge(_ state: MergeRepoState) -> some View {
        switch state {
        case .pending:
            Text("Pending")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        case .working:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Merging…").font(.caption)
            }
        case .upToDate:
            Label("Up to date", systemImage: "checkmark.seal.fill")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        case .merged:
            Label("Merged", systemImage: "checkmark.seal.fill")
                .font(.caption.weight(.medium))
                .foregroundStyle(.green)
        case .conflicted(let paths):
            Label("\(paths.count) conflict\(paths.count == 1 ? "" : "s")", systemImage: "exclamationmark.triangle.fill")
                .font(.caption.weight(.medium))
                .foregroundStyle(.orange)
        case .failed:
            Label("Failed", systemImage: "xmark.octagon.fill")
                .font(.caption.weight(.medium))
                .foregroundStyle(.red)
        }
    }

    // MARK: - Actions

    private func initializeStates() {
        var map: [String: MergeRepoState] = [:]
        for repo in repos {
            map[repo.name] = .pending
        }
        states = map
    }

    /// Poll every ~2.5s while the sheet is open. For any repo that's
    /// still showing as conflicted in our state map, ask git whether
    /// the conflict has been resolved. This is what makes the sheet
    /// flip to "Merged" automatically once the user (or their agent)
    /// finishes resolving and commits.
    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(2500))
                if Task.isCancelled { return }
                await pollConflictedRepos()
            }
        }
    }

    private func pollConflictedRepos() async {
        for repo in repos {
            guard case .conflicted = states[repo.name] ?? .pending else { continue }
            let baseURL = baseWorktreeURL(for: repo)
            let probe = await GitOperations.mergeProbe(
                in: baseURL,
                feature: workspace.name,
                baseBranch: repo.defaultBranch
            )
            switch probe {
            case .inProgress:
                // Refresh the conflicted file list — the agent might
                // have resolved a few but not all yet.
                let paths = await GitOperations.conflictedPaths(in: baseURL)
                if !paths.isEmpty {
                    states[repo.name] = .conflicted(paths: paths)
                }
            case .merged:
                states[repo.name] = .merged
            case .notMerged:
                // External `git merge --abort` or unrelated change.
                states[repo.name] = .pending
            }
        }
    }

    private var hasPending: Bool {
        states.values.contains { $0.canMerge }
    }

    private func runMerge(for repo: Repository) async {
        states[repo.name] = .working
        let baseURL = baseWorktreeURL(for: repo)
        do {
            let outcome = try await GitOperations.mergeBranch(
                feature: workspace.name,
                into: repo.defaultBranch,
                in: baseURL
            )
            switch outcome {
            case .alreadyUpToDate: states[repo.name] = .upToDate
            case .merged:          states[repo.name] = .merged
            case .conflicted(let paths): states[repo.name] = .conflicted(paths: paths)
            }
        } catch {
            states[repo.name] = .failed(message: error.localizedDescription)
        }
    }

    private func mergeAllPending() async {
        isBatchRunning = true
        for repo in repos where (states[repo.name] ?? .pending).canMerge {
            await runMerge(for: repo)
        }
        isBatchRunning = false
    }

    private func abortMerge(for repo: Repository) async {
        let baseURL = baseWorktreeURL(for: repo)
        states[repo.name] = .working
        await GitOperations.abortMerge(in: baseURL)
        states[repo.name] = .pending
    }

    private func cleanup(_ repo: Repository) async {
        let worktreeURL = repo.rootURL
            .appendingPathComponent(workspace.name, isDirectory: true)
        if FileManager.default.fileExists(atPath: worktreeURL.path) {
            try? await GitOperations.removeWorktree(at: worktreeURL, in: repo.rootURL)
        }
        try? await GitOperations.deleteBranch(in: repo.rootURL, branch: workspace.name)
    }

    // MARK: - Helpers

    private func baseWorktreeURL(for repo: Repository) -> URL {
        repo.rootURL.appendingPathComponent(repo.defaultBranch, isDirectory: true)
    }

    private func conflictedPaths(_ state: MergeRepoState) -> [String] {
        if case .conflicted(let paths) = state { return paths }
        return []
    }

    private func copyPrompt(for repo: Repository, paths: [String]) {
        let pathList = paths.joined(separator: ", ")
        let prompt = """
        I'm in the middle of merging branch `\(workspace.name)` into `\(repo.defaultBranch)` in the `\(repo.name)` repo. There are merge conflicts in: \(pathList).

        Please:
        1. Read each conflicted file and the conflict markers it contains.
        2. Understand what each side is trying to accomplish.
        3. Produce a resolved version that incorporates both intents — don't just pick one side unless that's clearly correct.
        4. `git add` each resolved file as you go.
        5. When all conflicts are resolved, `git commit` to complete the merge.

        Run any tests the project has after committing to make sure nothing's broken.
        """
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(prompt, forType: .string)
    }
}
