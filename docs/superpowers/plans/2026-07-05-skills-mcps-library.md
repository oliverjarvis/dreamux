# Skills & MCPs Library Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A read-only, App-Store-ish "Skills & MCPs" page — a new sidebar tile opening a main-pane library of every skill, MCP server, and plugin the local machine carries, each badged with whether this project's agents can actually reach it.

**Architecture:** A pure `LibraryScanner` enum (injectable roots, temp-dir testable) parses the real on-disk formats — SKILL.md frontmatter, `.mcp.json`/`~/.claude.json` server maps, `installed_plugins.json` v2 — into `LibraryItem`s with honest access verdicts. A new `SidebarTile.library` + `SidebarMode.library` route to `LibraryView`: search field, three card-grid sections, right-side detail inspector, Reveal in Finder, and the deferred skills.sh footer hook. One migration detail: `layout.tiles` is persisted, so the layout store must union in newly added tile cases at load.

**Tech Stack:** Swift/SwiftPM, SwiftUI (LazyVGrid), Foundation JSON/FileManager, XCTest. No new dependencies.

## Global Constraints

- Platform floor `macOS(.v14)`; no new dependencies. v1 is READ-ONLY: no install/uninstall/toggle anywhere; the only actions are selection and Reveal in Finder.
- Tile: `case library`, symbol `puzzlepiece.extension`, tint `.teal`, label `"Skills & MCPs"`, rendered below Signals/Browser (it's last in `allCases`); persisted tile lists must gain missing cases on load (users' sidebar.json predates it).
- Access verdicts are honest and carry a reason string (shown via `.help`): a wrong "Agent access" badge is worse than "Not accessible" with an explanation.
- Card grid: `LazyVGrid` adaptive columns (min 220pt), `.callout` names, 2-line `.caption` descriptions, scope badge capsule, green `checkmark.seal`/gray `xmark.seal` access badge. Detail inspector: fixed 300pt right column. Footer: quiet "Browse skills.sh — coming soon" (the 2026-06-12 skills.sh spec lands there later).
- Scanning runs off the main thread (a `.task` that calls the sync scanners on a background executor) and never throws user-visible errors — unreadable files are skipped silently (this is a browser, not a linter).
- On-disk truths (sampled from this machine, 2026-07-05): SKILL.md frontmatter = first `---`…`---` block of `key: value` lines (values may be double/single-quoted); plugin registry = `~/.claude/plugins/installed_plugins.json` `{"version":2,"plugins":{"<name>@<marketplace>":[{"scope":"user"|"project"|"local","projectPath":String?,"installPath":String,"version":String,...}]}}`; plugin skills live at `<installPath>/skills/*/SKILL.md`; `~/.claude.json` has top-level `mcpServers` plus `projects.<cwd>.mcpServers`; project disables live in `.claude/settings.json` + `.claude/settings.local.json` `disabledMcpjsonServers` arrays.
- Tests: XCTest in `Tests/DreamuxTests/`, temp-dir fixtures only (never the real `~/.claude`), house-style why-comments. Full `swift test` green before each task's final commit.
- Git: stage only named files (`Scripts/` capital-S); plain-sentence commits + `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- Delivery branch `skills-mcps-library`; merge only after user approval (Task 4).

**Verified code surfaces (current HEAD d61f9a3):**
- `SidebarTile` (Models/SidebarTile.swift): `String, Codable, CaseIterable, Identifiable` with `symbol/tint/label` switches. Rendered by `WorkspaceSidebar.tileRow` (~:423, selection test currently `tile == .signals && sidebarMode == .signals`), looped at :196 over `layout.tiles`, actions in `handleTileTap` (~:459).
- `SidebarMode` (ContentView.swift ~:661): `.workspace/.run(workspaceID:)/.signals`. Exhaustive switches to extend: `mainPane` (ContentView ~:275), `isWorkspaceActive` (WorkspaceSidebar ~:738), `sidebarModeName` (E2ECommands ~:261). Everything else assigns, never matches exhaustively.
- `layout.tiles` comes from the sidebar layout store persisted to `.dreamux/sidebar.json` (`SidebarLayoutStore` — read it; tiles are decoded by raw value, so a fresh case is absent from old files).
- Page-chrome precedents: `SignalsView` (filter bar on `.regularMaterial` → Divider → content → footer) and the `case .signals:` construction in `mainPane` (`SignalsView(signals:runners:projectDir:)`).
- JSON-reading precedent: `MCPInstaller.readJSON(url:) -> [String: Any]?` (JSONSerialization, nil on any failure).
- Project skills conventions: `SkillLinker` fans `<project>/.agents/skills/<name>` into every worktree's `.agents/skills` + `.claude/skills` — a project skill IS agent-reachable by construction.

---

### Task 1: LibraryScanner — item model, frontmatter, skills

**Files:**
- Create: `Sources/Dreamux/Models/LibraryScanner.swift`
- Test: `Tests/DreamuxTests/LibraryScannerTests.swift`

**Interfaces:**
- Consumes: nothing new.
- Produces (Tasks 2–3 rely on, verbatim):
  - `enum LibraryItemKind: String { case skill, mcpServer, plugin }`
  - `struct LibraryItem: Identifiable, Equatable { let kind: LibraryItemKind; let name: String; let description: String; let scopeLabel: String; let path: URL; let accessible: Bool; let accessReason: String; let detail: [String]; var id: String { "\(kind.rawValue)|\(scopeLabel)|\(name)" } }`
  - `LibraryScanner.parseFrontmatter(_ text: String) -> [String: String]`
  - `LibraryScanner.scanSkills(projectRoot: URL, home: URL, accessiblePlugins: Set<String>) -> [LibraryItem]`

- [ ] **Step 1: Create the working branch**

```bash
cd /Users/olliejarvis/Development/clayspace
git worktree add .claude/worktrees/skills-mcps-library -b skills-mcps-library
cd .claude/worktrees/skills-mcps-library
```

- [ ] **Step 2: Write the failing tests**

Create `Tests/DreamuxTests/LibraryScannerTests.swift`:

```swift
import XCTest
@testable import Dreamux

