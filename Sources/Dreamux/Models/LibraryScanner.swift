import Foundation

/// What a library card represents.
enum LibraryItemKind: String {
    case skill, mcpServer, plugin
    case plan, spec, configFile

    /// The three kinds the Context chip covers — docs and config files
    /// merged in from the old sidebar Context section.
    var isContext: Bool {
        switch self {
        case .plan, .spec, .configFile: return true
        case .skill, .mcpServer, .plugin: return false
        }
    }
}

/// One card in the Context & MCPs library. Read-only inventory — the
/// page never mutates anything these point at.
struct LibraryItem: Identifiable, Equatable {
    let kind: LibraryItemKind
    let name: String
    let description: String
    /// "Project" / "Global" / "Plugin: <name>" / "Feature: <dir>".
    let scopeLabel: String
    /// Reveal-in-Finder target (skill dir, .mcp.json, plugin install dir).
    let path: URL
    /// Whether THIS project's agents can actually reach it.
    let accessible: Bool
    /// The honest why/why-not, shown as the badge tooltip.
    let accessReason: String
    /// Contents lines for the detail panel (files, command, versions…).
    let detail: [String]
    /// Context kinds key by path — two docs may share a title, but paths
    /// are unique. Other kinds keep (kind, scope, name): MCP servers
    /// share a `.mcp.json` path, so path can't be the universal key.
    var id: String {
        kind.isContext
            ? "\(kind.rawValue)|\(path.path)"
            : "\(kind.rawValue)|\(scopeLabel)|\(name)"
    }
}

/// The single install of a plugin that matters for THIS project — the
/// registry entry (`installed_plugins.json` v2) that grants access, or
/// the first entry when none does. Everything downstream (which skills
/// dir to scan, which version/path to show) reads from this one entry
/// instead of re-deriving it, so a plugin can never appear twice with
/// two different "current" versions.
struct PluginInstall {
    let name: String
    let installPath: URL
    let version: String
    let accessible: Bool
    let accessReason: String
}

/// Pure filesystem/JSON scanners over injectable roots — every input
/// path is a parameter so tests run against temp dirs, never the real
/// ~/.claude. Unreadable/malformed files are skipped silently: this is
/// a browser, not a linter.
enum LibraryScanner {

    // MARK: - Frontmatter

    /// The `---`-delimited `key: value` block SKILL.md files open with.
    /// Values may be single- or double-quoted, or a folded (`>`/`>-`) or
    /// literal (`|`/`|-`) block whose continuation lines are indented.
    /// Only column-0 lines create keys — indented lines (block bodies,
    /// or children of a nested `metadata:` map, as stripe's cached
    /// skills ship) never do, so they can't pollute the flat map this
    /// browser expects.
    static func parseFrontmatter(_ text: String) -> [String: String] {
        let lines = Array(text.split(separator: "\n", omittingEmptySubsequences: false))
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return [:] }
        var result: [String: String] = [:]
        var i = 1
        while i < lines.count {
            let rawLine = lines[i]
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed == "---" { break }
            // Indented lines never introduce a top-level key — either
            // they're a fold/literal-block body consumed below, or a
            // nested map's children, which we intentionally drop.
            guard !rawLine.hasPrefix(" "), !rawLine.hasPrefix("\t") else { i += 1; continue }
            guard let colon = trimmed.firstIndex(of: ":") else { i += 1; continue }
            let key = String(trimmed[..<colon]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { i += 1; continue }
            var value = String(trimmed[trimmed.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)

            if value == ">" || value == ">-" || value == "|" || value == "|-" {
                let folded = value.hasPrefix(">")
                var lineValues: [String] = []
                var j = i + 1
                while j < lines.count {
                    let contLine = lines[j]
                    let contTrimmed = contLine.trimmingCharacters(in: .whitespaces)
                    if contTrimmed == "---" { break }
                    guard contLine.hasPrefix(" ") || contLine.hasPrefix("\t") else { break }
                    lineValues.append(contTrimmed)
                    j += 1
                }
                result[key] = lineValues.joined(separator: folded ? " " : "\n")
                i = j
                continue
            }

            for quote in ["\"", "'"] where value.hasPrefix(quote) && value.hasSuffix(quote) && value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            }
            result[key] = value
            i += 1
        }
        return result
    }

