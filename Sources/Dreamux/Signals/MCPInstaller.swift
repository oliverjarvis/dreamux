import Foundation

/// Installs the dreamux-signals MCP bridge into a project's `.mcp.json`
/// (the canonical Claude Code project-level config). Auto-called at
/// agent-session start (planning tab / plan run) so any Dreamux-managed
/// project picks up signal access in Claude Code without manual setup,
/// and exposed for explicit re-install via the SignalsView header button.
///
/// Merge semantics: an existing `.mcp.json` with other servers is
/// preserved verbatim — we only add (or refresh) the `dreamux-signals`
/// entry. If the file is malformed we log + skip rather than
/// clobber the user's work.
enum MCPInstaller {

    enum Status: Equatable {
        /// `.mcp.json` doesn't reference dreamux-signals at all.
        case notInstalled
        /// dreamux-signals entry references a runnable command that
        /// exists. Carries the path so the UI can surface it.
        case installed(commandPath: String)
        /// dreamux-signals entry exists but the command it references
        /// is gone (stale path after a rebuild / repo move).
        case installedButScriptMissing(referencedPath: String)
        /// We couldn't resolve a runnable on this machine —
        /// nothing we can install. Surfaced so the UI can explain.
        case noScriptAvailable
    }

    enum InstallResult: Equatable {
        case alreadyInstalled
        case installed(commandPath: String)
        case skippedNoScript
        case skippedReason(String)
    }

    /// What the installer chose to wire up. Compiled binary is
    /// preferred — single self-contained executable with no PATH
    /// dependencies, perfect for Claude Code's stripped-spawn
    /// environment. The bun + `.ts` form is the dev-tree fallback
    /// when the binary hasn't been bundled into Resources/ yet.
    private enum Runner {
        case compiledBinary(String)
        case bunScript(bun: String, script: String)
    }

    /// User-overridable script path. Set to "" or unset to use the
    /// default resolution chain.
    static let scriptPathDefaultsKey = "dreamux.signals.mcpScriptPath"

    /// User-overridable bun binary path. Same chain as the script
    /// override — set to skip auto-discovery.
    static let bunPathDefaultsKey = "dreamux.signals.mcpBunPath"

    /// Resolve a runnable for the MCP server. Compiled binary first
    /// (self-contained, no PATH deps) and bun + `.ts` second.
    /// Returns nil when neither path exists on this machine.
    private static func resolveRunner() -> Runner? {
        let fm = FileManager.default

        // 1. Bundled compiled binary at
        //    `<.app>/Contents/Resources/bin/dreamux-signals-mcp`.
        //    Produced by `scripts/build-mcp-server.sh` via the
        //    Xcode "Build dreamux-signals MCP" Run Script phase.
        if let resources = Bundle.main.resourceURL {
            let binary = resources
                .appendingPathComponent("bin/dreamux-signals-mcp").path
            if fm.isExecutableFile(atPath: binary) {
                return .compiledBinary(binary)
            }
        }

        // 2. Fall back to `bun + .ts script` for dev environments
        //    where the build phase didn't run (or bun wasn't on the
        //    build machine and the phase skipped).
        if let script = resolveScriptPath() {
            return .bunScript(bun: resolveBunPath(), script: script)
        }
        return nil
    }

    /// Resolve the dreamux-signals MCP script's absolute `.ts` path.
    /// Order:
    ///   1. UserDefaults override (`signals.mcp.scriptPath`).
    ///   2. The running app's Resources bundle —
    ///      `<.app>/Contents/Resources/mcp/dreamux-signals-mcp.ts`.
    ///   3. Known dev locations under `~/Development/clayspace/`,
    ///      `~/Development/dreamux/`, etc.
    /// Returns nil when none of the above produces a readable file.
    static func resolveScriptPath() -> String? {
        let fm = FileManager.default

        if let override = UserDefaults.standard.string(forKey: scriptPathDefaultsKey),
           !override.isEmpty,
           fm.fileExists(atPath: override) {
            return override
        }

        if let resources = Bundle.main.resourceURL {
            let bundled = resources.appendingPathComponent("mcp/dreamux-signals-mcp.ts").path
            if fm.fileExists(atPath: bundled) { return bundled }
        }

        let home = NSHomeDirectory()
        let candidates = [
            "\(home)/Development/clayspace/mcp/dreamux-signals-mcp.ts",
            "\(home)/Development/dreamux/mcp/dreamux-signals-mcp.ts",
            "\(home)/.dreamux/mcp/dreamux-signals-mcp.ts",
        ]
        for c in candidates where fm.fileExists(atPath: c) {
            return c
        }
        return nil
    }

