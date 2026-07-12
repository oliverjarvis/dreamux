import SwiftUI
import AppKit

struct MergeFeatureSheet: View {
    /// Opens a new tab in the workspace at the given absolute path,
    /// with a tab title indicating the conflict.
    let onOpenConflictTab: (URL, String) -> Void
    let onDismiss: () -> Void
    /// True when the sheet was opened from the gate card's "Create PR"
    /// button rather than "Merge locally"/"Merge & continue" — swaps
    /// which button per row reads as prominent: the publish button
    /// instead of the local Merge/Commit & Merge buttons.
    var emphasizePublish: Bool = false

    /// Every decision and git sequence lives in the flow, which is
    /// shared with the e2e automation server's `mergeFeature` /
    /// `cleanupFeature` commands and the `MergeFlowTests` suite — this
    /// view only renders states and forwards clicks. A fresh flow is
    /// created per presentation (`.sheet(item:)` gives the view new
    /// identity each open), preserving the old reset-on-open behavior.
    @State private var flow: MergeFlow
    @State private var pollTask: Task<Void, Never>?

    /// `onRepoCleanedUp` fires after each repo reaches `.cleanedUp` —
    /// the parent stops runners on the just-removed worktree.
    /// `onAllCleanedUp` fires once when every repo is cleaned up — the
    /// parent drops the workspace, removes `features/<name>/`, and
    /// dismisses the sheet.
    init(
        workspace: Workspace,
        repos: [Repository],
        project: Project,
        onOpenConflictTab: @escaping (URL, String) -> Void,
        onRepoCleanedUp: @escaping (Repository) -> Void = { _ in },
        onAllCleanedUp: @escaping () -> Void = {},
        onDismiss: @escaping () -> Void,
        emphasizePublish: Bool = false
    ) {
        self.onOpenConflictTab = onOpenConflictTab
        self.onDismiss = onDismiss
        self.emphasizePublish = emphasizePublish
        _flow = State(initialValue: MergeFlow(
            workspace: workspace,
            repos: repos,
            project: project,
            onRepoCleanedUp: onRepoCleanedUp,
            onAllCleanedUp: onAllCleanedUp
        ))
    }

