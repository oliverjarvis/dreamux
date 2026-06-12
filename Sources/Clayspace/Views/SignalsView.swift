import SwiftUI
import AppKit

/// Datadog-style log explorer for whatever runners are emitting via the
/// shared `SignalStore`. Top bar = search + source/level filters; main
/// area = sortable table; bottom strip = entry-count + auto-scroll
/// toggle.
struct SignalsView: View {
    @Bindable var signals: SignalStore
    @Bindable var runners: RunnerManager

    @State private var query: String = ""
    @State private var enabledSources: Set<String> = []
    @State private var enabledLevels: Set<SignalLevel> = Set(SignalLevel.allCases)
    @State private var sortDescending: Bool = false
    @State private var autoScroll: Bool = true
    @State private var selectedEntryID: SignalEntry.ID?

    var body: some View {
        VStack(spacing: 0) {
            filterBar
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.regularMaterial)

            Divider()

            tableHeader
                .background(Color.secondary.opacity(0.08))

            Divider()

            if filteredEntries.isEmpty {
                emptyState
            } else {
                entryList
            }

            Divider()

            footer
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(.regularMaterial)
        }
        .onAppear {
            // Seed the source filter with everything we currently know
            // about; the user can opt sources out from the chip row.
            if enabledSources.isEmpty {
                enabledSources = Set(allKnownSources)
            }
        }
        .onChange(of: signals.knownSources) { _, newSources in
            // Auto-include freshly-discovered sources so we don't hide
            // a runner's first lines behind a chip the user never sees.
            for source in newSources where !enabledSources.contains(source) {
                enabledSources.insert(source)
            }
        }
    }

    // MARK: - Filter bar

    private var filterBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search signals", text: $query)
                    .textFieldStyle(.plain)
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }

                Divider().frame(height: 16)

                Button {
                    sortDescending.toggle()
                } label: {
                    Label(
                        sortDescending ? "Newest first" : "Oldest first",
                        systemImage: sortDescending ? "arrow.down" : "arrow.up"
                    )
                    .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Toggle(isOn: $autoScroll) {
                    Text("Live tail").font(.caption)
                }
                .toggleStyle(.switch)
                .controlSize(.mini)

                Button(role: .destructive) {
                    signals.clear()
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Clear all signals")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.secondary.opacity(0.10))
            )

            HStack(alignment: .top, spacing: 12) {
                chipRow(
                    title: "Source",
                    items: allKnownSources,
                    enabled: enabledSources,
                    onToggle: { source in
                        if enabledSources.contains(source) {
                            enabledSources.remove(source)
                        } else {
                            enabledSources.insert(source)
                        }
                    },
                    onSelectAll: { enabledSources = Set(allKnownSources) },
                    onSelectNone: { enabledSources.removeAll() },
                    label: { $0 },
                    tint: { _ in Color.accentColor }
                )

                chipRow(
                    title: "Level",
                    items: SignalLevel.allCases,
                    enabled: enabledLevels,
                    onToggle: { level in
                        if enabledLevels.contains(level) {
                            enabledLevels.remove(level)
                        } else {
                            enabledLevels.insert(level)
                        }
                    },
                    onSelectAll: { enabledLevels = Set(SignalLevel.allCases) },
                    onSelectNone: { enabledLevels.removeAll() },
                    label: { $0.label },
                    tint: { $0.tint }
                )
            }
        }
    }

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
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Button("All", action: onSelectAll)
                    .buttonStyle(.plain)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Button("None", action: onSelectNone)
                    .buttonStyle(.plain)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            if items.isEmpty {
                Text("—")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else {
                FlowLayout(spacing: 4) {
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

    // MARK: - Table

    private var tableHeader: some View {
        HStack(spacing: 0) {
            Text("Time")
                .frame(width: 96, alignment: .leading)
            Text("Level")
                .frame(width: 64, alignment: .leading)
            Text("Source")
                .frame(width: 140, alignment: .leading)
            Text("Message")
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    private var entryList: some View {
        ScrollViewReader { proxy in
            List(selection: $selectedEntryID) {
                ForEach(filteredEntries) { entry in
                    SignalRow(entry: entry)
                        .listRowInsets(EdgeInsets(top: 2, leading: 14, bottom: 2, trailing: 14))
                        .id(entry.id)
                        .tag(entry.id)
                }
            }
            .listStyle(.plain)
            .onChange(of: signals.entries.count) { _, _ in
                guard autoScroll else { return }
                if let last = filteredEntries.last {
                    withAnimation(.linear(duration: 0.05)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "waveform.path.ecg")
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)
            Text(emptyStateMessage)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
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
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer()
            let runningCount = runners.statusByInstance.values.filter(\.isRunning).count
            if runningCount > 0 {
                HStack(spacing: 4) {
                    Circle().fill(Color.green).frame(width: 6, height: 6)
                    Text("\(runningCount) instance\(runningCount == 1 ? "" : "s") running")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Derived

    private var allKnownSources: [String] {
        // Union of sources we've seen in the store and runners declared
        // in run.toml — so a configured-but-never-started runner still
        // gets a chip the user can preemptively select.
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
        if sortDescending {
            return base.reversed()
        }
        return Array(base)
    }
}

// MARK: - Row

private struct SignalRow: View {
    let entry: SignalEntry

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(entry.timestamp, format: .dateTime.hour().minute().second())
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 96, alignment: .leading)

            Text(entry.level.label)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(
                    Capsule().fill(entry.level.tint.opacity(0.85))
                )
                .frame(width: 64, alignment: .leading)

            Text(entry.source)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: 140, alignment: .leading)

            Text(entry.message)
                .font(.system(.caption, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(entry.message)
                .textSelection(.enabled)
        }
    }
}

// MARK: - Chip

private struct Chip: View {
    let label: String
    let tint: Color
    let isEnabled: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            Text(label)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(isEnabled ? Color.white : tint)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(
                    Capsule().fill(tint.opacity(isEnabled ? 0.85 : 0.15))
                )
                .overlay(
                    Capsule().strokeBorder(tint.opacity(isEnabled ? 0 : 0.35), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - FlowLayout

/// Minimal flow layout for the chip row — wraps to the next line when
/// the container width is exceeded. SwiftUI's HStack doesn't wrap, so we
/// roll our own via the Layout protocol.
private struct FlowLayout: Layout {
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

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
        }
        return CGSize(width: maxWidth, height: y + rowHeight)
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
