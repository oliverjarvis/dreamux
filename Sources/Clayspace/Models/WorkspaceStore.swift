import Foundation
import SwiftUI

@MainActor
@Observable
final class WorkspaceStore {
    var workspaces: [Workspace]
    var activeID: UUID? {
        didSet {
            guard oldValue != activeID else { return }
            if let old = oldValue {
                sessions[old]?.didResignVisible()
            }
            if let new = activeID {
                sessions[new]?.didBecomeVisible()
            }
        }
    }

    /// All shells in this store default to running here — typically the
    /// project's root directory, used as a fallback when a workspace
    /// isn't tied to a specific repo's worktree.
    let defaultWorkingDirectory: String?

    /// Per-workspace session, kept alive for the lifetime of the workspace
    /// so the shell process and scrollback survive sidebar switches.
    private var sessions: [UUID: WorkspaceSession] = [:]

    /// Stack of recently-closed workspaces. The shell session is gone (the
    /// PTY was torn down on close), but we keep the metadata so the user
    /// can reopen by name/icon/tint and start a fresh shell.
    private var closedStack: [Workspace] = []
    private let closedStackLimit = 10

    var canReopenClosed: Bool { !closedStack.isEmpty }

    init(defaultWorkingDirectory: String? = nil) {
        self.defaultWorkingDirectory = defaultWorkingDirectory
        // Work items are now created under repos; new projects start
        // empty until the user adds a repository (which auto-seeds a
        // default work item under it).
        self.workspaces = []
        self.activeID = nil
    }

    func session(for workspace: Workspace) -> WorkspaceSession {
        if let existing = sessions[workspace.id] { return existing }
        let session = WorkspaceSession(workspace: workspace)
        sessions[workspace.id] = session
        if workspace.id == activeID {
            session.didBecomeVisible()
        }
        return session
    }

    func hasUnread(for workspace: Workspace) -> Bool {
        sessions[workspace.id]?.anyTabHasUnread ?? false
    }

    func lastActivityMessage(for workspace: Workspace) -> String? {
        sessions[workspace.id]?.lastActivityMessage
    }

    /// Tap the workspace row. Switches to it if not already active;
    /// otherwise dismisses any pending unread badge / activity message
    /// so a click on the currently-visible workspace functions as an
    /// "I see it" acknowledgement.
    func activate(_ workspaceID: UUID) {
        if activeID != workspaceID {
            activeID = workspaceID  // didSet drives the visibility transition
        } else {
            sessions[workspaceID]?.dismissActivity()
        }
    }

    func workspaces(under repo: Repository) -> [Workspace] {
        workspaces.filter { $0.linkedRepoIDs.contains(repo.name) }
    }

    /// Register a feature work item with already-provisioned worktrees
    /// (the actual `git worktree add` and symlink wiring is done by
    /// `FeatureProvisioner` so this method is purely model-side).
    /// The work item's working directory is the `features/<name>/`
    /// aggregation directory.
    @discardableResult
    func registerFeature(
        name: String,
        featureDirectory: URL,
        linkedRepoIDs: [String]
    ) -> Workspace {
        let index = workspaces.count
        let workspace = Workspace(
            name: name,
            symbol: paletteSymbol(for: index),
            tint: paletteColor(for: index),
            workingDirectory: featureDirectory.path,
            linkedRepoIDs: linkedRepoIDs
        )
        workspaces.append(workspace)
        activeID = workspace.id
        return workspace
    }

    /// Free-floating workspace with no repo. Used by ⌘⇧T as a fallback
    /// when there are no repositories and the user just wants a shell
    /// rooted at the project.
    @discardableResult
    func addWorkspace() -> Workspace {
        let index = workspaces.filter { $0.linkedRepoIDs.isEmpty }.count
        let workspace = Workspace(
            name: "Workspace \(index + 1)",
            symbol: paletteSymbol(for: index),
            tint: paletteColor(for: index),
            workingDirectory: defaultWorkingDirectory
        )
        workspaces.append(workspace)
        activeID = workspace.id
        return workspace
    }

    func setIcon(_ symbol: String, for workspaceID: UUID) {
        updateWorkspace(workspaceID) { $0.symbol = symbol }
    }

    func setTint(_ tint: Color, for workspaceID: UUID) {
        updateWorkspace(workspaceID) { $0.tint = tint }
    }

    func setName(_ name: String, for workspaceID: UUID) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        updateWorkspace(workspaceID) { $0.name = trimmed }
    }

    private func updateWorkspace(_ id: UUID, _ mutate: (inout Workspace) -> Void) {
        guard let index = workspaces.firstIndex(where: { $0.id == id }) else { return }
        mutate(&workspaces[index])
        sessions[id]?.workspace = workspaces[index]
    }

    func remove(_ workspace: Workspace) {
        sessions[workspace.id]?.stop()
        sessions.removeValue(forKey: workspace.id)
        workspaces.removeAll { $0.id == workspace.id }
        if activeID == workspace.id {
            // Promote the most recently-added remaining workspace if
            // any; otherwise the window goes empty (handled by the
            // terminal container's empty state).
            activeID = workspaces.last?.id
        }
        closedStack.append(workspace)
        if closedStack.count > closedStackLimit {
            closedStack.removeFirst(closedStack.count - closedStackLimit)
        }
    }

    @discardableResult
    func reopenClosedWorkspace() -> Workspace? {
        guard let last = closedStack.popLast() else { return nil }
        let restored = Workspace(
            name: last.name,
            symbol: last.symbol,
            tint: last.tint,
            workingDirectory: last.workingDirectory,
            linkedRepoIDs: last.linkedRepoIDs
        )
        workspaces.append(restored)
        activeID = restored.id
        return restored
    }

    var activeWorkspace: Workspace? {
        guard let activeID else { return nil }
        return workspaces.first { $0.id == activeID }
    }

    var activeSession: WorkspaceSession? {
        guard let workspace = activeWorkspace else { return nil }
        return session(for: workspace)
    }

    // MARK: - Palette

    private func paletteSymbol(for index: Int) -> String {
        let symbols = [
            "terminal.fill", "circle.grid.3x3.fill", "square.stack.3d.up.fill",
            "bolt.fill", "leaf.fill", "hammer.fill", "wrench.and.screwdriver.fill",
            "shippingbox.fill",
        ]
        return symbols[index % symbols.count]
    }

    private func paletteColor(for index: Int) -> Color {
        let palette: [Color] = [
            .blue, .purple, .orange, .pink, .green, .teal, .indigo, .red,
        ]
        return palette[index % palette.count]
    }
}
