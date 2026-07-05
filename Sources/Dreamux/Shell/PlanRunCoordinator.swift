import Foundation

enum PlanRunError: LocalizedError {
    case notAPlan
    case noRepositories

    var errorDescription: String? {
        switch self {
        case .notAPlan: return "Only plan documents can be run."
        case .noRepositories: return "Pick at least one repository to run the plan in."
        }
    }
}

/// Executes a plan: provision (or resume) the feature worktrees, record
/// the plan↔feature link, open a terminal tab in the feature, and type
/// the claude invocation. Shared by the sidebar's Run Plan sheet and
/// the e2e `runPlan` command so both paths are the same code.
@MainActor
final class PlanRunCoordinator {
    private let project: Project
    private let workspaceStore: WorkspaceStore
    private let repoStore: RepoStore
    private let docStore: DocStore

    /// Injectable for tests (capture prompts without a PTY).
    var sendPrompt: (String, TabSession) -> Void = { prompt, session in
        ClaudePromptDriver.send(prompt, into: session)
    }

    init(project: Project, workspaceStore: WorkspaceStore,
         repoStore: RepoStore, docStore: DocStore) {
        self.project = project
        self.workspaceStore = workspaceStore
        self.repoStore = repoStore
        self.docStore = docStore
    }

    /// Run (or resume) `doc` as feature `branchName` across `repoNames`.
    @discardableResult
    func runPlan(_ doc: PlanDoc, branchName: String, repoNames: [String]) async throws -> Workspace {
        guard doc.kind == .plan else { throw PlanRunError.notAPlan }
        let repos = repoStore.repositories.filter { repoNames.contains($0.name) }
        guard !repos.isEmpty else { throw PlanRunError.noRepositories }

        let planPath = docStore.relativePath(of: doc)
        let existing = docStore.ledger.recordForPlan(planPath)
        let isResume = existing?.featureName == branchName
            && workspaceStore.workspaces.contains { $0.name == branchName }

        let featureDir: URL
        if isResume {
            featureDir = FeatureProvisioner.featureDirectory(in: project, name: branchName)
        } else {
            featureDir = try await FeatureProvisioner.provision(
                featureName: branchName, in: project, across: repos)
        }

        let workspace = workspaceStore.registerFeature(
            name: branchName,
            featureDirectory: featureDir,
            linkedRepoIDs: repos.map(\.name))
        docStore.ledger.record(planPath: planPath, featureName: branchName)

        let docsLink = FeatureProvisioner.docsLinkName(repoNames: repos.map(\.name))
        // Inside the feature dir the docs home is reachable via the
        // symlink; rewrite the leading "docs/" when the link is renamed.
        let pathInFeature = docsLink == "docs"
            ? planPath
            : planPath.replacingOccurrences(of: "docs/", with: "\(docsLink)/",
                                            options: .anchored)
        let autoCommit = WorkflowSettings.autoCommitEnabled
        let prompt = isResume
            ? PlanPrompts.resumePlan(
                planRelativePath: pathInFeature, docsLinkName: docsLink,
                autoCommit: autoCommit)
            : PlanPrompts.runPlan(
                planRelativePath: pathInFeature, docsLinkName: docsLink,
                autoCommit: autoCommit)

        let session = workspaceStore.session(for: workspace)
        // Install where the agent runs (the feature dir — Claude Code
        // reads `.mcp.json` from its cwd) but scope signals to the
        // project ROOT: that's what ProjectSession tags every signal
        // with, so anything else leaves the agent reading and writing
        // a project_dir no signal ever matches.
        MCPInstaller.installIfNeeded(
            at: featureDir.path, projectScope: project.rootPath.path)
        if let tab = session.openPlanAgentTab(
            at: featureDir.path,
            title: "plan: \(branchName)",
            icon: "text.badge.checkmark") {
            tab.startIfNeeded()
            sendPrompt(prompt, tab)
        }
        return workspace
    }
}
