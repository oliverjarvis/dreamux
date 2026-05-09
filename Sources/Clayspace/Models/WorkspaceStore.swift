import Foundation
import SwiftUI

@MainActor
@Observable
final class WorkspaceStore {
    var workspaces: [Workspace]
    var activeID: UUID

    /// Per-workspace session, kept alive for the lifetime of the workspace
    /// so the shell process and scrollback survive sidebar switches.
    private var sessions: [UUID: WorkspaceSession] = [:]

    init() {
        let initial = [
            Workspace(name: "Home", symbol: "house.fill", tint: .blue),
            Workspace(name: "Code", symbol: "chevron.left.forwardslash.chevron.right", tint: .purple),
            Workspace(name: "Logs", symbol: "doc.text.magnifyingglass", tint: .orange),
        ]
        self.workspaces = initial
        self.activeID = initial[0].id
    }

    func session(for workspace: Workspace) -> WorkspaceSession {
        if let existing = sessions[workspace.id] { return existing }
        let session = WorkspaceSession(workspace: workspace)
        sessions[workspace.id] = session
        return session
    }

    func addWorkspace() {
        let palette: [Color] = [.blue, .purple, .orange, .pink, .green, .teal, .indigo, .red]
        let symbols = ["terminal.fill", "circle.grid.3x3.fill", "square.stack.3d.up.fill", "globe", "bolt.fill", "leaf.fill"]
        let index = workspaces.count
        let workspace = Workspace(
            name: "Workspace \(index + 1)",
            symbol: symbols[index % symbols.count],
            tint: palette[index % palette.count]
        )
        workspaces.append(workspace)
        activeID = workspace.id
    }

    func remove(_ workspace: Workspace) {
        guard workspaces.count > 1 else { return }
        sessions[workspace.id]?.stop()
        sessions.removeValue(forKey: workspace.id)
        workspaces.removeAll { $0.id == workspace.id }
        if activeID == workspace.id, let first = workspaces.first {
            activeID = first.id
        }
    }

    var activeWorkspace: Workspace? {
        workspaces.first { $0.id == activeID }
    }

    var activeSession: WorkspaceSession? {
        guard let workspace = activeWorkspace else { return nil }
        return session(for: workspace)
    }
}