/// The library page is only as good as its parsers: frontmatter is the
/// lone metadata source for skills, and the scanners must dedup the
/// SkillLinker symlink fan-out rather than listing one skill three
/// times. Everything runs against temp-dir fixtures — never ~/.claude.
final class LibraryScannerTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("library-scan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func makeSkill(at base: URL, name: String, description: String) throws {
        let skillDir = base.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: skillDir, withIntermediateDirectories: true)
        try """
        ---
        name: \(name)
        description: "\(description)"
        ---

        # \(name)
        """.write(to: skillDir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
    }

    // MARK: - parseFrontmatter

    /// Quoted and bare values, keys after the closing --- ignored.
    func testParseFrontmatter() {
        let text = """
        ---
        name: brainstorming
        description: "Use this, always."
        license: 'MIT'
        ---
        body: not-frontmatter
        """
        let fm = LibraryScanner.parseFrontmatter(text)
        XCTAssertEqual(fm["name"], "brainstorming")
        XCTAssertEqual(fm["description"], "Use this, always.")
        XCTAssertEqual(fm["license"], "MIT")
        XCTAssertNil(fm["body"])
    }

    func testParseFrontmatterMissingBlockIsEmpty() {
        XCTAssertTrue(LibraryScanner.parseFrontmatter("# Just markdown").isEmpty)
    }

    // MARK: - scanSkills

    /// Project, global, and plugin skills all surface with the right
    /// scope labels; project + global are accessible by construction,
    /// plugin skills inherit their plugin's accessibility.
    func testScanSkillsAcrossScopes() throws {
        let project = dir.appendingPathComponent("proj")
        let home = dir.appendingPathComponent("home")
        try makeSkill(at: project.appendingPathComponent(".agents/skills"),
                      name: "proj-skill", description: "project one")
        try makeSkill(at: home.appendingPathComponent(".claude/skills"),
                      name: "global-skill", description: "global one")
        try makeSkill(
            at: home.appendingPathComponent(".claude/plugins/cache/mkt/superpowers/1.0.0/skills"),
            name: "plugin-skill", description: "plugin one")

        let items = LibraryScanner.scanSkills(
            projectRoot: project, home: home,
            accessiblePlugins: ["superpowers"])

        XCTAssertEqual(items.count, 3)
        let byName = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0) })
        XCTAssertEqual(byName["proj-skill"]?.scopeLabel, "Project")
        XCTAssertEqual(byName["proj-skill"]?.accessible, true)
        XCTAssertEqual(byName["global-skill"]?.scopeLabel, "Global")
        XCTAssertEqual(byName["plugin-skill"]?.scopeLabel, "Plugin: superpowers")
        XCTAssertEqual(byName["plugin-skill"]?.accessible, true)
        XCTAssertEqual(byName["plugin-skill"]?.description, "plugin one")
    }

    /// A plugin skill from a plugin this project can't reach is listed
    /// but NOT accessible — visible inventory, honest badge.
    func testPluginSkillInheritsInaccessibility() throws {
        let project = dir.appendingPathComponent("proj")
        let home = dir.appendingPathComponent("home")
        try makeSkill(
            at: home.appendingPathComponent(".claude/plugins/cache/mkt/other/2.0/skills"),
            name: "locked", description: "elsewhere")
        let items = LibraryScanner.scanSkills(
            projectRoot: project, home: home, accessiblePlugins: [])
        XCTAssertEqual(items.count, 1)
        XCTAssertFalse(items[0].accessible)
        XCTAssertFalse(items[0].accessReason.isEmpty)
    }

    /// SkillLinker mirrors .agents/skills into .claude/skills via
    /// symlinks — the scanner must dedup by resolved path, not list
    /// the same skill twice.
    func testScanSkillsDedupsSymlinkedMirrors() throws {
        let project = dir.appendingPathComponent("proj")
        let canonical = project.appendingPathComponent(".agents/skills")
        try makeSkill(at: canonical, name: "one", description: "canonical")
        let mirror = project.appendingPathComponent(".claude/skills")
        try FileManager.default.createDirectory(at: mirror, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: mirror.appendingPathComponent("one"),
            withDestinationURL: canonical.appendingPathComponent("one"))

        let items = LibraryScanner.scanSkills(
            projectRoot: project, home: dir.appendingPathComponent("home"),
            accessiblePlugins: [])
        XCTAssertEqual(items.filter { $0.name == "one" }.count, 1)
    }
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `swift test --filter LibraryScannerTests 2>&1 | tail -10`
Expected: BUILD FAILURE — `cannot find 'LibraryScanner' in scope`.

