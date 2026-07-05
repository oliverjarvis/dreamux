import SwiftUI

/// The context header's run cluster: a play/stop capsule and a services
/// popover, sitting left of the git chip. Status derives from the
/// shared `RunnerManager` (via the tested aggregation in
/// RunnerHeaderState.swift); actions that navigate — starting the scope
/// (which may need the Run pane), editing run config, jumping to
/// Signals — are injected because they drive `sidebarMode`, which the
/// owning view controls. Mirrors `WorkspaceRunControls`' split.
struct HeaderRunControls: View {
    let workspace: Workspace
    let runners: RunnerManager
    let start: () -> Void
    let stop: () -> Void
    let openRunPane: () -> Void
    let showLogs: (_ runnerName: String) -> Void

    @State private var showServices = false
    @State private var hoveredRowID: String?

    var body: some View {
        let summary = runners.headerSummary(for: workspace)
        HStack(spacing: 2) {
            playCapsule(summary)
            if summary.hasConfig {
                chevronButton
            }
        }
        .popover(isPresented: $showServices, arrowEdge: .bottom) {
            servicesPopover
        }
    }

    // MARK: - Capsule

    private func playCapsule(_ summary: HeaderRunSummary) -> some View {
        Button {
            if !summary.hasConfig {
                openRunPane()
            } else if summary.runningCount > 0 {
                stop()
            } else {
                start()
            }
        } label: {
            HStack(spacing: 5) {
                if summary.runningCount > 0 {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 6))
                        .foregroundStyle(summary.attention ? Color.orange : Color.green)
                        .symbolEffect(.pulse)
                    Image(systemName: "stop.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text("\(summary.runningCount) running")
                        .foregroundStyle(.secondary)
                } else {
                    if summary.attention {
                        Image(systemName: "circle.fill")
                            .font(.system(size: 6))
                            .foregroundStyle(Color.orange)
                    }
                    Image(systemName: "play.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 11))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.primary.opacity(0.05)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(playHelp(summary))
    }

    private func playHelp(_ summary: HeaderRunSummary) -> String {
        if !summary.hasConfig { return "Set up run configuration" }
        if summary.runningCount > 0 { return "Stop \(workspace.name)'s services" }
        return "Start \(workspace.name)'s services"
    }

    private var chevronButton: some View {
        Button {
            showServices.toggle()
        } label: {
            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.tertiary)
                .frame(width: 16, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Services")
    }

    // MARK: - Popover

    private var servicesPopover: some View {
        let active = runners.serviceRows(for: workspace)
        let other = runners.otherWorktreeRows(excluding: workspace)
        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(active) { row in
                    serviceRow(row, inScope: true)
                }
            }
            .padding(8)

            if !other.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 2) {
                    Text("Other worktrees")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 6)
                        .padding(.top, 4)
                    ForEach(other) { row in
                        serviceRow(row, inScope: false)
                    }
                }
                .padding(8)
            }

            Divider()
            footer
        }
        .frame(width: 320)
    }

    /// One service line: status dot · name · (branch when out of scope)
    /// · port, with hover-revealed actions. In-scope rows get the full
    /// set (open/logs/restart/stop-or-start); other-worktree rows only
    /// open/logs/stop — restarting or starting them belongs to *their*
    /// workspace's play button.
    private func serviceRow(_ row: HeaderServiceRow, inScope: Bool) -> some View {
        let hovered = hoveredRowID == row.id
        return HStack(spacing: 8) {
            Circle()
                .fill(statusColor(row.status))
                .frame(width: 7, height: 7)

            Text(row.runner.name)
                .font(.callout.weight(.medium))
                .lineLimit(1)

            if !inScope {
                Text(row.branch)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            if let port = row.port {
                Text(":\(String(port))")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            if hovered {
                rowActions(row, inScope: inScope)
            }
        }
        .padding(.horizontal, 6)
        .frame(height: 28)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(hovered ? Color.primary.opacity(0.06) : .clear))
        .onHover { inside in
            if inside {
                hoveredRowID = row.id
            } else if hoveredRowID == row.id {
                hoveredRowID = nil
            }
        }
        .help(rowHelp(row))
    }

    @ViewBuilder
    private func rowActions(_ row: HeaderServiceRow, inScope: Bool) -> some View {
        HStack(spacing: 6) {
            if runners.canOpen(row.runner) {
                iconButton("safari", help: "Open in browser") {
                    runners.openNow(row.runner, on: row.branch)
                }
            }
            iconButton("waveform.path.ecg", help: "View logs in Signals") {
                showServices = false
                showLogs(row.runner.name)
            }
            if row.status.isRunning {
                if inScope {
                    iconButton("arrow.clockwise", help: "Restart") {
                        Task { await runners.restart(row.runner, on: row.branch) }
                    }
                }
                iconButton("stop.fill", help: "Stop") {
                    runners.stop(row.runner, on: row.branch)
                }
            } else if inScope {
                iconButton("play.fill", help: "Start") {
                    // Pin the runner to this workspace's worktree first —
                    // a single-row start must not launch on whatever
                    // branch a previous session left active.
                    runners.setActiveBranch(workspace.name, for: row.runner)
                    runners.start(row.runner)
                }
            }
        }
    }

    private func iconButton(
        _ symbol: String, help: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func statusColor(_ status: RunnerStatus) -> Color {
        switch status {
        case .running:
            return .green
        case .failed:
            return .orange
        case .exited(let code):
            return code == 0 ? Color.secondary.opacity(0.5) : .orange
        case .idle:
            return Color.secondary.opacity(0.4)
        }
    }

    private func rowHelp(_ row: HeaderServiceRow) -> String {
        switch row.status {
        case .running(let pid):
            return "\(row.runner.name) on \(row.branch) — running (pid \(pid))"
        case .failed(let message):
            return "\(row.runner.name) on \(row.branch) — \(message)"
        case .exited(let code):
            return "\(row.runner.name) on \(row.branch) — exited (\(code))"
        case .idle:
            return "\(row.runner.name) on \(row.branch) — not running"
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Button("Start all") {
                showServices = false
                start()
            }
            Button("Stop all") {
                showServices = false
                stop()
            }
            Spacer(minLength: 0)
            Button {
                showServices = false
                openRunPane()
            } label: {
                Label("Edit run config", systemImage: "slider.horizontal.3")
            }
        }
        .buttonStyle(.plain)
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