    // MARK: - Skills

    static func scanSkills(
        projectRoot: URL,
        home: URL,
        plugins: [PluginInstall]
    ) -> [LibraryItem] {
        var items: [LibraryItem] = []
        var seenResolved: Set<String> = []

        func addSkills(
            under base: URL,
            scopeLabel: String,
            accessible: Bool,
            accessReason: String
        ) {
            for dir in subdirectories(of: base) {
                let skillFile = dir.appendingPathComponent("SKILL.md")
                guard let text = try? String(contentsOf: skillFile, encoding: .utf8)
                else { continue }
                let resolvedKey = dir.resolvingSymlinksInPath().path
                guard !seenResolved.contains(resolvedKey) else { continue }
                seenResolved.insert(resolvedKey)
                let fm = parseFrontmatter(text)
                let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
                items.append(LibraryItem(
                    kind: .skill,
                    name: fm["name"] ?? dir.lastPathComponent,
                    description: fm["description"] ?? "",
                    scopeLabel: scopeLabel,
                    path: dir,
                    accessible: accessible,
                    accessReason: accessReason,
                    detail: files.sorted()))
            }
        }

        // Project scope: SkillLinker fans these into every worktree.
        addSkills(under: projectRoot.appendingPathComponent(".agents/skills"),
                  scopeLabel: "Project", accessible: true,
                  accessReason: "Linked into every repo worktree of this project")
        addSkills(under: projectRoot.appendingPathComponent(".claude/skills"),
                  scopeLabel: "Project", accessible: true,
                  accessReason: "Linked into every repo worktree of this project")

        // Global scope: agents discover these in every session.
        addSkills(under: home.appendingPathComponent(".claude/skills"),
                  scopeLabel: "Global", accessible: true,
                  accessReason: "Global — available to every session")
        addSkills(under: home.appendingPathComponent(".agents/skills"),
                  scopeLabel: "Global", accessible: true,
                  accessReason: "Global — available to every session")

        // Plugin-bundled: exactly the install the registry resolved for
        // THIS project — not every cached version in cache/<mkt>/<plugin>/*,
        // which on a machine with several projects/updates yields many
        // stale duplicates of the same skill (and duplicate LibraryItem
        // ids, since ids don't carry a version component).
        for install in plugins {
            addSkills(
                under: install.installPath.appendingPathComponent("skills"),
                scopeLabel: "Plugin: \(install.name)",
                accessible: install.accessible,
                accessReason: install.accessible
                    ? "Ships with the \(install.name) plugin, which this project can use"
                    : "Ships with the \(install.name) plugin, which isn't enabled for this project")
        }

        return items
    }

    // MARK: - Shared helpers