- [ ] **Step 4: Implement**

Create `Sources/Dreamux/Models/LibraryScanner.swift`:

```swift
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
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter LibraryScannerTests 2>&1 | tail -5`
Expected: `Test Suite 'LibraryScannerTests' passed` — 5 tests.

- [ ] **Step 6: Full suite, commit**

Run: `swift test 2>&1 | grep -E "Executed .* tests" | tail -1` → 0 failures.

```bash
git add Sources/Dreamux/Models/LibraryScanner.swift Tests/DreamuxTests/LibraryScannerTests.swift
git commit -m "Library scanner: frontmatter parsing and skill inventory

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: MCP-server and plugin scanners

**Files:**
- Modify: `Sources/Dreamux/Models/LibraryScanner.swift` (extend)
- Test: `Tests/DreamuxTests/LibraryScannerTests.swift` (extend)

**Interfaces:**
- Consumes: Task 1's `LibraryItem`, `readJSON`, `subdirectories`.
- Produces (Task 3 relies on, verbatim):
  - `LibraryScanner.scanMCPServers(projectRoot: URL, home: URL) -> [LibraryItem]`
  - `LibraryScanner.scanPlugins(projectRoot: URL, home: URL) -> [LibraryItem]`
  - `LibraryScanner.accessiblePluginNames(projectRoot: URL, home: URL) -> Set<String>`
  - `LibraryScanner.scanAll(projectRoot: URL, home: URL) -> [LibraryItem]` — skills (with plugin access wired) + servers + plugins, in that order.

- [ ] **Step 1: Write the failing tests**

Append to `LibraryScannerTests.swift`:

```swift
    // MARK: - scanMCPServers

    private func writeJSON(_ obj: [String: Any], to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted])
            .write(to: url)
    }

    /// Project .mcp.json servers are accessible unless a settings file
    /// disables them; the disabled one still LISTS (inventory) with an
    /// honest badge.
    func testScanMCPServersProjectWithDisables() throws {
        let project = dir.appendingPathComponent("proj")
        let home = dir.appendingPathComponent("home")
        try writeJSON([
            "mcpServers": [
                "dreamux-signals": ["command": "/bun", "args": ["run", "x.ts"]],
                "muted": ["command": "/bin/echo"],
            ],
        ], to: project.appendingPathComponent(".mcp.json"))
        try writeJSON(
            ["disabledMcpjsonServers": ["muted"]],
            to: project.appendingPathComponent(".claude/settings.local.json"))

        let items = LibraryScanner.scanMCPServers(projectRoot: project, home: home)
        let byName = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0) })
        XCTAssertEqual(byName["dreamux-signals"]?.accessible, true)
        XCTAssertEqual(byName["muted"]?.accessible, false)
        XCTAssertTrue(byName["muted"]!.accessReason.contains("disabled"))
        XCTAssertTrue(byName["dreamux-signals"]!.detail.joined().contains("/bun"))
    }

    /// Global servers come from ~/.claude.json — both the top-level map
    /// and the entry keyed by this project's path.
    func testScanMCPServersGlobalAndProjectKeyed() throws {
        let project = dir.appendingPathComponent("proj")
        let home = dir.appendingPathComponent("home")
        try writeJSON([
            "mcpServers": ["everywhere": ["command": "/g"]],
            "projects": [
                project.path: ["mcpServers": ["scoped": ["command": "/p"]]],
                "/elsewhere": ["mcpServers": ["other": ["command": "/o"]]],
            ],
        ], to: home.appendingPathComponent(".claude.json"))

        let items = LibraryScanner.scanMCPServers(projectRoot: project, home: home)
        let names = Set(items.map(\.name))
        XCTAssertTrue(names.contains("everywhere"))
        XCTAssertTrue(names.contains("scoped"))
        XCTAssertFalse(names.contains("other"), "another project's servers are not this project's inventory")
    }

    /// Feature-dir .mcp.json entries surface unless the project root
    /// already declares the same server name.
    func testScanMCPServersFeatureDirsDedupAgainstProject() throws {
        let project = dir.appendingPathComponent("proj")
        let home = dir.appendingPathComponent("home")
        try writeJSON(["mcpServers": ["dreamux-signals": ["command": "/a"]]],
                      to: project.appendingPathComponent(".mcp.json"))
        try writeJSON(["mcpServers": [
            "dreamux-signals": ["command": "/b"],
            "feature-only": ["command": "/c"],
        ]], to: project.appendingPathComponent("features/thing/.mcp.json"))

        let items = LibraryScanner.scanMCPServers(projectRoot: project, home: home)
        XCTAssertEqual(items.filter { $0.name == "dreamux-signals" }.count, 1)
        XCTAssertTrue(items.contains { $0.name == "feature-only" && $0.scopeLabel == "Feature: thing" })
    }

    // MARK: - scanPlugins / accessiblePluginNames

    /// v2 registry: user scope reaches everywhere; project/local scope
    /// reaches only when its projectPath is this project (or inside it,
    /// where feature-dir agents run).
    func testScanPluginsScopes() throws {
        let project = dir.appendingPathComponent("proj")
        let home = dir.appendingPathComponent("home")
        try writeJSON([
            "version": 2,
            "plugins": [
                "superpowers@official": [[
                    "scope": "user",
                    "installPath": home.appendingPathComponent(".claude/plugins/cache/official/superpowers/6.1.0").path,
                    "version": "6.1.0",
                ]],
                "here-only@official": [[
                    "scope": "project",
                    "projectPath": project.path,
                    "installPath": home.appendingPathComponent(".claude/plugins/cache/official/here-only/1.0").path,
                    "version": "1.0",
                ]],
                "elsewhere@official": [[
                    "scope": "project",
                    "projectPath": "/somewhere/else",
                    "installPath": home.appendingPathComponent(".claude/plugins/cache/official/elsewhere/1.0").path,
                    "version": "1.0",
                ]],
            ],
        ], to: home.appendingPathComponent(".claude/plugins/installed_plugins.json"))

        let items = LibraryScanner.scanPlugins(projectRoot: project, home: home)
        let byName = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0) })
        XCTAssertEqual(byName["superpowers"]?.accessible, true)
        XCTAssertEqual(byName["here-only"]?.accessible, true)
        XCTAssertEqual(byName["elsewhere"]?.accessible, false)
        XCTAssertTrue(byName["superpowers"]!.detail.contains { $0.contains("6.1.0") })

        let accessible = LibraryScanner.accessiblePluginNames(projectRoot: project, home: home)
        XCTAssertEqual(accessible, ["superpowers", "here-only"])
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter LibraryScannerTests 2>&1 | tail -10`
Expected: BUILD FAILURE — no member `scanMCPServers`.

- [ ] **Step 3: Implement**

Append to `LibraryScanner`:

```swift
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
```

- [ ] **Step 4: Tests green, full suite, commit**

Run: `swift test --filter LibraryScannerTests 2>&1 | tail -5` → 9 tests passed.
Run: `swift test 2>&1 | grep -E "Executed .* tests" | tail -1` → 0 failures.

```bash
git add Sources/Dreamux/Models/LibraryScanner.swift Tests/DreamuxTests/LibraryScannerTests.swift
git commit -m "Library scanner inventories MCP servers and installed plugins

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: Tile, mode, and the LibraryView page

