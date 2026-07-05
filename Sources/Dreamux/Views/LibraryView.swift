import SwiftUI
import AppKit

/// The Skills & MCPs library — a read-only, App-Store-ish inventory of
/// every skill, MCP server, and plugin on this machine, badged with
/// whether THIS project's agents can reach it. v1 browses; installing
/// and the skills.sh registry land later (see the 2026-06-12 spec).
struct LibraryView: View {
    let projectRoot: URL

    @State private var items: [LibraryItem] = []
    @State private var query = ""
    @State private var selectedID: LibraryItem.ID?
    @State private var loaded = false

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                searchBar
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(.regularMaterial)
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
                    .background(.regularMaterial)
            }
            if let selected = items.first(where: { $0.id == selectedID }) {
                Divider()
                DetailPanel(item: selected)
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
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search skills, servers, plugins", text: $query)
                .textFieldStyle(.plain)
            Spacer()
            Text("\(filtered.count) of \(items.count)")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private var filtered: [LibraryItem] {
        guard !query.isEmpty else { return items }
        let needle = query.lowercased()
        return items.filter {
            $0.name.lowercased().contains(needle)
                || $0.description.lowercased().contains(needle)
                || $0.scopeLabel.lowercased().contains(needle)
        }
    }

    private var grid: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                section("Skills", kind: .skill)
                section("MCP Servers", kind: .mcpServer)
                section("Plugins", kind: .plugin)
            }
            .padding(16)
        }
    }

    @ViewBuilder
    private func section(_ title: String, kind: LibraryItemKind) -> some View {
        let sectionItems = filtered.filter { $0.kind == kind }
        if !sectionItems.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .kerning(0.6)
                    .textCase(.uppercase)
                    .foregroundStyle(.tertiary)
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 220), spacing: 12)],
                    alignment: .leading, spacing: 12
                ) {
                    ForEach(sectionItems) { item in
                        card(item)
                    }
                }
            }
        }
    }

    private func card(_ item: LibraryItem) -> some View {
        Button {
            selectedID = selectedID == item.id ? nil : item.id
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: icon(for: item.kind))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text(item.name)
                        .font(.callout.weight(.medium))
                        .lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 0)
                    Image(systemName: item.accessible ? "checkmark.seal.fill" : "xmark.seal")
                        .font(.system(size: 11))
                        .foregroundStyle(item.accessible ? Color.green : Color.secondary)
                        .help(item.accessReason)
                }
                Text(item.description.isEmpty ? "—" : item.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2, reservesSpace: true)
                    .multilineTextAlignment(.leading)
                Text(item.scopeLabel)
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.primary.opacity(0.07)))
                    .foregroundStyle(.secondary)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(selectedID == item.id
                          ? Color.accentColor.opacity(0.10)
                          : Color.primary.opacity(0.04)))
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(
                        selectedID == item.id
                            ? Color.accentColor.opacity(0.5)
                            : Color.primary.opacity(0.06)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func icon(for kind: LibraryItemKind) -> String {
        switch kind {
        case .skill: return "wand.and.stars"
        case .mcpServer: return "server.rack"
        case .plugin: return "puzzlepiece.extension"
        }
    }

    private var footer: some View {
        HStack {
            Text("Read-only inventory. Browse skills.sh — coming soon.")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Spacer()
        }
    }
}

/// Right-side inspector for the selected card: full description,
/// contents, path, Reveal in Finder. Read-only by design.
private struct DetailPanel: View {
    let item: LibraryItem

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Text(item.name)
                        .font(.title3.weight(.semibold))
                    Spacer(minLength: 0)
                    Image(systemName: item.accessible ? "checkmark.seal.fill" : "xmark.seal")
                        .foregroundStyle(item.accessible ? Color.green : Color.secondary)
                }
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
