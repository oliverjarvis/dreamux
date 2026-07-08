import SwiftUI
import AppKit

/// Log console for whatever runners are emitting via the shared
/// `SignalStore`. Toolbar = search + controls (sort, zoom, live tail,
/// clear); a compact filter row; a dense, monospaced log list; a thin
/// footer with counts. Dense by default with a zoom control for reading
/// closely.
struct SignalsView: View {
    @Bindable var signals: SignalStore
    @Bindable var runners: RunnerManager
    let projectDir: String

    @State private var query: String = ""
    @State private var enabledSources: Set<String> = []
    @State private var enabledLevels: Set<SignalLevel> = Set(SignalLevel.allCases)
    @State private var sortDescending: Bool = false
    /// Whether the list is stuck to the newest end (tail-following). Set by
    /// the end sentinel's visibility — scroll away and it pauses, scroll
    /// back and it resumes. No explicit toggle.
    @State private var following: Bool = true
    /// New rows that have arrived while paused (scrolled away from latest),
    /// surfaced on the "Jump to latest" pill.
    @State private var newSinceScroll: Int = 0
    @State private var selectedEntryID: SignalEntry.ID?
    @State private var hoveredEntryID: SignalEntry.ID?
    /// Rows the user double-clicked to reveal in full (message wraps
    /// instead of truncating).
    @State private var expandedEntryIDs: Set<SignalEntry.ID> = []
    @State private var showSourceFilter = false
    @State private var showLevelFilter = false
    @State private var mcpStatus: MCPInstaller.Status?
    /// Persisted log text size — the console is dense by default; this is
    /// the zoom escape hatch.
    @AppStorage("signalsFontSize") private var fontSize: Double = 12

