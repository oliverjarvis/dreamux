import Foundation
import SwiftUI
import CryptoKit

@MainActor
@Observable
final class WorkspaceStore {
    var workspaces: [Workspace]
    /// Per-project sidebar arrangement. Set by the window at startup;
    /// drives feature ordering on reload and persistence on drag-reorder.
    var layout: SidebarLayoutStore?
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

    /// Flips true once `reloadFeatures(in:repoStore:)` has completed at
    /// least once. `workspaces` is empty (and every feature name is
    /// therefore "unknown") until then, so callers that need the real
    /// feature set — ledger reconciliation, the plan queue's poller —
    /// must wait for this rather than racing the async discovery.
    private(set) var didLoadFeatures = false

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
    /// aggregation directory. The id is deterministic (derived from
    /// the feature name) so a relaunch picks up the same workspace.
    @discardableResult
    func registerFeature(
        name: String,
        featureDirectory: URL,
        linkedRepoIDs: [String]
    ) -> Workspace {
        let id = Self.stableUUID(forFeature: name)
        // If we already have it (e.g., a relaunch-time discovery raced
        // with a fresh user-driven creation), update in place.
        if let existing = workspaces.firstIndex(where: { $0.id == id }) {
            workspaces[existing].workingDirectory = featureDirectory.path
            workspaces[existing].linkedRepoIDs = linkedRepoIDs
            sessions[id]?.workspace = workspaces[existing]
            activeID = id
            return workspaces[existing]
        }
        let workspace = Workspace(
            id: id,
            name: name,
            symbol: Self.stableSymbol(for: name),
            tint: Self.stableColor(for: name),
            workingDirectory: featureDirectory.path,
            linkedRepoIDs: linkedRepoIDs
        )
        workspaces.append(workspace)
        activeID = workspace.id
        return workspace
    }

    /// Rebuild the feature list from on-disk worktree state. Branch
    /// names that appear as worktrees in one or more repos become
    /// features; same-named branches across repos collapse into one
    /// feature whose `linkedRepoIDs` is the union of those repos.
    /// Orphan (no-repo) workspaces are preserved.
    func reloadFeatures(in project: Project, repoStore: RepoStore) async {
        let mapping = await repoStore.discoverFeatures()

        var discovered: [Workspace] = []
        for (name, linkedRepos) in mapping.sorted(by: { $0.key < $1.key }) {
            let dir = await FeatureProvisioner.ensureFeatureDirectory(
                featureName: name,
                in: project,
                across: linkedRepos
            )
            // Preserve any in-memory customizations (symbol/tint/name) if
            // the user already had this feature visible — same id, so we
            // can look it up.
            let id = Self.stableUUID(forFeature: name)
            let existing = workspaces.first { $0.id == id }
            let workspace = Workspace(
                id: id,
                name: existing?.name ?? name,
                symbol: existing?.symbol ?? Self.stableSymbol(for: name),
                tint: existing?.tint ?? Self.stableColor(for: name),
                workingDirectory: dir.path,
                linkedRepoIDs: linkedRepos.map(\.name)
            )
            discovered.append(workspace)
        }

        // Keep orphan workspaces (no linked repos) — they're transient
        // shells the user opened that don't correspond to any worktree.
        let orphans = workspaces.filter { $0.linkedRepoIDs.isEmpty }
        let ordered = layout?.ordered(discovered) ?? discovered
        let merged = ordered + orphans
        workspaces = merged

        // Sync active session metadata for survivors.
        for workspace in merged {
            sessions[workspace.id]?.workspace = workspace
        }

        // Reset activeID if it pointed to a now-gone workspace.
        if let activeID, !workspaces.contains(where: { $0.id == activeID }) {
            self.activeID = workspaces.first?.id
        } else if activeID == nil {
            activeID = workspaces.first?.id
        }

        didLoadFeatures = true
    }

    /// Persist the current feature order after a drag-reorder. Only
    /// linked features are recorded; orphan shells stay session-only and
    /// always render after the linked features.
    func persistFeatureOrder() {
        layout?.setFeatureOrder(workspaces.filter { !$0.linkedRepoIDs.isEmpty }.map(\.name))
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
        Self.colorPalette[index % Self.colorPalette.count]
    }

    private static let symbolPalette: [String] = [
        "terminal.fill", "circle.grid.3x3.fill", "square.stack.3d.up.fill",
        "bolt.fill", "leaf.fill", "hammer.fill", "wrench.and.screwdriver.fill",
        "shippingbox.fill",
    ]

    private static let colorPalette: [Color] = [
        .blue, .purple, .orange, .pink, .green, .teal, .indigo, .red,
    ]

    /// Stable hash → palette index, so a feature keeps the same icon
    /// and tint across relaunches even though we don't persist
    /// per-feature customizations yet.
    private static func paletteIndex(for name: String) -> Int {
        let digest = SHA256.hash(data: Data(name.utf8))
        let firstByte = Array(digest).first.map(Int.init) ?? 0
        return firstByte
    }

    static func stableSymbol(for name: String) -> String {
        symbolPalette[paletteIndex(for: name) % symbolPalette.count]
    }

    static func stableColor(for name: String) -> Color {
        colorPalette[paletteIndex(for: name) % colorPalette.count]
    }

    /// Deterministic UUID derived from the feature name — same name in
    /// the same project always maps to the same UUID, so relaunch-time
    /// rediscovery doesn't churn the in-memory session map.
    static func stableUUID(forFeature name: String) -> UUID {
        let digest = SHA256.hash(data: Data(name.utf8))
        var bytes = Array(digest.prefix(16))
        // Mark as RFC 4122 v5 + variant 1 so other code that introspects
        // the UUID gets a well-formed value.
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0],  bytes[1],  bytes[2],  bytes[3],
            bytes[4],  bytes[5],  bytes[6],  bytes[7],
            bytes[8],  bytes[9],  bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}
