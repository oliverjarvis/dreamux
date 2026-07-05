import Foundation

/// What a library card represents.
enum LibraryItemKind: String {
    case skill, mcpServer, plugin
}

/// One card in the Skills & MCPs library. Read-only inventory — the
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
    var id: String { "\(kind.rawValue)|\(scopeLabel)|\(name)" }
}

/// Pure filesystem/JSON scanners over injectable roots — every input
/// path is a parameter so tests run against temp dirs, never the real
/// ~/.claude. Unreadable/malformed files are skipped silently: this is
/// a browser, not a linter.
enum LibraryScanner {

    // MARK: - Frontmatter

    /// The `---`-delimited `key: value` block SKILL.md files open with.
    /// Values may be single- or double-quoted. No YAML nesting — the
    /// convention in the wild is flat (verified against installed
    /// plugins on this machine).
    static func parseFrontmatter(_ text: String) -> [String: String] {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)[...]
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return [:] }
        lines = lines.dropFirst()
        var result: [String: String] = [:]
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "---" { break }
            guard let colon = trimmed.firstIndex(of: ":") else { continue }
            let key = String(trimmed[..<colon]).trimmingCharacters(in: .whitespaces)
            var value = String(trimmed[trimmed.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)
            for quote in ["\"", "'"] where value.hasPrefix(quote) && value.hasSuffix(quote) && value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            }
            guard !key.isEmpty else { continue }
            result[key] = value
        }
        return result
    }

    // MARK: - Skills

    static func scanSkills(
        projectRoot: URL,
        home: URL,
        accessiblePlugins: Set<String>
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

        // Plugin-bundled: cache/<marketplace>/<plugin>/<version>/skills/*
        let cache = home.appendingPathComponent(".claude/plugins/cache")
        for marketplace in subdirectories(of: cache) {
            for plugin in subdirectories(of: marketplace) {
                for version in subdirectories(of: plugin) {
                    let pluginName = plugin.lastPathComponent
                    let reachable = accessiblePlugins.contains(pluginName)
                    addSkills(
                        under: version.appendingPathComponent("skills"),
                        scopeLabel: "Plugin: \(pluginName)",
                        accessible: reachable,
                        accessReason: reachable
                            ? "Ships with the \(pluginName) plugin, which this project can use"
                            : "Ships with the \(pluginName) plugin, which isn't enabled for this project")
                }
            }
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
            reasonWhenAccessible: String
        ) {
            guard let root = readJSON(url),
                  let servers = root["mcpServers"] as? [String: Any] else { return }
            for (name, raw) in servers.sorted(by: { $0.key < $1.key }) {
                guard !skipNames.contains(name),
                      let entry = raw as? [String: Any] else { continue }
                let isDisabled = disabled.contains(name)
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
        addServers(from: claudeJSON, scopeLabel: "Global",
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

    static func scanPlugins(projectRoot: URL, home: URL) -> [LibraryItem] {
        guard let root = readJSON(home.appendingPathComponent(
            ".claude/plugins/installed_plugins.json")),
            let plugins = root["plugins"] as? [String: Any]
        else { return [] }

        var items: [LibraryItem] = []
        for (key, raw) in plugins.sorted(by: { $0.key < $1.key }) {
            guard let entries = raw as? [[String: Any]], let first = entries.first
            else { continue }
            // Key shape: "<name>@<marketplace>".
            let parts = key.split(separator: "@", maxSplits: 1)
            let name = String(parts.first ?? Substring(key))
            let marketplace = parts.count > 1 ? String(parts[1]) : ""
            let installPath = (first["installPath"] as? String).map {
                URL(fileURLWithPath: $0)
            } ?? home.appendingPathComponent(".claude/plugins/cache")
            let version = (first["version"] as? String) ?? "unknown"

            let (accessible, reason) = pluginAccess(entries: entries, projectRoot: projectRoot)
            var detail = ["version \(version)"]
            if !marketplace.isEmpty { detail.append("marketplace: \(marketplace)") }
            let skillNames = subdirectories(of: installPath.appendingPathComponent("skills"))
                .map(\.lastPathComponent)
            if !skillNames.isEmpty {
                detail.append("skills: " + skillNames.joined(separator: ", "))
            }
            items.append(LibraryItem(
                kind: .plugin,
                name: name,
                description: "",
                scopeLabel: pluginScopeLabel(entries: entries),
                path: installPath,
                accessible: accessible,
                accessReason: reason,
                detail: detail))
        }
        return items
    }

    static func accessiblePluginNames(projectRoot: URL, home: URL) -> Set<String> {
        Set(scanPlugins(projectRoot: projectRoot, home: home)
            .filter(\.accessible)
            .map(\.name))
    }

    private static func pluginAccess(
        entries: [[String: Any]],
        projectRoot: URL
    ) -> (Bool, String) {
        for entry in entries {
            let scope = (entry["scope"] as? String) ?? ""
            if scope == "user" {
                return (true, "Installed user-wide — every project")
            }
            if let path = entry["projectPath"] as? String {
                // Feature-dir agents run INSIDE the project root, so a
                // projectPath at or under the root counts.
                if path == projectRoot.path || path.hasPrefix(projectRoot.path + "/") {
                    return (true, "Installed for this project")
                }
            }
        }
        return (false, "Installed only for other projects")
    }

    private static func pluginScopeLabel(entries: [[String: Any]]) -> String {
        entries.contains { ($0["scope"] as? String) == "user" }
            ? "Global" : "Project-scoped"
    }

    // MARK: - Everything

    /// The page's one entry point: skills (plugin access pre-computed),
    /// then servers, then plugins.
    static func scanAll(projectRoot: URL, home: URL) -> [LibraryItem] {
        let plugins = accessiblePluginNames(projectRoot: projectRoot, home: home)
        return scanSkills(projectRoot: projectRoot, home: home, accessiblePlugins: plugins)
            + scanMCPServers(projectRoot: projectRoot, home: home)
            + scanPlugins(projectRoot: projectRoot, home: home)
    }
}
