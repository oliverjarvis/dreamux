import SwiftUI
import AppKit

/// The Context & MCPs library — the project's context docs (plans,
/// specs, root config files) merged with a read-only, App-Store-ish
/// inventory of every skill, MCP server, and plugin on this machine,
/// badged with whether THIS project's agents can reach it. Docs open in
/// the editor; installing and the skills.sh registry land later (see
/// the 2026-06-12 spec).
struct LibraryView: View {
    let projectRoot: URL
    /// Project display name — the CLAUDE.md create card's template header.
    let projectName: String
    /// Live plan/spec docs (kqueue-watched) — doc cards appear and update
    /// as agents write files, no rescan needed.
    let docStore: DocStore
    /// Open a doc in an editor tab, exactly as the old sidebar rows did.
    let onOpenDoc: (URL) -> Void

    @State private var items: [LibraryItem] = []
    @State private var query = ""
    @State private var selectedID: LibraryItem.ID?
    @State private var loaded = false
    /// Active toolbar chip — `.all` shows every kind.
    @State private var chip: LibraryChip = .all
    /// Show only what THIS project's agents can reach right now.
    @State private var activeOnly = false

    /// Context cards, recomputed per body evaluation: `docStore.docs` is
    /// Observation-tracked so doc cards track disk live; the five config
    /// `fileExists` checks are negligible.
    private var contextItems: [LibraryItem] {
        LibraryContext.docItems(docs: docStore.docs, projectRoot: projectRoot)
            + LibraryContext.configItems(projectRoot: projectRoot)
    }

