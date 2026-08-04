import SwiftUI

/// The one door every fired idea goes through — ⌘P's New idea sheet, the
/// Overview's Mode B "Plan something here", the spec→plan kickoff, and the
/// bottom composer's **Idea** target. Ensures the docs home, refreshes the
/// `DocStore`, installs the MCP, builds the intake digest, and sends the
/// kickoff.
///
/// The decisive difference from the `PlanningSessionLauncher` it replaces:
/// **it never reuses a session.** That launcher re-selected the workspace's
/// one planning tab, so a second idea fired while the first conversation
/// was live typed `claude "$(cat …)"` — a SHELL COMMAND — into a running
/// agent's REPL, where it landed as a chat message and the second idea was
/// eaten. Here every fire opens a brand-new agent tab.
///
/// Sessions live as tabs in `main` (spec: Decisions §3), not in a reserved
/// "Ideas" workspace and not in whatever workspace happens to be active:
/// `main`'s working directory already IS the project root, which is exactly
/// the cwd an intake session needs to see `docs/` and `repos/`.
@MainActor
final class IdeaIntakeLauncher {
    /// Injectable for tests (capture prompts without a PTY) — the same
    /// seam `PlanRunCoordinator.sendPrompt` uses.
    var sendPrompt: (String, TabSession) -> Void = { prompt, session in
        // The tab is always fresh, so the gate can't refuse — but log if it
        // ever does rather than dropping a kickoff in silence.
        if !ClaudePromptDriver.send(prompt, into: session) {
            NSLog("IdeaIntakeLauncher: delivery refused on a freshly opened tab")
        }
    }

    /// Fire one idea. `title` names the tab; `buildPrompt` receives the
    /// intake digest (nil when there is nothing in flight at all) and
    /// returns the kickoff text.
    ///
    /// `title` rather than `idea` because the launcher serves two kickoffs:
    /// the idea-intake callers pass `IdeaTitle.tabTitle(for: idea)`, and the
    /// spec→plan path (`PlanPrompts.writePlanKickoff`) passes
    /// `"plan: <spec name>"`.
    func fire(
        title: String,
        store: WorkspaceStore,
        repoStore: RepoStore,
        docStore: DocStore,
        planQueue: PlanQueueController,
        sidebarMode: Binding<SidebarMode>,
        buildPrompt: @escaping (String?) -> String
    ) {
        // Find-or-create `main` — the same call `openMainWorkspace` makes.
        // It does no git work, so this stays cheap.
        let workspace = store.mainWorkspace(
            name: repoStore.repositories.first?.defaultBranch ?? "main",
            workingDirectory: repoStore.project.rootPath.path,
            linkedRepoIDs: repoStore.repositories.map(\.name))
        store.activate(workspace.id)
        sidebarMode.wrappedValue = .workspace

        let session = store.session(for: workspace)
        let projectRoot = repoStore.project.rootPath
        DocStore.ensureDocsHome(at: projectRoot)
        docStore.refresh()
        MCPInstaller.installIfNeeded(at: projectRoot.path)

        // Read siblings BEFORE opening this fire's tab, so a session is
        // never named in its own digest.
        let siblings = session.intakeTabTitles

        guard let tab = session.openAgentTab(
            at: projectRoot.path, title: title, icon: "lightbulb") else { return }
        if let id = session.lastCreatedTabID {
            session.registerIntakeTab(id)
        }
        tab.startIfNeeded()

        Task { [weak self] in
            guard let self else { return }
            let prompt = buildPrompt(await Self.intakeDigest(
                store: store, repoStore: repoStore, docStore: docStore,
                planQueue: planQueue, liveIntakeSessions: siblings))
            self.sendPrompt(prompt, tab)
        }
    }

    /// Assemble the intake digest for a kickoff prompt, or nil when there is
    /// nothing in flight at all — no non-merged plan AND no sibling session
    /// (the prompt then reproduces its pre-intake form). Reads the live
    /// `DocStore` inventory and, for running plans, worktree territory via
    /// `IntakeDigest.build`. Assembled AFTER `docStore.refresh()` above so it
    /// reflects the freshest inventory at send time.
    private static func intakeDigest(
        store: WorkspaceStore,
        repoStore: RepoStore,
        docStore: DocStore,
        planQueue: PlanQueueController,
        liveIntakeSessions: [String]
    ) async -> String? {
        let featureExists: (String) -> Bool = { name in
            store.featureNames.contains(name)
        }
        let hasUnmergedPlan = docStore.plans.contains {
            docStore.status(for: $0, featureExists: featureExists) != .merged
        }
        guard hasUnmergedPlan || !liveIntakeSessions.isEmpty else { return nil }
        return await IntakeDigest.build(
            docStore: docStore,
            repos: repoStore.repositories,
            queue: planQueue.entries,
            featureExists: featureExists,
            liveIntakeSessions: liveIntakeSessions)
    }
}
