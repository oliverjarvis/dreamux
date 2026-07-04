import SwiftUI

/// The play/stop · open-services · Run Settings cluster shown on the trailing
/// edge of a workspace-backed row. Feature rows use it directly; plan rows
/// borrow it once their worktree exists, so both surfaces stay in lockstep.
///
/// It derives `isRunning`/`openableNames` from the shared `RunnerManager`, but
/// the four actions are injected — starting runners and opening Run Settings
/// also drive the owning view's selection and switch-notice state, which lives
/// outside this cluster.
struct WorkspaceRunControls: View {
    let workspace: Workspace
    let runners: RunnerManager
    /// Open the workspace's services — `nil` opens everything openable (the
    /// button's primary click), a name opens just that runner (its
    /// press-and-hold menu item).
    let openServices: (_ runnerName: String?) -> Void
    let start: () -> Void
    let stop: () -> Void
    let configure: () -> Void

    var body: some View {
        let isRunning = !runners.runningRunners(onBranch: workspace.name).isEmpty
        let openableNames = runners.openableRunners(for: workspace).map(\.name)
        HStack(spacing: 4) {
            if isRunning, !openableNames.isEmpty {
                Menu {
                    ForEach(openableNames, id: \.self) { name in
                        Button("Open \(name)") { openServices(name) }
                    }
                } label: {
                    Image(systemName: "safari")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(Color.primary.opacity(0.10)))
                } primaryAction: {
                    openServices(nil)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Open \(workspace.name)'s services (hold to pick one)")
            }

            Menu {
                Button("Run Settings…") { configure() }
            } label: {
                Image(systemName: isRunning ? "stop.fill" : "play.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Color.green))
            } primaryAction: {
                isRunning ? stop() : start()
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(isRunning ? "Stop running services on \(workspace.name) (hold for Run Settings)"
                            : "Start \(workspace.name) (hold for Run Settings)")
        }
    }
}
