import Foundation
import SwiftUI

/// A feature the user is working on. Maps to:
///   - one branch name (== `name`) created in each linked repo,
///   - one worktree per linked repo at `repos/<repo>/<name>/`,
///   - a `features/<name>/` aggregation directory whose symlinks point
///     to those worktrees,
/// so the agent can `cd` into one place and see all repos involved.
struct Workspace: Identifiable, Hashable {
    let id: UUID
    var name: String
    var symbol: String
    var tint: Color
    /// Path the tab terminals cd into. For features this is the
    /// `features/<name>/` aggregation directory; for orphan workspaces
    /// it falls back to the project root.
    var workingDirectory: String?
    /// Names (== folder names under `repos/`) of repositories this
    /// feature spans. Empty for an orphan workspace with no associated
    /// repos.
    var linkedRepoIDs: [String]
    /// The reserved main-branch workspace — permanent, excluded from
    /// feature machinery; see WorkspaceStore.mainWorkspace.
    var isMain: Bool

    init(
        id: UUID = UUID(),
        name: String,
        symbol: String = "terminal.fill",
        tint: Color = .accentColor,
        workingDirectory: String? = nil,
        linkedRepoIDs: [String] = [],
        isMain: Bool = false
    ) {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.tint = tint
        self.workingDirectory = workingDirectory
        self.linkedRepoIDs = linkedRepoIDs
        self.isMain = isMain
    }
}