    /// Resolve the **absolute path** of a runnable `bun` binary on
    /// this machine. Critical for `.mcp.json` to work: Claude Code
    /// spawns MCP servers with a stripped PATH (no `~/.asdf/shims`,
    /// no `~/.bun/bin`), so `"command": "bun"` fails to resolve and
    /// the asdf shim itself can't `exec asdf` either. Probing for
    /// the real binary sidesteps both.
    ///
    /// Order:
    ///   1. UserDefaults override.
    ///   2. Common installer paths: `~/.bun/bin/bun` (official),
    ///      `/opt/homebrew/bin/bun`, `/usr/local/bin/bun`.
    ///   3. asdf installs (`~/.asdf/installs/bun/<ver>/bin/bun`) —
    ///      pick the lexicographically last (≈ newest semver) entry.
    /// Falls back to `"bun"` (no absolute path) if nothing resolves —
    /// the resulting `.mcp.json` may still work for users whose
    /// Claude Code session inherits a richer PATH.
    static func resolveBunPath() -> String {
        let fm = FileManager.default

        if let override = UserDefaults.standard.string(forKey: bunPathDefaultsKey),
           !override.isEmpty,
           fm.isExecutableFile(atPath: override) {
            return override
        }

        let home = NSHomeDirectory()
        let direct = [
            "\(home)/.bun/bin/bun",
            "/opt/homebrew/bin/bun",
            "/usr/local/bin/bun",
        ]
        for c in direct where fm.isExecutableFile(atPath: c) {
            return c
        }

        // asdf: scan installed versions and pick the newest.
        let asdfRoot = "\(home)/.asdf/installs/bun"
        if let versions = try? fm.contentsOfDirectory(atPath: asdfRoot) {
            let sorted = versions.sorted(by: >)  // lexicographic, ≈ newest first
            for v in sorted {
                let path = "\(asdfRoot)/\(v)/bin/bun"
                if fm.isExecutableFile(atPath: path) {
                    return path
                }
            }
        }

        return "bun"
    }