    private static let minFont: Double = 10
    private static let maxFont: Double = 19

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if filteredEntries.isEmpty {
                emptyState
            } else {
                entryList
            }
            Divider()
            footer
        }
        .onAppear {
            mcpStatus = MCPInstaller.status(at: projectDir)
            if let focus = signals.pendingSourceFocus {
                consumePendingFocus(focus)
            } else if enabledSources.isEmpty {
                enabledSources = Set(allKnownSources)
            }
        }
        .onChange(of: signals.knownSources) { oldSources, newSources in
            let known = Set(oldSources)
            for source in newSources where !known.contains(source) {
                enabledSources.insert(source)
            }
        }
        .onChange(of: signals.pendingSourceFocus) { _, focus in
            guard let focus else { return }
            consumePendingFocus(focus)
        }
    }

    /// Apply a parked "logs" focus jump: show only that runner's sources.
    private func consumePendingFocus(_ focus: String) {
        signals.pendingSourceFocus = nil
        enabledSources = SignalStore.sourcesMatching(
            focus: focus, in: allKnownSources)
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 10) {
            searchField
                .frame(maxWidth: .infinity)
            sourceFilter
            levelFilter
            // Only surfaces when MCP needs attention — a lone "all good"
            // seal in the toolbar just reads as clutter.
            if !mcpInstalled {
                mcpStatusButton
            }
            Rectangle().fill(Color.secondary.opacity(0.2)).frame(width: 1, height: 18)
            sortButton
            zoomControl
            iconButton("trash", help: "Clear all signals") {
                signals.clear()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.regularMaterial)
    }

    // MARK: - Filter dropdowns

    private var sourceFilter: some View {
        filterButton(title: "Source",
                     active: enabledSources.intersection(allKnownSources).count,
                     total: allKnownSources.count,
                     isPresented: $showSourceFilter) {
            chipRow(
                title: "Source",
                items: allKnownSources,
                enabled: enabledSources,
                onToggle: { source in
                    if enabledSources.contains(source) { enabledSources.remove(source) }
                    else { enabledSources.insert(source) }
                },
                onSelectAll: { enabledSources = Set(allKnownSources) },
                onSelectNone: { enabledSources.removeAll() },
                label: { $0 },
                tint: { _ in Color.primary }
            )
            .padding(12)
            .frame(width: 300)
        }
    }

    private var levelFilter: some View {
        filterButton(title: "Level",
                     active: enabledLevels.count,
                     total: SignalLevel.allCases.count,
                     isPresented: $showLevelFilter) {
            chipRow(
                title: "Level",
                items: SignalLevel.allCases,
                enabled: enabledLevels,
                onToggle: { level in
                    if enabledLevels.contains(level) { enabledLevels.remove(level) }
                    else { enabledLevels.insert(level) }
                },
                onSelectAll: { enabledLevels = Set(SignalLevel.allCases) },
                onSelectNone: { enabledLevels.removeAll() },
                label: { $0.label },
                tint: { $0.tint }
            )
            .padding(12)
            .frame(width: 260)
        }
    }

    /// A compact filter dropdown: shows the active count and tints itself
    /// when a subset is selected, and opens the toggle tags in a popover.
    private func filterButton<Content: View>(
        title: String, active: Int, total: Int,
        isPresented: Binding<Bool>, @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        let filtered = total > 0 && active < total
        return Button { isPresented.wrappedValue.toggle() } label: {
            HStack(spacing: 5) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(filtered ? .primary : .secondary)
                if filtered {
                    Text("\(active)")
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Color.accentColor)
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(filtered ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.10)))
        }
        .buttonStyle(.plain)
        .popover(isPresented: isPresented, arrowEdge: .bottom) { content() }
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            TextField("Search signals", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.secondary.opacity(0.12)))
    }

    private var sortButton: some View {
        iconButton(sortDescending ? "arrow.down" : "arrow.up",
                   help: sortDescending ? "Newest first (tap for oldest)"
                                        : "Oldest first (tap for newest)") {
            sortDescending.toggle()
        }
    }

    /// A− / A+ text-size stepper for the log rows.
    private var zoomControl: some View {
        HStack(spacing: 0) {
            Button { fontSize = max(Self.minFont, fontSize - 1) } label: {
                Image(systemName: "textformat.size.smaller")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(fontSize <= Self.minFont)

            Rectangle().fill(Color.secondary.opacity(0.2)).frame(width: 1, height: 14)

            Button { fontSize = min(Self.maxFont, fontSize + 1) } label: {
                Image(systemName: "textformat.size.larger")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(fontSize >= Self.maxFont)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.25), lineWidth: 1))
        .help("Log text size")
    }

    /// A subtle, borderless toolbar icon button.
    private func iconButton(
        _ symbol: String, help: String, role: ButtonRole? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(role: role, action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(role == .destructive ? Color.secondary : .secondary)
                .frame(width: 28, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    /// Manual (re)install affordance for the dreamux-signals MCP — quiet
    /// when ready, an amber nudge when it needs repair.
    private var mcpStatusButton: some View {
        Button {
            _ = MCPInstaller.installIfNeeded(at: projectDir, force: true)
            mcpStatus = MCPInstaller.status(at: projectDir)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: mcpSymbol)
                    .font(.system(size: 12, weight: .medium))
                if !mcpInstalled {
                    Text(mcpLabel).font(.system(size: 12, weight: .medium))
                }
            }
            .foregroundStyle(mcpTint)
            .padding(.horizontal, mcpInstalled ? 0 : 8)
            .frame(width: mcpInstalled ? 28 : nil, height: 26)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Give agents signal access via .mcp.json (dreamux-signals)")
    }

    private var mcpInstalled: Bool {
        if case .installed = mcpStatus { return true }
        return false
    }

    private var mcpSymbol: String {
        switch mcpStatus {
        case .installed: return "checkmark.seal"
        case .installedButScriptMissing: return "exclamationmark.triangle"
        case .noScriptAvailable: return "xmark.seal"
        default: return "puzzlepiece.extension"
        }
    }
    private var mcpLabel: String {
        switch mcpStatus {
        case .installedButScriptMissing: return "Repair MCP"
        case .noScriptAvailable: return "MCP unavailable"
        default: return "Install MCP"
        }
    }
    private var mcpTint: Color {
        switch mcpStatus {
        case .installed: return .secondary
        case .installedButScriptMissing: return .orange
        default: return .secondary
        }
    }

    // MARK: - Filters

    @ViewBuilder
    private func chipRow<Item: Hashable>(
        title: String,
        items: [Item],
        enabled: Set<Item>,
        onToggle: @escaping (Item) -> Void,
        onSelectAll: @escaping () -> Void,
        onSelectNone: @escaping () -> Void,
        label: @escaping (Item) -> String,
        tint: @escaping (Item) -> Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .kerning(0.3)
                    .textCase(.uppercase)
                    .foregroundStyle(.secondary)
                Button("All", action: onSelectAll)
                    .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.tertiary)
                Button("None", action: onSelectNone)
                    .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            if items.isEmpty {
                Text("—").font(.system(size: 12)).foregroundStyle(.tertiary)
            } else {
                SignalFlowLayout(spacing: 6) {
                    ForEach(items, id: \.self) { item in
                        Chip(
                            label: label(item),
                            tint: tint(item),
                            isEnabled: enabled.contains(item),
                            onTap: { onToggle(item) }
                        )
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Log list

    /// Which end holds the newest signal, and where to pin it.
    private var latestAnchorID: String { sortDescending ? "top" : "bottom" }
    private var latestAnchor: UnitPoint { sortDescending ? .top : .bottom }

    private var entryList: some View {
        ScrollViewReader { proxy in
            List(selection: $selectedEntryID) {
                sentinel(id: "top", isLatestEnd: sortDescending)
                ForEach(filteredEntries) { entry in
                    SignalRow(entry: entry, fontSize: fontSize,
                              isExpanded: expandedEntryIDs.contains(entry.id))
                        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                        .listRowSeparator(.hidden)
                        .listRowBackground(rowBackground(for: entry))
                        .id(entry.id)
                        .tag(entry.id)
                        .onHover { hovering in
                            if hovering { hoveredEntryID = entry.id }
                            else if hoveredEntryID == entry.id { hoveredEntryID = nil }
                        }
                        .onTapGesture(count: 2) { toggleExpanded(entry.id) }
                        .contextMenu {
                            Button(expandedEntryIDs.contains(entry.id) ? "Collapse" : "Expand") {
                                toggleExpanded(entry.id)
                            }
                            Divider()
                            Button("Copy message") { copyToPasteboard(entry.message) }
                            Button("Copy line") { copyToPasteboard(lineString(entry)) }
                        }
                }
                sentinel(id: "bottom", isLatestEnd: !sortDescending)
            }
            .listStyle(.plain)
            .environment(\.defaultMinListRowHeight, CGFloat(fontSize) + 8)
            .onChange(of: filteredEntries.count) { oldCount, newCount in
                if following {
                    withAnimation(.linear(duration: 0.05)) {
                        proxy.scrollTo(latestAnchorID, anchor: latestAnchor)
                    }
                } else if newCount > oldCount {
                    newSinceScroll += newCount - oldCount
                }
            }
            .onChange(of: sortDescending) { _, _ in
                following = true
                newSinceScroll = 0
                DispatchQueue.main.async {
                    proxy.scrollTo(latestAnchorID, anchor: latestAnchor)
                }
            }
            .onAppear {
                DispatchQueue.main.async {
                    proxy.scrollTo(latestAnchorID, anchor: latestAnchor)
                }
            }
            .overlay(alignment: sortDescending ? .top : .bottom) {
                if !following {
                    jumpToLatestButton {
                        following = true
                        newSinceScroll = 0
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo(latestAnchorID, anchor: latestAnchor)
                        }
                    }
                    .padding(sortDescending ? .top : .bottom, 12)
                }
            }
        }
    }

    /// An invisible 1pt row at one end of the list. When the end that holds
    /// the newest signal is visible, we're tail-following; when it scrolls
    /// out of view, we pause.
    private func sentinel(id: String, isLatestEnd: Bool) -> some View {
        Color.clear
            .frame(height: 1)
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .id(id)
            .onAppear {
                if isLatestEnd { following = true; newSinceScroll = 0 }
            }
            .onDisappear {
                if isLatestEnd { following = false }
            }
    }

    /// Floating pill shown while paused — jumps back to the newest signals
    /// and resumes following. Shows a count when new lines have arrived.
    private func jumpToLatestButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: sortDescending ? "arrow.up" : "arrow.down")
                    .font(.system(size: 11, weight: .bold))
                Text(newSinceScroll > 0
                     ? "\(newSinceScroll) new signal\(newSinceScroll == 1 ? "" : "s")"
                     : "Jump to latest")
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 13)
            .padding(.vertical, 7)
            .background(Capsule().fill(Color.accentColor))
            .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
        }
        .buttonStyle(.plain)
        .help("Scroll to the newest signals and resume following")
    }

    /// Row tint: selected wins, then a faint level wash for warn/error, then
    /// a hover highlight — so problems stand out and the pointer has feedback.
    private func rowBackground(for entry: SignalEntry) -> Color {
        if entry.id == selectedEntryID { return Color.accentColor.opacity(0.16) }
        switch entry.level {
        case .error: return Color.red.opacity(entry.id == hoveredEntryID ? 0.12 : 0.07)
        case .warn: return Color.orange.opacity(entry.id == hoveredEntryID ? 0.11 : 0.06)
        default: return entry.id == hoveredEntryID ? Color.primary.opacity(0.04) : .clear
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "waveform.path.ecg")
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)
            // NOTE: do NOT add `.fixedSize(horizontal: false, vertical: true)`
            // here — inside a detail column it drives SwiftUI's layout to a
            // degenerate state that blanks the whole window when this pane
            // appears.
            Text(emptyStateMessage)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    private var emptyStateMessage: String {
        if signals.entries.isEmpty {
            if runners.runners.isEmpty {
                return "No runners yet. Configure them on the Run page, then start a runner to see its signals here."
            } else {
                return "No signals yet. Start a runner on the Run page to begin streaming logs."
            }
        }
        return "No signals match the current filters."
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Text("\(filteredEntries.count) shown · \(signals.entries.count) total")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
            let runningCount = runners.statusByInstance.values.filter(\.isRunning).count
            if runningCount > 0 {
                HStack(spacing: 5) {
                    Circle().fill(Color.green).frame(width: 6, height: 6)
                    Text("\(runningCount) instance\(runningCount == 1 ? "" : "s") running")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(.regularMaterial)
    }

    // MARK: - Derived

    private var allKnownSources: [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for name in (runners.runners.map(\.name) + signals.knownSources) {
            if seen.insert(name).inserted { ordered.append(name) }
        }
        return ordered
    }

    private var filteredEntries: [SignalEntry] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let base = signals.entries.lazy.filter { entry in
            guard enabledSources.contains(entry.source) else { return false }
            guard enabledLevels.contains(entry.level) else { return false }
            if !trimmedQuery.isEmpty {
                return entry.message.lowercased().contains(trimmedQuery)
                    || entry.source.lowercased().contains(trimmedQuery)
            }
            return true
        }
        return sortDescending ? base.reversed() : Array(base)
    }

    private func toggleExpanded(_ id: SignalEntry.ID) {
        if expandedEntryIDs.contains(id) { expandedEntryIDs.remove(id) }
        else { expandedEntryIDs.insert(id) }
    }

    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func lineString(_ entry: SignalEntry) -> String {
        let time = entry.timestamp.formatted(.dateTime.hour().minute().second())
        return "\(time)  \(entry.level.label)  \(entry.source)  \(entry.message)"
    }
}

