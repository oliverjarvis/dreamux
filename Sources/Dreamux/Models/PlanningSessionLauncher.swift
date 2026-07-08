import SwiftUI

/// One planning terminal per project, cwd at the project root where
/// `repos/<repo>/<default>/` checkouts and `docs/` are visible. Reuses the
/// existing tab when it's still open; the kickoff prompt is typed via the
/// shared driver either way.
///
/// Shared verbatim between `WorkspaceSidebar`'s `+` New Plan flow and the
/// Overview's Mode B "Plan something here" so the two entry points can't
/// drift — the same reasoning `FlowGateActions` is passed unchanged
/// between the Overview and the Flows page.
@MainActor
enum PlanningSessionLauncher {
    /// `buildPrompt` receives the intake digest (nil on a project with no
    /// plans in flight) and returns the kickoff text. The digest is
    /// assembled *after* the `docStore.refresh()` below so it reflects the
    /// freshest inventory at send time; the driver's own quiescence gate
    /// (`ClaudePromptDriver.send`) is left entirely untouched.
    static func open(
        store: WorkspaceStore,
        repoStore: RepoStore,
        docStore: DocStore,
        planQueue: PlanQueueController,
        sidebarMode: Binding<SidebarMode>,
        buildPrompt: @escaping (String?) -> String
    ) {
        let workspace = store.activeWorkspace ?? store.workspaces.first ?? store.addWorkspace()
        store.activate(workspace.id)
        sidebarMode.wrappedValue = .workspace
        let session = store.session(for: workspace)
        DocStore.ensureDocsHome(at: repoStore.project.rootPath)
        docStore.refresh()
        MCPInstaller.installIfNeeded(at: repoStore.project.rootPath.path)
        guard let tab = session.reuseOrOpenPlanningTab(
            at: repoStore.project.rootPath.path) else { return }
        tab.startIfNeeded()
        Task {
            let prompt = buildPrompt(await intakeDigest(
                store: store, repoStore: repoStore, docStore: docStore, planQueue: planQueue))
            ClaudePromptDriver.send(prompt, into: tab)
        }
    }

    /// Assemble the intake digest for a kickoff prompt, or nil when the
    /// project has no non-merged plans (the prompt then reproduces its
    /// pre-intake form). Reads the live `DocStore` inventory and, for
    /// running plans, worktree territory via `IntakeDigest.build`
    /// (`<repoRoot>/<feature>` per repo, diffed against each repo's
    /// default branch).
    private static func intakeDigest(
        store: WorkspaceStore, repoStore: RepoStore, docStore: DocStore, planQueue: PlanQueueController
    ) async -> String? {
        let featureExists: (String) -> Bool = { name in
            store.featureNames.contains(name)
        }
        guard docStore.plans.contains(where: {
            docStore.status(for: $0, featureExists: featureExists) != .merged
        }) else { return nil }
        return await IntakeDigest.build(
            docStore: docStore,
            repos: repoStore.repositories,
            queue: planQueue.entries,
            featureExists: featureExists)
    }
}
