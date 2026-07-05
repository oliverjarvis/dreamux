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

    /// Verbatim shape of every cached stripe skill: `description: >-`
    /// folds its indented continuation into one space-joined line, and
    /// a nested `metadata:` map's indented children (even ones with
    /// their own colon) must NOT surface as top-level keys.
    func testParseFrontmatterFoldedScalarAndNestedMap() {
        let text = """
        ---
        name: stripe-directory
        description: >-
          Use when the user wants to find businesses, software, service providers, or
          partners for a specific industry, workflow, pain point, capability, or job to
          be done. Also use when the agent needs to programmatically purchase or consume
          a service. Use Stripe Directory to build a short relevant shortlist, even if
          the user does not mention Stripe Directory explicitly.
        metadata:
          short-description: Find (and optionally purchase from) vendors or partners
        allowed-tools:
          - Bash(stripe directory *)

        ---
        """
        let fm = LibraryScanner.parseFrontmatter(text)
        XCTAssertEqual(fm["name"], "stripe-directory")
        XCTAssertEqual(fm["description"], """
        Use when the user wants to find businesses, software, service providers, or \
        partners for a specific industry, workflow, pain point, capability, or job to \
        be done. Also use when the agent needs to programmatically purchase or consume \
        a service. Use Stripe Directory to build a short relevant shortlist, even if \
        the user does not mention Stripe Directory explicitly.
        """)
        XCTAssertNil(fm["short-description"], "nested metadata children must not become top-level keys")
    }

    /// A folded scalar (`>-`) whose continuation includes a line with
    /// its own colon — that colon must not be mistaken for a new key,
    /// and the line must still be folded into the value.
    func testParseFrontmatterFoldedScalarContinuationWithColon() {
        let text = """
        ---
        name: sample
        description: >-
          First line of the description.
          Second line has a colon: like this in it.
        ---
        """
        let fm = LibraryScanner.parseFrontmatter(text)
        XCTAssertEqual(fm["description"],
                       "First line of the description. Second line has a colon: like this in it.")
        XCTAssertNil(fm["colon"], "a colon inside a folded continuation line must not create a key")
    }

    /// A literal block (`|`) joins its continuation lines with newlines
    /// instead of folding them into one line.
    func testParseFrontmatterLiteralBlock() {
        let text = """
        ---
        name: sample
        notes: |
          line one
          line two
        ---
        """
        let fm = LibraryScanner.parseFrontmatter(text)
        XCTAssertEqual(fm["notes"], "line one\nline two")
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
        let pluginInstallPath = home.appendingPathComponent(".claude/plugins/cache/mkt/superpowers/1.0.0")
        try makeSkill(
            at: pluginInstallPath.appendingPathComponent("skills"),
            name: "plugin-skill", description: "plugin one")

        let items = LibraryScanner.scanSkills(
            projectRoot: project, home: home,
            plugins: [PluginInstall(name: "superpowers", installPath: pluginInstallPath,
                                     version: "1.0.0", accessible: true, accessReason: "reachable")])

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
        let installPath = home.appendingPathComponent(".claude/plugins/cache/mkt/other/2.0")
        try makeSkill(
            at: installPath.appendingPathComponent("skills"),
            name: "locked", description: "elsewhere")
        let items = LibraryScanner.scanSkills(
            projectRoot: project, home: home,
            plugins: [PluginInstall(name: "other", installPath: installPath,
                                     version: "2.0", accessible: false, accessReason: "elsewhere")])
        XCTAssertEqual(items.count, 1)
        XCTAssertFalse(items[0].accessible)
        XCTAssertFalse(items[0].accessReason.isEmpty)
    }

    /// Regression: the registry can reference an OLDER cached version
    /// while a newer directory for the same skill also sits in
    /// cache/<mkt>/<plugin>/* (from a prior update, or another project
    /// pinned to a different version). Only the registry's resolved
    /// installPath may be scanned — never every cached version — so
    /// each skill appears exactly once, from the registry's path.
    func testScanSkillsOnlyReadsRegistrysResolvedVersionNotEveryCachedVersion() throws {
        let project = dir.appendingPathComponent("proj")
        let home = dir.appendingPathComponent("home")
        let pluginRoot = home.appendingPathComponent(".claude/plugins/cache/mkt/stripe")
        let registryVersionPath = pluginRoot.appendingPathComponent("1.0")
        let staleVersionPath = pluginRoot.appendingPathComponent("2.0")
        try makeSkill(at: registryVersionPath.appendingPathComponent("skills"),
                      name: "stripe-directory", description: "registry version")
        try makeSkill(at: staleVersionPath.appendingPathComponent("skills"),
                      name: "stripe-directory", description: "stale cached version")

        let items = LibraryScanner.scanSkills(
            projectRoot: project, home: home,
            plugins: [PluginInstall(name: "stripe", installPath: registryVersionPath,
                                     version: "1.0", accessible: true, accessReason: "reachable")])

        let matches = items.filter { $0.name == "stripe-directory" }
        XCTAssertEqual(matches.count, 1, "must not scan every cached version directory")
        // Resolve both sides: /tmp is itself a symlink into /private on
        // macOS, and FileManager's directory enumeration returns the
        // canonicalized form while our hand-built URL doesn't.
        let matchedPath = matches[0].path.resolvingSymlinksInPath().path
        let registryPath = registryVersionPath.resolvingSymlinksInPath().path
        XCTAssertTrue(matchedPath.hasPrefix(registryPath),
                      "the item's path must come from the registry's resolved installPath")
        XCTAssertFalse(matchedPath.contains("/2.0/"),
                       "must not fall back to another cached version's directory")
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
            plugins: [])
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
            plugins: [])
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

    /// HTTP-style servers (`"url"` instead of `"command"`) surface a
    /// `url:` line in the detail panel.
    func testScanMCPServersHTTPEntryShowsURLDetail() throws {
        let project = dir.appendingPathComponent("proj")
        let home = dir.appendingPathComponent("home")
        try writeJSON(["mcpServers": [
            "hosted": ["url": "https://example.com/mcp"],
        ]], to: project.appendingPathComponent(".mcp.json"))

        let items = LibraryScanner.scanMCPServers(projectRoot: project, home: home)
        let hosted = items.first { $0.name == "hosted" }
        XCTAssertTrue(hosted!.detail.contains("url: https://example.com/mcp"))
    }

    /// `disabledMcpjsonServers` governs project/feature-dir .mcp.json
    /// entries only — a GLOBAL server (~/.claude.json top-level map)
    /// sharing a name with a disabled project server must stay
    /// accessible; the disabling is scoped, not name-global.
    func testScanMCPServersGlobalNotAffectedByProjectDisable() throws {
        let project = dir.appendingPathComponent("proj")
        let home = dir.appendingPathComponent("home")
        try writeJSON(["mcpServers": ["shared-name": ["command": "/project-one"]]],
                      to: project.appendingPathComponent(".mcp.json"))
        try writeJSON(["disabledMcpjsonServers": ["shared-name"]],
                      to: project.appendingPathComponent(".claude/settings.local.json"))
        try writeJSON(["mcpServers": ["shared-name": ["command": "/global-one"]]],
                      to: home.appendingPathComponent(".claude.json"))

        let items = LibraryScanner.scanMCPServers(projectRoot: project, home: home)
        let byScope = Dictionary(uniqueKeysWithValues: items.map { ($0.scopeLabel, $0) })
        XCTAssertEqual(byScope["Project"]?.accessible, false)
        XCTAssertEqual(byScope["Global"]?.accessible, true,
                       "a global server must not inherit a project-scoped disable")
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
                // Fix 3: an entry ordered BEFORE the access-granting one
                // must not win — the chosen entry (and its version/path)
                // is the one that actually grants access, in list order.
                "ordered@official": [
                    [
                        "scope": "project",
                        "projectPath": "/somewhere/else/Fur",
                        "installPath": home.appendingPathComponent(".claude/plugins/cache/official/ordered/1.0").path,
                        "version": "1.0",
                    ],
                    [
                        "scope": "user",
                        "installPath": home.appendingPathComponent(".claude/plugins/cache/official/ordered/2.0").path,
                        "version": "2.0",
                    ],
                ],
            ],
        ], to: home.appendingPathComponent(".claude/plugins/installed_plugins.json"))

        let items = LibraryScanner.scanPlugins(projectRoot: project, home: home)
        let byName = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0) })
        XCTAssertEqual(byName["superpowers"]?.accessible, true)
        XCTAssertEqual(byName["here-only"]?.accessible, true)
        XCTAssertEqual(byName["elsewhere"]?.accessible, false)
        XCTAssertTrue(byName["superpowers"]!.detail.contains { $0.contains("6.1.0") })
        XCTAssertTrue(byName["elsewhere"]!.accessReason.contains("else"),
                      "denied reason should name the project(s) the plugin belongs to")

        let ordered = byName["ordered"]!
        XCTAssertTrue(ordered.detail.contains { $0.contains("2.0") })
        XCTAssertEqual(ordered.path,
                       home.appendingPathComponent(".claude/plugins/cache/official/ordered/2.0"))

        let accessible = LibraryScanner.accessiblePluginNames(projectRoot: project, home: home)
        XCTAssertEqual(accessible, ["superpowers", "here-only", "ordered"])
    }

    /// Fix 5: the denied reason names the project(s) the plugin is
    /// actually installed for, using the projectPath basename.
    func testScanPluginsDeniedReasonNamesTheProject() throws {
        let project = dir.appendingPathComponent("proj")
        let home = dir.appendingPathComponent("home")
        try writeJSON([
            "version": 2,
            "plugins": [
                "typescript-lsp@official": [[
                    "scope": "project",
                    "projectPath": "/Users/olliejarvis/Development/Fur",
                    "installPath": home.appendingPathComponent(".claude/plugins/cache/official/typescript-lsp/1.0").path,
                    "version": "1.0",
                ]],
            ],
        ], to: home.appendingPathComponent(".claude/plugins/installed_plugins.json"))

        let items = LibraryScanner.scanPlugins(projectRoot: project, home: home)
        XCTAssertEqual(items.first?.accessReason, "Installed for Fur only")
    }

    /// Fix 4: an installed plugin explicitly disabled via
    /// `enabledPlugins` in the PROJECT's settings.local.json is
    /// inaccessible even though its install scope would otherwise
    /// grant access.
    func testScanPluginsDisabledByProjectSettingsLocal() throws {
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
            ],
        ], to: home.appendingPathComponent(".claude/plugins/installed_plugins.json"))
        try writeJSON(
            ["enabledPlugins": ["superpowers@official": false]],
            to: project.appendingPathComponent(".claude/settings.local.json"))

        let items = LibraryScanner.scanPlugins(projectRoot: project, home: home)
        let superpowers = items.first { $0.name == "superpowers" }
        XCTAssertEqual(superpowers?.accessible, false)
        XCTAssertEqual(superpowers?.accessReason, "Disabled in Claude settings")
    }

    /// Fix 5: `.claude-plugin/plugin.json` at the resolved installPath
    /// fills the description (and the version, when the registry says
    /// "unknown") — missing file falls back to today's empty behavior.
    func testScanPluginsReadsPluginJSONForDescriptionAndVersion() throws {
        let project = dir.appendingPathComponent("proj")
        let home = dir.appendingPathComponent("home")
        let installPath = home.appendingPathComponent(".claude/plugins/cache/official/stripe/0.2.2")
        try writeJSON([
            "version": 2,
            "plugins": [
                "stripe@official": [[
                    "scope": "user",
                    "installPath": installPath.path,
                    "version": "unknown",
                ]],
            ],
        ], to: home.appendingPathComponent(".claude/plugins/installed_plugins.json"))
        try writeJSON([
            "name": "stripe",
            "description": "Stripe development plugin for Claude",
            "version": "0.2.2",
        ], to: installPath.appendingPathComponent(".claude-plugin/plugin.json"))

        let items = LibraryScanner.scanPlugins(projectRoot: project, home: home)
        let stripe = items.first { $0.name == "stripe" }
        XCTAssertEqual(stripe?.description, "Stripe development plugin for Claude")
        XCTAssertTrue(stripe!.detail.contains { $0.contains("0.2.2") })
    }
}