    private var workspace: Workspace { flow.workspace }
    private var repos: [Repository] { flow.repos }

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
                    Task { await flow.mergeAllPending() }
                } label: {
                    if flow.isBatchRunning {
                        HStack {
                            ProgressView().controlSize(.small)
                            Text("Merging…")
                        }
                    } else {
                        Text("Merge All Pending")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(flow.isBatchRunning || !flow.hasPending)

                Spacer()

                Button("Done", action: onDismiss)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 540)
        .onAppear {
            Task {
                await flow.initializeStates()
                startPolling()
            }
        }
        .onDisappear { pollTask?.cancel() }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Merge \(workspace.name)")
                .font(.title3.weight(.semibold))
            Text("Merge \(workspace.name) into each repo's default branch locally, or push it to origin as a pull request. The feature branch and worktree stay until you clean up — for PRs, cleanup unlocks once the PR merges.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Per-repo row

    @ViewBuilder
    private func repoRow(_ repo: Repository) -> some View {
        let state = flow.state(for: repo)
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
            } else if state == .featureDirty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(repo.name)/\(workspace.name) has uncommitted changes. Commit & Merge will run `git add -A && git commit -m \"\(workspace.name)\"` in the feature worktree, then merge.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let error = flow.commitErrors[repo.name] {
                        Text(error)
                            .font(.caption2)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            if case .working = state, !(flow.liveOutput[repo.name]?.isEmpty ?? true) {
                liveOutputView(for: repo)
            } else if case .cleaningUp = state, !(flow.liveOutput[repo.name]?.isEmpty ?? true) {
                liveOutputView(for: repo)
            } else if case .pushing = state, !(flow.liveOutput[repo.name]?.isEmpty ?? true) {
                liveOutputView(for: repo)
            }

            HStack(spacing: 8) {
                if state == .working || state == .cleaningUp || state == .pushing {
                    Button("Cancel") { flow.cancel(repo) }
                        .buttonStyle(.bordered)
                }
                if state.canMerge {
                    Button("Merge") {
                        Task { await flow.runMerge(for: repo) }
                    }
                    .buttonStyle(.bordered)
                    publishButton(repo, title: "Create PR", state: state)
                }
                if let url = state.prURL {
                    Button("View PR") {
                        if let parsed = URL(string: url) {
                            NSWorkspace.shared.open(parsed)
                        }
                    }
                    .buttonStyle(.bordered)
                }
                if state == .featureDirty {
                    if emphasizePublish {
                        Button("Commit & Merge") {
                            Task { await flow.commitAndMerge(repo) }
                        }
                        .buttonStyle(.bordered)
                    } else {
                        Button("Commit & Merge") {
                            Task { await flow.commitAndMerge(repo) }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    publishButton(repo, title: "Commit & Create PR", state: state)
                    Button("Open in Terminal") {
                        let url = flow.featureWorktreeURL(for: repo)
                        onOpenConflictTab(url, "\(repo.name) commit")
                    }
                    .buttonStyle(.bordered)
                }
                if case .conflicted = state {
                    Button("Open in Terminal") {
                        let path = flow.baseWorktreeURL(for: repo)
                        onOpenConflictTab(path, "\(repo.name) merge")
                    }
                    .buttonStyle(.bordered)
                    Button("Copy Resolution Prompt") {
                        copyPrompt(for: repo, paths: conflictedPaths(state))
                    }
                    .buttonStyle(.bordered)
                    Button("Abort Merge") {
                        Task { await flow.abortMerge(for: repo) }
                    }
                    .buttonStyle(.bordered)
                }
                if state.canCleanup {
                    Button("Cleanup Worktree & Branch") {
                        Task { await flow.cleanup(repo) }
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

    /// "Create PR" (or its Commit & variant), shaped by the repo's
    /// publish availability: hidden when there's no remote to push to,
    /// disabled with an install hint when gh is missing, live
    /// otherwise. Hidden-vs-disabled is deliberate — no remote means
    /// the option can never apply, while a missing CLI is fixable.
    @ViewBuilder
    private func publishButton(_ repo: Repository, title: String, state: MergeRepoState) -> some View {
        switch flow.publishAvailability[repo.name] {
        case .available:
            if emphasizePublish {
                Button(title) {
                    Task {
                        if state == .featureDirty {
                            await flow.commitAndPublish(repo)
                        } else {
                            await flow.publish(repo)
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .help("Push \(workspace.name) to origin and open a pull request against \(repo.defaultBranch)")
            } else {
                Button(title) {
                    Task {
                        if state == .featureDirty {
                            await flow.commitAndPublish(repo)
                        } else {
                            await flow.publish(repo)
                        }
                    }
                }
                .buttonStyle(.bordered)
                .help("Push \(workspace.name) to origin and open a pull request against \(repo.defaultBranch)")
            }
        case .ghMissing:
            Button(title) {}
                .buttonStyle(.bordered)
                .disabled(true)
                .help("Install the GitHub CLI (`brew install gh`, then `gh auth login`) to create PRs from Dreamux.")
        case .noRemote, nil:
            EmptyView()
        }
    }

    /// Last few lines of git output for an in-flight operation. We show
    /// it as a monospaced, lightly-tinted strip directly under the row
    /// so a hung-feeling merge becomes visibly active (`Counting objects:
    /// 4/12`, `add file: …`) rather than just spinning.
    @ViewBuilder
    private func liveOutputView(for repo: Repository) -> some View {
        let lines = flow.liveOutput[repo.name] ?? []
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(0.05))
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
            Text("Worktree: \(flow.baseWorktreeURL(for: repo).path)")
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
            Label("Nothing to merge", systemImage: "checkmark.seal.fill")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        case .featureDirty:
            Label("Uncommitted changes", systemImage: "exclamationmark.triangle.fill")
                .font(.caption.weight(.medium))
                .foregroundStyle(.orange)
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
        case .cleaningUp:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Cleaning up…").font(.caption)
            }
        case .cleanedUp:
            Label("Cleaned up", systemImage: "trash")
                .font(.caption.weight(.medium))
                .foregroundStyle(.tertiary)
        case .pushing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Pushing…").font(.caption)
            }
        case .prOpen:
            Label("PR open", systemImage: "arrow.triangle.pull")
                .font(.caption.weight(.medium))
                .foregroundStyle(.blue)
        case .prMerged:
            Label("PR merged", systemImage: "checkmark.seal.fill")
                .font(.caption.weight(.medium))
                .foregroundStyle(.green)
        }
    }

    // MARK: - Polling

    /// Poll every ~2.5s while the sheet is open, delegating the actual
    /// probing to the flow. The timer lives here rather than in the
    /// flow because its lifetime is a presentation concern: it should
    /// run exactly as long as the sheet is on screen.
    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(2500))
                if Task.isCancelled { return }
                await flow.pollConflictedRepos()
            }
        }
    }

    // MARK: - Helpers

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
