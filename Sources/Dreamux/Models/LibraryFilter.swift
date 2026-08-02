import Foundation

/// Which chip is active in the library toolbar. Each chip narrows to a
/// kind-set so one chip can span several kinds (Context = plans + specs
/// + config files); `all` matches everything. `allCases` order is the
/// chip-row display order.
enum LibraryChip: CaseIterable {
    case all, context, plugins, skills, mcpServers

    /// The kinds this chip narrows to — nil means no narrowing.
    var kinds: Set<LibraryItemKind>? {
        switch self {
        case .all: return nil
        case .context: return [.plan, .spec, .configFile]
        case .plugins: return [.plugin]
        case .skills: return [.skill]
        case .mcpServers: return [.mcpServer]
        }
    }

    var label: String {
        switch self {
        case .all: return "All"
        case .context: return "Context"
        case .plugins: return "Plugins"
        case .skills: return "Skills"
        case .mcpServers: return "MCP Servers"
        }
    }
}

/// Pure filtering pipeline for the library page: activeOnly → query,
/// with kind-set narrowing layered separately so chip counts can show
/// "what you'd get by clicking this chip".
enum LibraryFilter {
    static func searchScoped(
        _ items: [LibraryItem], query: String, activeOnly: Bool
    ) -> [LibraryItem] {
        var result = items
        if activeOnly {
            result = result.filter(\.accessible)
        }
        guard !query.isEmpty else { return result }
        let needle = query.lowercased()
        return result.filter {
            $0.name.lowercased().contains(needle)
                || $0.description.lowercased().contains(needle)
                || $0.scopeLabel.lowercased().contains(needle)
        }
    }

    /// The chip's kind-set narrowing, applied on top of `searchScoped`.
    static func narrowed(_ items: [LibraryItem], chip: LibraryChip) -> [LibraryItem] {
        guard let kinds = chip.kinds else { return items }
        return items.filter { kinds.contains($0.kind) }
    }
}
