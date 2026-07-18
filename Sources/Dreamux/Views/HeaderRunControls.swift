import SwiftUI

private struct ConfigureHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// The context header's run cluster: a play/stop capsule and a services
/// popover, sitting left of the git chip. Status derives from the
/// shared `RunnerManager` (via the tested aggregation in
/// RunnerHeaderState.swift); actions that navigate — starting the scope
/// (which may need the Run pane), editing run config, jumping to
/// Signals — are injected because they drive `sidebarMode`, which the
/// owning view controls. Shared across the context header, the Workspaces
/// rail cards, the main row, and the workspace Overview, so the run.toml
/// services control reads identically everywhere.
struct HeaderRunControls: View {
    let workspace: Workspace
    let runners: RunnerManager
    let start: () -> Void
    let stop: () -> Void
    let showLogs: (_ runnerName: String) -> Void
    /// The popover's Configure tab — run configuration (Detect, runner
    /// rows, run.toml) merged into this cluster (2026-07-18). Built by
    /// the owner, which holds the stores; `AnyView` keeps this type
    /// non-generic for the `makeRunControls` signatures.
    let configContent: () -> AnyView
    /// True for the context header's instance only: it consumes
    /// `RunnerManager.pendingConfigureWorkspaceID` so every "Run
    /// Settings" entry point opens exactly one popover.
    var consumesConfigureRequests: Bool = false

    enum PopoverTab {
        case services, configure
    }

    @State private var showServices = false
    @State private var popoverTab: PopoverTab = .services
    @State private var hoveredRowID: String?
    /// The Configure tab content's measured natural height — the popover
    /// hugs it up to a 520pt cap (see the tab's ScrollView).
    @State private var configureHeight: CGFloat = 0

    /// Fixed height of the outlined control so its two segments and the
    /// divider between them line up.
    private static let controlHeight: CGFloat = 26

    var body: some View {
        let summary = runners.headerSummary(for: workspace)
        // One outlined pill: play/stop on the left, a chevron for the
        // services popover on the right, split by a hairline divider.
        HStack(spacing: 0) {
            playSegment(summary)
            if summary.hasConfig {
                Rectangle()
                    .fill(Color.secondary.opacity(0.25))
                    .frame(width: 1, height: 16)
                chevronButton
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.3), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .popover(isPresented: $showServices, arrowEdge: .bottom) {
            servicesPopover
        }
        .onAppear(perform: consumeConfigureRequestIfAny)
        .onChange(of: runners.pendingConfigureWorkspaceID) { _, _ in
            consumeConfigureRequestIfAny()
        }
    }

    /// Open the popover on the Configure tab.
    private func openConfigure() {
        popoverTab = .configure
        showServices = true
    }

    private func consumeConfigureRequestIfAny() {
        guard consumesConfigureRequests,
              runners.pendingConfigureWorkspaceID == workspace.id else { return }
        runners.pendingConfigureWorkspaceID = nil
        openConfigure()
    }

    // MARK: - Segments

    private func playSegment(_ summary: HeaderRunSummary) -> some View {
        Button {
            if !summary.hasConfig {
                openConfigure()
            } else if summary.runningCount > 0 {
                stop()
            } else {
                start()
            }
        } label: {
            HStack(spacing: 6) {
                if summary.runningCount > 0 {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 7))
                        .foregroundStyle(summary.attention ? Color.orange : Color.green)
                        .symbolEffect(.pulse)
                    Image(systemName: "stop.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text("\(summary.runningCount) running")
                        .foregroundStyle(.secondary)
                } else {
                    if summary.attention {
                        Image(systemName: "circle.fill")
                            .font(.system(size: 7))
                            .foregroundStyle(Color.orange)
                    }
                    Image(systemName: "play.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 12))
            .padding(.horizontal, 10)
            .frame(height: Self.controlHeight)
            .contentShape(Rectangle())
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
            if showServices {
                showServices = false
            } else {
                popoverTab = .services
                showServices = true
            }
        } label: {
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: Self.controlHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Services")
    }

    // MARK: - Popover

    private var servicesPopover: some View {
        VStack(alignment: .leading, spacing: 0) {
            tabPicker
                .padding(8)
            Divider()
            if popoverTab == .services {
                servicesTab
            } else {
                // The Configure tab can outgrow a popover — scroll it,
                // sized to the content's MEASURED height capped at 520.
                // A scroll view reports no ideal height of its own, so a
                // flexible frame kept the Services tab's measurement
                // (clipping), and a fixed one left dead space when the
                // pane was short — hence the preference-key measure.
                ScrollView(showsIndicators: false) {
                    configContent()
                        .background(
                            GeometryReader { proxy in
                                Color.clear.preference(
                                    key: ConfigureHeightKey.self,
                                    value: proxy.size.height)
                            })
                }
                .onPreferenceChange(ConfigureHeightKey.self) { height in
                    // Ignore the 0 the preference collapses to when this
                    // branch leaves the tree, and sub-point jitter — both
                    // caused a re-render storm during the popover's
                    // resize that swallowed tab clicks.
                    guard height > 0, abs(height - configureHeight) > 1 else { return }
                    configureHeight = height
                }
                .frame(height: min(max(configureHeight, 120), 520))
            }
        }
        .frame(width: 360)
    }

    /// Services / Configure — two tabs over one popover, because
    /// running services and configuring how they run are the same job.
    private var tabPicker: some View {
        HStack(spacing: 4) {
            tabButton("Services", .services)
            tabButton("Configure", .configure)
            Spacer(minLength: 0)
        }
    }

    private func tabButton(_ title: String, _ tab: PopoverTab) -> some View {
        Button {
            popoverTab = tab
        } label: {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(popoverTab == tab ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(popoverTab == tab ? Color.primary.opacity(0.08) : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var servicesTab: some View {
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
                Text(":\(port)")
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
                    // Pin to this workspace's worktree and apply the
                    // shared fixed-port switch semantics — a single-row
                    // start must not launch on whatever branch a
                    // previous session left active, nor trip the bind
                    // probe when a fixed-port instance is live elsewhere.
                    Task { await runners.startPinned(row.runner, to: workspace.name) }
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
                popoverTab = .configure
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