**Files:**
- Modify: `Sources/Dreamux/Models/SidebarTile.swift` (new case)
- Modify: `Sources/Dreamux/Models/SidebarLayoutStore.swift` (tiles union on load — read the store first)
- Modify: `Sources/Dreamux/Views/ContentView.swift` (`SidebarMode.library` + `mainPane` case)
- Modify: `Sources/Dreamux/Views/WorkspaceSidebar.swift` (`tileRow` selection, `handleTileTap`, `isWorkspaceActive`)
- Modify: `Sources/Dreamux/E2E/E2ECommands.swift` (`sidebarModeName` case)
- Create: `Sources/Dreamux/Views/LibraryView.swift`
- Test: `Tests/DreamuxTests/SidebarLayoutStoreTests.swift` (extend — tiles union)

**Interfaces:**
- Consumes: `LibraryScanner.scanAll` (Task 2), the tile/mode wiring checklist above.
- Produces: the shipped page.

- [ ] **Step 1: Failing tiles-union test**

Read `SidebarLayoutStore.swift` + its tests first (how `tiles` decodes from `.dreamux/sidebar.json`). Add to `SidebarLayoutStoreTests`:

```swift
    /// sidebar.json written before a tile case existed must still show
    /// the new tile after load — union missing cases (append, keeping
    /// the user's saved order for the rest).
    func testTilesUnionInMissingCases() throws {
        // arrange per this file's fixture style: persist a layout whose
        // tiles are [.signals, .browser] only, reload the store, then:
        XCTAssertTrue(store.tiles.contains(.library))
        XCTAssertEqual(store.tiles.prefix(2), [.signals, .browser],
                       "saved order preserved; new cases appended")
    }
```