// MARK: - Row

private struct SignalRow: View {
    let entry: SignalEntry
    let fontSize: Double
    let isExpanded: Bool

    /// Monospaced columns scale with the zoom so nothing clips when the
    /// user sizes up. ~0.62em per SF Mono glyph.
    private var size: CGFloat { CGFloat(fontSize) }
    private var timeWidth: CGFloat { size * 5.4 }
    private var levelWidth: CGFloat { size * 4.2 }
    private var sourceWidth: CGFloat { size * 11 }
    private var showBar: Bool { entry.level == .error || entry.level == .warn }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(entry.timestamp, format: .dateTime.hour().minute().second())
                .foregroundStyle(.tertiary)
                .frame(width: timeWidth, alignment: .leading)

            Text(entry.level.label)
                .fontWeight(.semibold)
                .foregroundStyle(entry.level.tint)
                .frame(width: levelWidth, alignment: .leading)

            Text(entry.source)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: sourceWidth, alignment: .leading)

            Text(entry.message)
                .foregroundStyle(.primary)
                .lineLimit(isExpanded ? nil : 1)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: isExpanded)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(entry.message)
        }
        .font(.system(size: size, design: .monospaced))
        .padding(.leading, 14)
        .padding(.trailing, 12)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .leading) {
            // A thin colored bar on the left of warn/error rows so the
            // margin is scannable for problems.
            if showBar {
                Rectangle()
                    .fill(entry.level.tint)
                    .frame(width: 2.5)
            }
        }
        .contentShape(Rectangle())
    }
}

