import Foundation
import SwiftUI

@MainActor
@Observable
final class WorkspaceStore {
    var workspaces: [Workspace]
    var activeID: UUID {
        didSet {
            guard oldValue != activeID else { return }
            sessions[oldValue]?.didResignVisible()
            sessions[activeID]?.didBecomeVisible()
        }
    }

    /// All shells in this store default to running here — typically the
    /// project's root directory, so opening a tab drops you straight into
    /// the project's folder.
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
        let initial = [
            Workspace(name: "Home", symbol: "house.fill", tint: .blue,
                      workingDirectory: defaultWorkingDirectory),
            Workspace(name: "Code", symbol: "chevron.left.forwardslash.chevron.right", tint: .purple,
                      workingDirectory: defaultWorkingDirectory),
            Workspace(name: "Logs", symbol: "doc.text.magnifyingglass", tint: .orange,
                      workingDirectory: defaultWorkingDirectory),
        ]
        self.workspaces = initial
        self.activeID = initial[0].id
    }

    func session(for workspace: Workspace) -> WorkspaceSession {
        if let existing = sessions[workspace.id] { return existing }
        let session = WorkspaceSession(workspace: workspace)
        sessions[workspace.id] = session
        // Match initial visibility — the first workspace's session is
        // visible from the moment it's created if it matches activeID.
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

    func addWorkspace() {
        let palette: [Color] = [.blue, .purple, .orange, .pink, .green, .teal, .indigo, .red]
        let symbols = ["terminal.fill", "circle.grid.3x3.fill", "square.stack.3d.up.fill", "globe", "bolt.fill", "leaf.fill"]
        let index = workspaces.count
        let workspace = Workspace(
            name: "Workspace \(index + 1)",
            symbol: symbols[index % symbols.count],
            tint: palette[index % palette.count],
            workingDirectory: defaultWorkingDirectory
        )
        workspaces.append(workspace)
        activeID = workspace.id
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
        // Mirror the change into the live session so menu-bar titles,
        // notifications, etc. read the new value.
        sessions[id]?.workspace = workspaces[index]
    }

    func remove(_ workspace: Workspace) {
        guard workspaces.count > 1 else { return }
        sessions[workspace.id]?.stop()
        sessions.removeValue(forKey: workspace.id)
        workspaces.removeAll { $0.id == workspace.id }
        if activeID == workspace.id, let first = workspaces.first {
            activeID = first.id
        }
        closedStack.append(workspace)
        if closedStack.count > closedStackLimit {
            closedStack.removeFirst(closedStack.count - closedStackLimit)
        }
    }

    @discardableResult
    func reopenClosedWorkspace() -> Workspace? {
        guard let last = closedStack.popLast() else { return nil }
        // Mint a fresh id so the new session map entry can't collide with a
        // stale one if the user reopens, closes, and reopens again.
        let restored = Workspace(
            name: last.name,
            symbol: last.symbol,
            tint: last.tint,
            workingDirectory: last.workingDirectory
        )
        workspaces.append(restored)
        activeID = restored.id
        return restored
    }

    var activeWorkspace: Workspace? {
        workspaces.first { $0.id == activeID }
    }

    var activeSession: WorkspaceSession? {
        guard let workspace = activeWorkspace else { return nil }
        return session(for: workspace)
    }
}