(Adapt arrangement to the real store/test conventions — if the store decodes tiles inline, the union belongs right after decode; the assertion pair is the contract.)

- [ ] **Step 2: Red**

Run: `swift test --filter SidebarLayoutStoreTests 2>&1 | tail -6`
Expected: FAILURE — `.library` doesn't exist yet (build error), then after adding the case: union missing.

- [ ] **Step 3: Tile + mode + union**

1. `SidebarTile`: add `case library` with `symbol: "puzzlepiece.extension"`, `tint: .teal`, `label: "Skills & MCPs"` (extend all three switches).
2. `SidebarLayoutStore`: wherever `tiles` is loaded/decoded, append missing cases: `let missing = SidebarTile.allCases.filter { !tiles.contains($0) }; tiles += missing` (adapt to real property/flow; the saved order stays, new cases trail).
3. `SidebarMode` (ContentView ~:661): add `case library`. `mainPane` (~:275): add

```swift
        case .library:
            LibraryView(projectRoot: repoStore.project.rootPath)
```

4. `WorkspaceSidebar`: `tileRow` selection becomes

```swift
        let selected = (tile == .signals && sidebarMode == .signals)
            || (tile == .library && sidebarMode == .library)
```

`handleTileTap`: `case .library: sidebarMode = .library`. `isWorkspaceActive` (~:738): `case .library: return false`.
5. `E2ECommands.sidebarModeName` (~:261): `case .library: return "library"`.