    /// Context first, then the one-shot scanned inventory.
    private var allItems: [LibraryItem] {
        contextItems + items
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                VStack(spacing: 10) {
                    searchBar
                    filterBar
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                Divider()
                if !loaded {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    grid
                }
                Divider()
                footer
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
            }
            if let selected = allItems.first(where: { $0.id == selectedID }) {
                Divider()
                DetailPanel(
                    item: selected,
                    onOpenInEditor: selected.kind.isContext
                        ? { onOpenDoc(selected.path) } : nil)
                    .frame(width: 300)
            }
        }
        .task {
            // ~/.claude.json's projects map and the plugin registry key
            // by resolved cwd paths — an alias root would silently drop
            // those scopes.
            let root = projectRoot.resolvingSymlinksInPath()
            let scanned = await Task.detached(priority: .userInitiated) {
                LibraryScanner.scanAll(
                    projectRoot: root,
                    home: FileManager.default.homeDirectoryForCurrentUser)
            }.value
            items = scanned
            loaded = true
        }
    }

    private var searchBar: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            TextField("Search context, skills, servers", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.secondary.opacity(0.12)))
    }

    /// Chip row + active-only switch. Context leads after All — the page
    /// is named for it. Chip counts reflect the current search and
    /// active-toggle, but not the kind narrowing.
    private var filterBar: some View {
        HStack(spacing: 8) {
            ForEach(LibraryChip.allCases, id: \.self) { candidate in
                FilterChip(label: candidate.label,
                           count: chipCount(candidate),
                           isActive: chip == candidate) { chip = candidate }
            }
            Spacer(minLength: 12)
            Toggle(isOn: $activeOnly) {
                Text("Active in this project")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            .tint(.teal)
            .help("Show only what this project's agents can reach right now")
        }
    }

    private func chipCount(_ chip: LibraryChip) -> Int {
        LibraryFilter.narrowed(searchScoped, chip: chip).count
    }

    /// Everything except kind narrowing — chip counts read this so each
    /// chip can show what you'd get by clicking it.
    private var searchScoped: [LibraryItem] {
        LibraryFilter.searchScoped(allItems, query: query, activeOnly: activeOnly)
    }

    private var filtered: [LibraryItem] {
        LibraryFilter.narrowed(searchScoped, chip: chip)
    }

    private var grid: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Context leads — the page is named for it; the scanned
                // inventory sections follow.
                section("Plans", kind: .plan)
                section("Specs", kind: .spec)
                configFilesSection
                section("Plugins", kind: .plugin)
                section("Skills", kind: .skill)
                section("MCP Servers", kind: .mcpServer)
                if loaded && filtered.isEmpty {
                    Text(activeOnly
                         ? "Nothing matching is active in this project."
                         : "No matches.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 40)
                }
            }
            .padding(20)
        }
    }

    @ViewBuilder
    private func section(_ title: String, kind: LibraryItemKind) -> some View {
        let sectionItems = filtered.filter { $0.kind == kind }
        if !sectionItems.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                sectionHeader(title, count: sectionItems.count)
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 300, maximum: 420), spacing: 12)],
                    alignment: .leading, spacing: 12
                ) {
                    ForEach(sectionItems) { item in
                        card(item)
                    }
                }
            }
        }
    }

    /// The create card is an offer, not inventory: only when CLAUDE.md is
    /// missing, no kind chip other than All/Context is narrowing, and no
    /// search is underway — it never matches a query.
    private var showsCreateClaudeCard: Bool {
        query.isEmpty
            && (chip == .all || chip == .context)
            && !contextItems.contains { $0.kind == .configFile && $0.name == "CLAUDE.md" }
    }

    /// Config Files renders like every section, plus the trailing create
    /// card — which counts as content for the hide-when-empty rule, so a
    /// project with no config files at all can still create CLAUDE.md.
    @ViewBuilder
    private var configFilesSection: some View {
        let sectionItems = filtered.filter { $0.kind == .configFile }
        if !sectionItems.isEmpty || showsCreateClaudeCard {
            VStack(alignment: .leading, spacing: 10) {
                sectionHeader("Config Files", count: sectionItems.count)
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 300, maximum: 420), spacing: 12)],
                    alignment: .leading, spacing: 12
                ) {
                    ForEach(sectionItems) { item in
                        card(item)
                    }
                    if showsCreateClaudeCard {
                        createClaudeCard
                    }
                }
            }
        }
    }

    /// Dashed-outline create card — secondary styling throughout; the
    /// hidden pill row reserves the same footer height as its neighbors.
    private var createClaudeCard: some View {
        Button(action: createAndOpenClaudeMd) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(Color.primary.opacity(0.05))
                        PhosphorIcon.plusFill
                            .renderingMode(.template)
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 16, height: 16)
                            .foregroundStyle(.secondary)
                    }
                    .frame(width: 34, height: 34)
                    Text("New CLAUDE.md")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                Text("Create project instructions for Claude at the project root")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2, reservesSpace: true)
                    .multilineTextAlignment(.leading)
                HStack(spacing: 6) {
                    ActivePill()
                    ScopePill(label: "Project")
                }
                .padding(.top, 2)
                .hidden()
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.15),
                                  style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .help("Create a CLAUDE.md at the project root and open it")
    }

    /// Write a minimal CLAUDE.md at the project root (if absent) and open
    /// it in an editor tab — moved from the sidebar's Context section.
    /// Best-effort: if the write fails, nothing opens.
    private func createAndOpenClaudeMd() {
        let url = projectRoot.appendingPathComponent("CLAUDE.md")
        if !FileManager.default.fileExists(atPath: url.path) {
            let stub = """
            # \(projectName)

            Project instructions for Claude. Describe the architecture,
            conventions, and anything an agent should know before working
            here.
            """
            try? stub.write(to: url, atomically: true, encoding: .utf8)
        }
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        onOpenDoc(url)
    }

    private func sectionHeader(_ title: String, count: Int) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)
            Text("\(count)")
                .font(.system(size: 11.5, weight: .semibold).monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.primary.opacity(0.08)))
        }
    }

    /// Single click selects and opens the panel, as for every card. On
    /// context cards a two-tap gesture rides alongside the select button:
    /// double-click opens the editor directly, skipping the panel.
    @ViewBuilder
    private func card(_ item: LibraryItem) -> some View {
        if item.kind.isContext {
            cardButton(item).simultaneousGesture(
                TapGesture(count: 2).onEnded { onOpenDoc(item.path) })
        } else {
            cardButton(item)
        }
    }

    private func cardButton(_ item: LibraryItem) -> some View {
        Button {
            selectedID = selectedID == item.id ? nil : item.id
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    KindTile(kind: item.kind, name: item.name)
                    Text(item.name)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 0)
                }
                Text(item.description.isEmpty ? "—" : item.description)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2, reservesSpace: true)
                    .multilineTextAlignment(.leading)
                HStack(spacing: 6) {
                    if item.accessible {
                        ActivePill()
                    }
                    ScopePill(label: item.scopeLabel)
                }
                .padding(.top, 2)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardSurface(isSelected: selectedID == item.id)
        }
        .buttonStyle(.plain)
        .help(item.accessReason)
    }

    private var footer: some View {
        HStack {
            Text("Browse-only inventory — docs open in the editor. Browse skills.sh — coming soon.")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Spacer()
        }
    }
}

