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

    /// SkillLinker populates worktrees (and the skills.sh CLI populates
    /// project roots) with SYMLINKED skill dirs — a skill present ONLY
    /// via symlink must still be found. The naive dirent isDirectory
    /// check reports false for symlinks-to-directories and silently
    /// dropped every linked skill.
    func testSymlinkOnlySkillIsFound() throws {
        let project = dir.appendingPathComponent("proj")
        let external = dir.appendingPathComponent("elsewhere/skills")
        try makeSkill(at: external, name: "linked-only", description: "via symlink")
        let claudeSkills = project.appendingPathComponent(".claude/skills")
        try FileManager.default.createDirectory(at: claudeSkills, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: claudeSkills.appendingPathComponent("linked-only"),
            withDestinationURL: external.appendingPathComponent("linked-only"))

        let items = LibraryScanner.scanSkills(
            projectRoot: project, home: dir.appendingPathComponent("home"),
            accessiblePlugins: [])
        XCTAssertEqual(items.filter { $0.name == "linked-only" }.count, 1,
                       "symlink-only skills must be enumerated")
    }

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
}