    static func subdirectories(of url: URL) -> [URL] {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles])) ?? []
        return entries
            .filter { entry in
                // Test directory-ness on the RESOLVED target: SkillLinker
                // (and the skills.sh CLI) populate skill dirs as symlinks,
                // and a symlink's own dirent reports isDirectory == false
                // even when it points at a perfectly readable directory.
                // Filtering on the raw dirent would silently drop every
                // linked skill; the resolved-path dedup in scanSkills then
                // keeps mirrors from listing twice.
                var isDir: ObjCBool = false
                return FileManager.default.fileExists(
                    atPath: entry.resolvingSymlinksInPath().path,
                    isDirectory: &isDir) && isDir.boolValue
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static func readJSON(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data)
        else { return nil }
        return obj as? [String: Any]
    }

    // MARK: - MCP servers

    static func scanMCPServers(projectRoot: URL, home: URL) -> [LibraryItem] {
        var items: [LibraryItem] = []
        var projectNames: Set<String> = []
        let disabled = disabledServerNames(projectRoot: projectRoot)

        func serverDetail(_ entry: [String: Any]) -> [String] {
            var lines: [String] = []
            if let command = entry["command"] as? String {
                let args = (entry["args"] as? [String]) ?? []
                lines.append(([command] + args).joined(separator: " "))
            }
            if let url = entry["url"] as? String {
                lines.append("url: \(url)")
            }
            if let env = entry["env"] as? [String: Any], !env.isEmpty {
                lines.append("env: " + env.keys.sorted().joined(separator: ", "))
            }
            return lines
        }

        func addServers(
            from url: URL,
            scopeLabel: String,
            skipNames: Set<String> = [],
            accessibleOverride: Bool? = nil,
            applyDisabled: Bool = true,
            reasonWhenAccessible: String
        ) {
            guard let root = readJSON(url),
                  let servers = root["mcpServers"] as? [String: Any] else { return }
            for (name, raw) in servers.sorted(by: { $0.key < $1.key }) {
                guard !skipNames.contains(name),
                      let entry = raw as? [String: Any] else { continue }
                // disabledMcpjsonServers only governs project/feature-dir
                // .mcp.json entries — a global server sharing a name with
                // a disabled project one must stay accessible.
                let isDisabled = applyDisabled && disabled.contains(name)
                let accessible = accessibleOverride ?? !isDisabled
                items.append(LibraryItem(
                    kind: .mcpServer,
                    name: name,
                    description: "",
                    scopeLabel: scopeLabel,
                    path: url,
                    accessible: accessible,
                    accessReason: isDisabled
                        ? "Listed in \(url.lastPathComponent) but disabled in .claude settings"
                        : reasonWhenAccessible,
                    detail: serverDetail(entry)))
            }
        }

        // Project root .mcp.json — what agents at the project root see.
        let projectMCP = projectRoot.appendingPathComponent(".mcp.json")
        if let root = readJSON(projectMCP),
           let servers = root["mcpServers"] as? [String: Any] {
            projectNames = Set(servers.keys)
        }
        addServers(from: projectMCP, scopeLabel: "Project",
                   reasonWhenAccessible: "In the project's .mcp.json")

        // Feature dirs — where plan agents actually run.
        let featuresDir = projectRoot.appendingPathComponent("features")
        for feature in subdirectories(of: featuresDir) {
            addServers(
                from: feature.appendingPathComponent(".mcp.json"),
                scopeLabel: "Feature: \(feature.lastPathComponent)",
                skipNames: projectNames,
                reasonWhenAccessible: "In this feature's .mcp.json")
        }

        // ~/.claude.json: global + this-project-keyed maps.
        let claudeJSON = home.appendingPathComponent(".claude.json")
        addServers(from: claudeJSON, scopeLabel: "Global", applyDisabled: false,
                   reasonWhenAccessible: "Global — every session")
        if let root = readJSON(claudeJSON),
           let projects = root["projects"] as? [String: Any],
           let entry = projects[projectRoot.path] as? [String: Any],
           let servers = entry["mcpServers"] as? [String: Any], !servers.isEmpty {
            // Re-shape into the shared path by writing through addServers'
            // logic manually: same rows, project-keyed scope.
            for (name, raw) in servers.sorted(by: { $0.key < $1.key }) {
                guard let server = raw as? [String: Any] else { continue }
                let isDisabled = disabled.contains(name)
                items.append(LibraryItem(
                    kind: .mcpServer,
                    name: name,
                    description: "",
                    scopeLabel: "Project (Claude config)",
                    path: claudeJSON,
                    accessible: !isDisabled,
                    accessReason: isDisabled
                        ? "Configured for this project but disabled in .claude settings"
                        : "Configured for this project in ~/.claude.json",
                    detail: serverDetail(server)))
            }
        }

        return items
    }

    /// Union of `disabledMcpjsonServers` across the project's settings
    /// files — the same lists Claude Code honors.
    static func disabledServerNames(projectRoot: URL) -> Set<String> {
        var names: Set<String> = []
        for file in [".claude/settings.json", ".claude/settings.local.json"] {
            guard let root = readJSON(projectRoot.appendingPathComponent(file)),
                  let list = root["disabledMcpjsonServers"] as? [String] else { continue }
            names.formUnion(list)
        }
        return names
    }

    // MARK: - Plugins

    /// Everything `loadPluginRegistry` learns about one plugin key —
    /// `PluginInstall` plus the bits (marketplace, full scope label,
    /// plugin.json description) only `scanPlugins`' cards need.
    private struct PluginRegistryRow {
        let name: String
        let marketplace: String
        let installPath: URL
        let version: String
        let accessible: Bool
        let accessReason: String
        let scopeLabel: String
        let description: String
    }

    /// Parses `installed_plugins.json` v2 ONCE and, per plugin key,
    /// resolves the single entry that matters for this project: the
    /// entry that GRANTS access (user scope, or a `projectPath` at/under
    /// `projectRoot`), or the registry's first entry when none does.
    /// That chosen entry's installPath/version drive everything
    /// downstream — the plugin can never show two "current" versions.
    private static func loadPluginRegistry(projectRoot: URL, home: URL) -> [PluginRegistryRow] {
        guard let root = readJSON(home.appendingPathComponent(
            ".claude/plugins/installed_plugins.json")),
            let plugins = root["plugins"] as? [String: Any]
        else { return [] }

        var rows: [PluginRegistryRow] = []
        for (key, raw) in plugins.sorted(by: { $0.key < $1.key }) {
            guard let entries = raw as? [[String: Any]], !entries.isEmpty else { continue }
            // Key shape: "<name>@<marketplace>".
            let parts = key.split(separator: "@", maxSplits: 1)
            let name = String(parts.first ?? Substring(key))
            let marketplace = parts.count > 1 ? String(parts[1]) : ""

            let (chosen, granted) = choosePluginEntry(entries: entries, projectRoot: projectRoot)
            let installPath = (chosen["installPath"] as? String).map {
                URL(fileURLWithPath: $0)
            } ?? home.appendingPathComponent(".claude/plugins/cache")
            var version = (chosen["version"] as? String) ?? "unknown"

            var accessible = granted
            var reason = pluginAccessReason(entry: chosen, granted: granted, allEntries: entries)
            if isPluginDisabledBySettings(key: key, projectRoot: projectRoot, home: home) {
                accessible = false
                reason = "Disabled in Claude settings"
            }

            var description = ""
            if let pluginJSON = readJSON(installPath.appendingPathComponent(".claude-plugin/plugin.json")) {
                description = (pluginJSON["description"] as? String) ?? ""
                if version == "unknown", let pluginJSONVersion = pluginJSON["version"] as? String {
                    version = pluginJSONVersion
                }
            }

            rows.append(PluginRegistryRow(
                name: name,
                marketplace: marketplace,
                installPath: installPath,
                version: version,
                accessible: accessible,
                accessReason: reason,
                scopeLabel: pluginScopeLabel(entries: entries),
                description: description))
        }
        return rows
    }

    /// The one entry per plugin that the rest of the scanner should
    /// treat as authoritative — see `pluginInstalls` doc.
    static func pluginInstalls(projectRoot: URL, home: URL) -> [PluginInstall] {
        loadPluginRegistry(projectRoot: projectRoot, home: home).map {
            PluginInstall(
                name: $0.name, installPath: $0.installPath, version: $0.version,
                accessible: $0.accessible, accessReason: $0.accessReason)
        }
    }

    private static func pluginItem(_ row: PluginRegistryRow) -> LibraryItem {
        var detail = ["version \(row.version)"]
        if !row.marketplace.isEmpty { detail.append("marketplace: \(row.marketplace)") }
        let skillNames = subdirectories(of: row.installPath.appendingPathComponent("skills"))
            .map(\.lastPathComponent)
        if !skillNames.isEmpty {
            detail.append("skills: " + skillNames.joined(separator: ", "))
        }
        return LibraryItem(
            kind: .plugin,
            name: row.name,
            description: row.description,
            scopeLabel: row.scopeLabel,
            path: row.installPath,
            accessible: row.accessible,
            accessReason: row.accessReason,
            detail: detail)
    }

    static func scanPlugins(projectRoot: URL, home: URL) -> [LibraryItem] {
        loadPluginRegistry(projectRoot: projectRoot, home: home).map(pluginItem)
    }

    static func accessiblePluginNames(projectRoot: URL, home: URL) -> Set<String> {
        Set(pluginInstalls(projectRoot: projectRoot, home: home)
            .filter(\.accessible)
            .map(\.name))
    }

    /// The first entry (in registry order) that grants THIS project
    /// access, or the registry's first entry as a fallback so callers
    /// always have an installPath/version to show.
    private static func choosePluginEntry(
        entries: [[String: Any]],
        projectRoot: URL
    ) -> (entry: [String: Any], granted: Bool) {
        if let granting = entries.first(where: { pluginEntryGrantsAccess($0, projectRoot: projectRoot) }) {
            return (granting, true)
        }
        return (entries[0], false)
    }

    private static func pluginEntryGrantsAccess(_ entry: [String: Any], projectRoot: URL) -> Bool {
        if (entry["scope"] as? String) == "user" { return true }
        if let path = entry["projectPath"] as? String {
            // Feature-dir agents run INSIDE the project root, so a
            // projectPath at or under the root counts.
            return path == projectRoot.path || path.hasPrefix(projectRoot.path + "/")
        }
        return false
    }

    private static func pluginAccessReason(
        entry: [String: Any],
        granted: Bool,
        allEntries: [[String: Any]]
    ) -> String {
        guard granted else {
            let elsewhere = otherProjectNames(allEntries)
            return elsewhere.isEmpty
                ? "Installed only for other projects"
                : "Installed for \(elsewhere.joined(separator: ", ")) only"
        }
        return (entry["scope"] as? String) == "user"
            ? "Installed user-wide — every project"
            : "Installed for this project"
    }

    /// Distinct `projectPath` basenames across every entry, in registry
    /// order — used to name the project(s) a denied plugin belongs to.
    private static func otherProjectNames(_ entries: [[String: Any]]) -> [String] {
        var seen: Set<String> = []
        var names: [String] = []
        for entry in entries {
            guard let path = entry["projectPath"] as? String else { continue }
            let base = URL(fileURLWithPath: path).lastPathComponent
            if seen.insert(base).inserted { names.append(base) }
        }
        return names
    }

    private static func pluginScopeLabel(entries: [[String: Any]]) -> String {
        entries.contains { ($0["scope"] as? String) == "user" }
            ? "Global" : "Project-scoped"
    }

    /// `enabledPlugins` in `~/.claude/settings.json` and the project's
    /// `.claude/settings.local.json` / `.claude/settings.json` can force
    /// a plugin off. Project settings override global; an explicit
    /// `false` in EITHER project file wins outright, otherwise a global
    /// `false` applies. An absent key is no opinion — install scope
    /// decides, as it always has.
    private static func isPluginDisabledBySettings(
        key: String,
        projectRoot: URL,
        home: URL
    ) -> Bool {
        func explicitValue(_ url: URL) -> Bool? {
            guard let root = readJSON(url),
                  let map = root["enabledPlugins"] as? [String: Any]
            else { return nil }
            return map[key] as? Bool
        }
        let projectLocal = explicitValue(projectRoot.appendingPathComponent(".claude/settings.local.json"))
        let projectMain = explicitValue(projectRoot.appendingPathComponent(".claude/settings.json"))
        if projectLocal == false || projectMain == false { return true }
        if projectLocal != nil || projectMain != nil { return false }
        return explicitValue(home.appendingPathComponent(".claude/settings.json")) == false
    }

    // MARK: - Everything

    /// The page's one entry point: skills (plugin installs pre-resolved),
    /// then servers, then plugins — one registry parse feeds both the
    /// plugin section and the plugin-bundled skills.
    static func scanAll(projectRoot: URL, home: URL) -> [LibraryItem] {
        let rows = loadPluginRegistry(projectRoot: projectRoot, home: home)
        let installs = rows.map {
            PluginInstall(
                name: $0.name, installPath: $0.installPath, version: $0.version,
                accessible: $0.accessible, accessReason: $0.accessReason)
        }
        return scanSkills(projectRoot: projectRoot, home: home, plugins: installs)
            + scanMCPServers(projectRoot: projectRoot, home: home)
            + rows.map(pluginItem)
    }
}