    /// Inspect a project's `.mcp.json` and report whether the
    /// dreamux-signals bridge is wired up correctly. Cheap; safe to
    /// call from a SwiftUI view's body.
    static func status(at projectDir: String) -> Status {
        let runnerAvailable = resolveRunner() != nil
        let fallbackStatus: Status = runnerAvailable ? .notInstalled : .noScriptAvailable

        let url = mcpFile(at: projectDir)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return fallbackStatus
        }
        guard let dict = readJSON(url: url) else {
            return fallbackStatus
        }
        guard let servers = dict["mcpServers"] as? [String: Any],
              let entry = servers["dreamux-signals"] as? [String: Any] else {
            return fallbackStatus
        }
        // Two shapes we recognize: compiled binary form
        // `{ command: <abs path> }` (no args) and bun-script form
        // `{ command: <bun>, args: ["run", <script>] }`.
        if let args = entry["args"] as? [String], let scriptArg = args.last, !scriptArg.isEmpty {
            if FileManager.default.fileExists(atPath: scriptArg) {
                return .installed(commandPath: scriptArg)
            } else {
                return .installedButScriptMissing(referencedPath: scriptArg)
            }
        }
        if let command = entry["command"] as? String, !command.isEmpty {
            if FileManager.default.fileExists(atPath: command) {
                return .installed(commandPath: command)
            } else {
                return .installedButScriptMissing(referencedPath: command)
            }
        }
        return fallbackStatus
    }

    /// Idempotent install. Writes / merges `.mcp.json` so that the
    /// `dreamux-signals` MCP server entry points at the bundled
    /// compiled binary (preferred) or the dev `.ts` script
    /// (fallback). Returns what we did.
    ///
    /// Two distinct directories are in play and must not be conflated:
    /// - Parameters:
    ///   - installDir: where `.mcp.json` lands — the directory the
    ///     agent session runs in (Claude Code discovers project-level
    ///     MCP config from its cwd). For plan runs this is the feature
    ///     aggregation dir (`<project>/features/<branch>`), not the
    ///     project root.
    ///   - projectScope: the project ROOT every signal is tagged with
    ///     (the `project_dir` tag, see ProjectSession). Written as the
    ///     server's `DREAMUX_PROJECT_DIR` env so the MCP bridge's
    ///     queries and `signals_emit` auto-tags line up with the app's
    ///     own signals. Defaults to `installDir` for the common case
    ///     where the agent runs at the project root; pass it whenever
    ///     the install dir is a subdirectory, or the agent's signal
    ///     reads come back empty and its emits never surface in the
    ///     app's Signals page.
    ///   - force: when true, rewrites even if an existing
    ///     entry already references a working file. The manual
    ///     "Install MCP" / "MCP ready" button passes this so it
    ///     upgrades a still-running `.ts`-form entry to the bundled
    ///     binary. Auto-install at env init defaults to `false` to
    ///     avoid `git status` churn for committed `.mcp.json` files.
    @discardableResult
    static func installIfNeeded(
        at installDir: String,
        projectScope: String? = nil,
        force: Bool = false
    ) -> InstallResult {
        guard let runner = resolveRunner() else {
            return .skippedNoScript
        }
        let url = mcpFile(at: installDir)

        var rootDict: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: url.path) {
            if let existing = readJSON(url: url) {
                rootDict = existing
            } else {
                return .skippedReason("existing .mcp.json failed to parse; not overwriting")
            }
        }

        // Walk-or-create the `mcpServers` map.
        var servers = (rootDict["mcpServers"] as? [String: Any]) ?? [:]
        // Don't overwrite an existing `dreamux-signals` entry that
        // *already works* — its referenced command/script resolves
        // to a file on disk. This keeps us from rewriting checked-in
        // `.mcp.json` entries on every env init (which would create
        // git churn). Only auto-write when the entry is missing,
        // its reference is stale, or `force` was set.
        if !force,
           let existing = servers["dreamux-signals"] as? [String: Any],
           let referenced = referencedFile(in: existing),
           FileManager.default.fileExists(atPath: referenced) {
            return .alreadyInstalled
        }

        let desired: [String: Any]
        let installedPath: String
        let env = ["DREAMUX_PROJECT_DIR": projectScope ?? installDir]
        switch runner {
        case .compiledBinary(let path):
            desired = ["command": path, "env": env]
            installedPath = path
        case .bunScript(let bun, let script):
            desired = [
                "command": bun,
                "args": ["run", script],
                "env": env,
            ]
            installedPath = script
        }
        servers["dreamux-signals"] = desired
        rootDict["mcpServers"] = servers

        do {
            // Pretty-print with stable key ordering so the file
            // doesn't churn on every install. JSONSerialization's
            // .sortedKeys handles the latter.
            let data = try JSONSerialization.data(
                withJSONObject: rootDict,
                options: [.prettyPrinted, .sortedKeys]
            )
            try ensureParentDirectory(for: url)
            try data.write(to: url, options: [.atomic])
        } catch {
            return .skippedReason("failed to write .mcp.json: \(error.localizedDescription)")
        }
        return .installed(commandPath: installedPath)
    }

    /// Resolve the on-disk file an existing `dreamux-signals` entry
    /// actually references. For the compiled-binary form that's
    /// `command`; for the bun-script form it's `args.last`.
    private static func referencedFile(in entry: [String: Any]) -> String? {
        if let args = entry["args"] as? [String], let last = args.last, !last.isEmpty {
            return last
        }
        if let command = entry["command"] as? String, !command.isEmpty {
            return command
        }
        return nil
    }

    // MARK: - Helpers

    private static func mcpFile(at projectDir: String) -> URL {
        URL(fileURLWithPath: projectDir).appendingPathComponent(".mcp.json")
    }

    private static func readJSON(url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let obj = try? JSONSerialization.jsonObject(with: data, options: []) else { return nil }
        return obj as? [String: Any]
    }

    private static func ensureParentDirectory(for url: URL) throws {
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: true
        )
    }

}