/// 34pt rounded-square icon tile tinted per kind. Phosphor glyph where
/// the bundled set has one; SF Symbol fallback otherwise. Never emoji.
private struct KindTile: View {
    let kind: LibraryItemKind
    /// Item name — config-file glyphs are per-file (the sidebar's old
    /// mapping); other kinds ignore it.
    var name: String = ""

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(tint.opacity(fillOpacity))
            glyph
        }
        .frame(width: 34, height: 34)
    }

    private var tint: Color {
        switch kind {
        case .plugin: return .purple
        case .skill: return .orange
        case .mcpServer: return .blue
        case .plan: return .indigo
        case .spec: return .cyan
        case .configFile: return .mint
        }
    }

    private var fillOpacity: Double {
        switch kind {
        case .plugin: return 0.16
        case .skill: return 0.14
        case .mcpServer: return 0.15
        case .plan, .spec, .configFile: return 0.15
        }
    }

    @ViewBuilder private var glyph: some View {
        switch kind {
        case .plugin:
            PhosphorIcon.packageFill
                .renderingMode(.template)
                .aspectRatio(contentMode: .fit)
                .frame(width: 16, height: 16)
                .foregroundStyle(tint)
        case .skill:
            Image(systemName: "sparkles")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(tint)
        case .mcpServer:
            Image(systemName: "server.rack")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(tint)
        case .plan:
            Image(systemName: "checklist")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(tint)
        case .spec:
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(tint)
        case .configFile:
            Image(systemName: configGlyph)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(tint)
        }
    }

    /// The sidebar's old `configSymbol` mapping, carried over.
    private var configGlyph: String {
        switch name {
        case "CLAUDE.md", "AGENTS.md", "GEMINI.md": return "sparkles"
        case "run.toml": return "gearshape"
        default: return "doc.richtext"
        }
    }
}

/// Green "Active" pill — shown only on items this project can reach.
private struct ActivePill: View {
    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(Color.green).frame(width: 6, height: 6)
            Text("Active")
                .font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(Color.green)
        .padding(.horizontal, 9)
        .padding(.vertical, 3)
        .background(Capsule().fill(Color.green.opacity(0.13)))
    }
}

/// Neutral capsule for the free-form scope label (six string shapes:
/// Project / Global / Plugin: <name> / Feature: <dir> /
/// Project (Claude config) / Project-scoped) — renders any string.
private struct ScopePill: View {
    let label: String

    var body: some View {
        Text(label)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.primary.opacity(0.07)))
    }
}

/// Right-side inspector for the selected card: full description,
/// contents, path, Reveal in Finder. Read-only by design.
private struct DetailPanel: View {
    let item: LibraryItem
    /// Non-nil for context kinds — the primary "Open in Editor" action.
    var onOpenInEditor: (() -> Void)?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Text(item.name)
                        .font(.title3.weight(.semibold))
                    Spacer(minLength: 0)
                    if item.accessible {
                        ActivePill()
                    }
                }
                ScopePill(label: item.scopeLabel)
                Text(item.accessReason)
                    .font(.caption)
                    .foregroundStyle(item.accessible ? Color.secondary : Color.orange)
                if !item.description.isEmpty {
                    Text(item.description)
                        .font(.callout)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !item.detail.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Contents")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                        ForEach(item.detail, id: \.self) { line in
                            Text(line)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.path.path)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(2).truncationMode(.middle)
                    if let onOpenInEditor {
                        Button(action: onOpenInEditor) {
                            Label("Open in Editor", systemImage: "square.and.pencil")
                                .font(.caption)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([item.path])
                    } label: {
                        Label("Reveal in Finder", systemImage: "folder")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                Spacer(minLength: 0)
            }
            .padding(14)
        }
    }
}