- [ ] **Step 4: LibraryView**

Create `Sources/Dreamux/Views/LibraryView.swift`:

```swift
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
            let root = projectRoot
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
```

- [ ] **Step 5: Green + full suite + commit**

Run: `swift test --filter SidebarLayoutStoreTests 2>&1 | tail -5` → passed.
Run: `swift build 2>&1 | grep "error:" | head; echo BUILD-DONE` → no errors.
Run: `swift test 2>&1 | grep -E "Executed .* tests" | tail -1` → 0 failures.

```bash
git add Sources/Dreamux/Models/SidebarTile.swift Sources/Dreamux/Models/SidebarLayoutStore.swift Sources/Dreamux/Views/ContentView.swift Sources/Dreamux/Views/WorkspaceSidebar.swift Sources/Dreamux/E2E/E2ECommands.swift Sources/Dreamux/Views/LibraryView.swift Tests/DreamuxTests/SidebarLayoutStoreTests.swift
git commit -m "Skills & MCPs library page behind a new sidebar tile

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: Verification + merge gate

**Files:** none (verification + git only)

- [ ] **Step 1: Build + relaunch from the worktree**

```bash
./Scripts/make-app.sh
PID=$(pgrep -x Dreamux); if [ -n "$PID" ]; then kill -TERM "$PID"; while kill -0 "$PID" 2>/dev/null; do sleep 0.3; done; fi
open ./Dreamux.app --args -ApplePersistenceIgnoreState YES
sleep 4
```

- [ ] **Step 2: Live verification**

- The "Skills & MCPs" tile appears below Signals/Browser (with a PRE-EXISTING sidebar.json — the union must add it).
- The page loads: superpowers skills listed under Plugin scope with real descriptions from frontmatter; `dreamux-signals` under MCP Servers (Project scope, accessible) in any project where it's installed; plugins section shows the installed_plugins.json inventory with sensible scope/access badges.
- Search narrows across all three sections; card click opens the 300pt detail panel; Reveal in Finder lands on the right dir; access-badge tooltips read sensibly.
- Tile highlights while the page is open; Signals/Browser/workspace switching still works; nothing regressed in e2e mode naming.
- Screenshot the page for the record if capture is available.

- [ ] **Step 3: Present results to the user and wait for merge approval.** Do not merge without it.

- [ ] **Step 4: Merge and push (after approval)**

```bash
cd /Users/olliejarvis/Development/clayspace
git status --short && git log --oneline -1
git merge --ff-only skills-mcps-library || git merge --no-edit skills-mcps-library
swift test 2>&1 | grep -E "Executed .* tests" | tail -1
git push origin main
git worktree remove .claude/worktrees/skills-mcps-library
git branch -d skills-mcps-library
./Scripts/make-app.sh
PID=$(pgrep -x Dreamux); if [ -n "$PID" ]; then kill -TERM "$PID"; while kill -0 "$PID" 2>/dev/null; do sleep 0.3; done; fi
open /Users/olliejarvis/Development/clayspace/Dreamux.app
```

Expected: ff merge (re-verify SHAs — main may move from parallel sessions), suite green on main, push accepted, canonical app relaunched from main.
