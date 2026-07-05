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
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static func readJSON(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data)
        else { return nil }
        return obj as? [String: Any]
    }
}
