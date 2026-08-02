import Foundation

/// Pure mapping from the project's context sources — plan/spec docs and
/// root config files — into `LibraryItem` cards for the Context & MCPs
/// page. Pure like `LibraryScanner`: every input is a parameter, so
/// tests run against fixtures and temp dirs.
enum LibraryContext {

    /// The root config/instruction files the page knows, in the old
    /// sidebar's stable display order. `.mcp.json` is intentionally
    /// omitted — it already renders as MCP-server cards.
    static let configFileNames = [
        "CLAUDE.md", "AGENTS.md", "GEMINI.md", "run.toml", "README.md",
    ]

    /// Map `.plan`/`.spec` docs into cards (`.doc` kind excluded, as in
    /// the old sidebar). Plans lead, then specs, each newest-first by
    /// filename — the date prefix makes filename order date order.
    static func docItems(docs: [PlanDoc], projectRoot: URL) -> [LibraryItem] {
        let plans = docs.filter { $0.kind == .plan }
        let specs = docs.filter { $0.kind == .spec }
        return (newestFirst(plans) + newestFirst(specs)).map {
            item(for: $0, projectRoot: projectRoot)
        }
    }

    /// Existence-checked root config files, in `configFileNames` order.
    static func configItems(projectRoot: URL) -> [LibraryItem] {
        configFileNames.compactMap { name in
            let url = projectRoot.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            return LibraryItem(
                kind: .configFile,
                name: name,
                description: blurb(for: name),
                scopeLabel: "Project",
                path: url,
                accessible: true,
                accessReason: "At the project root — read by agents working here",
                detail: [name])
        }
    }

    private static func newestFirst(_ docs: [PlanDoc]) -> [PlanDoc] {
        docs.sorted { $0.fileURL.lastPathComponent > $1.fileURL.lastPathComponent }
    }

    private static func item(for doc: PlanDoc, projectRoot: URL) -> LibraryItem {
        var detail = [relativePath(of: doc.fileURL, projectRoot: projectRoot)]
        if let date = doc.date { detail.append(date) }
        return LibraryItem(
            kind: doc.kind == .plan ? .plan : .spec,
            name: doc.title.isEmpty ? doc.fileURL.lastPathComponent : doc.title,
            // The filename carries the date users know the docs by.
            description: doc.fileURL.lastPathComponent,
            scopeLabel: "Project",
            path: doc.fileURL,
            accessible: true,
            accessReason: "In this project's shared docs — read by agents",
            detail: detail)
    }

    /// Same path discipline as `DocStore.relativePath(of:)`.
    private static func relativePath(of url: URL, projectRoot: URL) -> String {
        url.standardizedFileURL.path.replacingOccurrences(
            of: projectRoot.standardizedFileURL.path + "/", with: "")
    }

    private static func blurb(for name: String) -> String {
        switch name {
        case "CLAUDE.md": return "Claude Code project instructions"
        case "AGENTS.md": return "Agent instructions"
        case "GEMINI.md": return "Gemini instructions"
        case "run.toml": return "Run configuration"
        case "README.md": return "Project readme"
        default: return ""
        }
    }
}