// MARK: - Chip

/// A flat filter tag: active items get a soft color-washed fill with
/// colored text; inactive ones are just muted text with a faint hover.
/// No dot, no border.
private struct Chip: View {
    let label: String
    let tint: Color
    let isEnabled: Bool
    let onTap: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 5) {
                if isEnabled {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .bold))
                }
                Text(label)
                    .font(.system(size: 12, weight: isEnabled ? .semibold : .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(isEnabled ? AnyShapeStyle(tint) : AnyShapeStyle(Color.secondary))
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(background))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }

    private var background: Color {
        // Deselected tags keep a neutral filled background (not transparent)
        // so they still read as togglable — "off", not gone.
        if isEnabled { return tint.opacity(0.18) }
        return Color.secondary.opacity(hovered ? 0.18 : 0.11)
    }
}

// MARK: - SignalFlowLayout

/// Minimal flow layout for the chip row — wraps to the next line when the
/// container width is exceeded. SwiftUI's HStack doesn't wrap, so we roll
/// our own via the Layout protocol.
private struct SignalFlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Void
    ) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var widest: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
            widest = max(widest, x - spacing)
        }
        // Never report an infinite width — an unspecified/`.fixedSize`
        // proposal must collapse to the content's own width, not ∞, or
        // SwiftUI asserts when placing into infinite bounds.
        let width = maxWidth.isFinite ? maxWidth : widest
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Void
    ) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
        }
    }
}
