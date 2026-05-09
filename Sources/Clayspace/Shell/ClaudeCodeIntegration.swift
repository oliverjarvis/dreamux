import Foundation
import AppKit

/// Writes Claude Code's project-scoped hook config so its `Stop` and
/// `Notification` events route through `clayspace-hook`. Touches only
/// `<project>/.claude/settings.json`; other settings keys are preserved
/// across runs.
@MainActor
enum ClaudeCodeIntegration {
    static var hookExecutablePath: String? {
        let url = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/bin/clayspace-hook")
        return FileManager.default.fileExists(atPath: url.path) ? url.path : nil
    }

    enum InstallError: LocalizedError {
        case hookMissing
        case writeFailed(underlying: Error)

        var errorDescription: String? {
            switch self {
            case .hookMissing:
                return "clayspace-hook is missing from this build of Clayspace.app."
            case .writeFailed(let error):
                return "Couldn't write .claude/settings.json: \(error.localizedDescription)"
            }
        }
    }

    /// Result describes what changed so the caller can show a useful
    /// confirmation message.
    struct InstallResult {
        var settingsPath: String
        var stopInstalled: Bool
        var notificationInstalled: Bool
    }

    @discardableResult
    static func install(into projectRoot: URL) throws -> InstallResult {
        guard let hookPath = hookExecutablePath else {
            throw InstallError.hookMissing
        }

        let fm = FileManager.default
        let claudeDir = projectRoot.appendingPathComponent(".claude", isDirectory: true)
        do {
            try fm.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        } catch {
            throw InstallError.writeFailed(underlying: error)
        }
        let settingsURL = claudeDir.appendingPathComponent("settings.json")

        var settings: [String: Any] = [:]
        if let data = try? Data(contentsOf: settingsURL),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            settings = parsed
        }

        var hooks = settings["hooks"] as? [String: Any] ?? [:]

        let stopCmd = "\"\(hookPath)\" stop"
        let notifyCmd = "\"\(hookPath)\" notify"

        let stopInstalled = upsertHook(into: &hooks, event: "Stop", command: stopCmd)
        let notificationInstalled = upsertHook(into: &hooks, event: "Notification", command: notifyCmd)

        settings["hooks"] = hooks

        do {
            let data = try JSONSerialization.data(
                withJSONObject: settings,
                options: [.prettyPrinted, .sortedKeys]
            )
            try data.write(to: settingsURL, options: .atomic)
        } catch {
            throw InstallError.writeFailed(underlying: error)
        }

        return InstallResult(
            settingsPath: settingsURL.path,
            stopInstalled: stopInstalled,
            notificationInstalled: notificationInstalled
        )
    }

    /// Adds (or refreshes) Clayspace's entry under a given event without
    /// trampling unrelated entries the user might have. Detection: any
    /// existing inner-hook command containing `clayspace-hook` is treated
    /// as ours and updated in place. Returns `true` if a new entry was
    /// inserted (vs. an existing one being refreshed).
    private static func upsertHook(
        into hooks: inout [String: Any],
        event: String,
        command: String
    ) -> Bool {
        var groups = hooks[event] as? [[String: Any]] ?? []

        // Walk existing groups, find one whose inner hooks reference us.
        for (i, group) in groups.enumerated() {
            var inner = group["hooks"] as? [[String: Any]] ?? []
            var found = false
            for (j, innerHook) in inner.enumerated() {
                if let cmd = innerHook["command"] as? String,
                   cmd.contains("clayspace-hook") {
                    var updated = innerHook
                    updated["type"] = "command"
                    updated["command"] = command
                    inner[j] = updated
                    found = true
                }
            }
            if found {
                var updatedGroup = group
                updatedGroup["hooks"] = inner
                groups[i] = updatedGroup
                hooks[event] = groups
                return false
            }
        }

        // Otherwise append a new group.
        groups.append([
            "matcher": "",
            "hooks": [["type": "command", "command": command]],
        ])
        hooks[event] = groups
        return true
    }
}
