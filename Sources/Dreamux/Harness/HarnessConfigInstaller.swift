import Foundation

/// Writes Dreamux's hook into a harness's own global config file.
///
/// This is the invasive strategy, used only where the harness offers no
/// per-process injection. Every operation is written to be safe on a
/// file Dreamux does not own: back up before the first write, mark our
/// entries so re-install replaces rather than appends, leave every
/// foreign key alone, and refuse outright rather than rewrite a file we
/// cannot parse.
struct HarnessConfigInstaller {
    enum InstallError: Error, Equatable {
        case unreadableConfig
        case unwritableConfig
    }

    /// Cursor CLI's hook event for shell commands — the point at which
    /// it is about to act and might need the user.
    private static let hookKeys = ["cursor": "beforeShellExecution"]

    private func hookKey(for harnessID: String) -> String {
        Self.hookKeys[harnessID] ?? "beforeShellExecution"
    }

    func install(harnessID: String, configURL: URL, hookCommand: String) throws {
        var root = try readRoot(configURL)

        // Back up the pristine file exactly once — a second install
        // would otherwise capture our own edits as "the user's config".
        let backup = configURL.appendingPathExtension("dreamux.bak")
        if FileManager.default.fileExists(atPath: configURL.path),
           !FileManager.default.fileExists(atPath: backup.path) {
            try? FileManager.default.copyItem(at: configURL, to: backup)
        }

        var hooks = root["hooks"] as? [String: Any] ?? [:]
        let key = hookKey(for: harnessID)
        var entries = hooks[key] as? [[String: Any]] ?? []
        entries.removeAll { ($0["dreamux"] as? Bool) == true }
        entries.append([
            "dreamux": true,
            "command": hookCommand,
        ])
        hooks[key] = entries
        root["hooks"] = hooks
        try write(root, to: configURL)
    }

    func uninstall(harnessID: String, configURL: URL) throws {
        guard FileManager.default.fileExists(atPath: configURL.path) else { return }
        var root = try readRoot(configURL)
        guard var hooks = root["hooks"] as? [String: Any] else { return }
        let key = hookKey(for: harnessID)
        guard var entries = hooks[key] as? [[String: Any]] else { return }
        entries.removeAll { ($0["dreamux"] as? Bool) == true }
        hooks[key] = entries
        root["hooks"] = hooks
        try write(root, to: configURL)
    }

    func isInstalled(harnessID: String, configURL: URL) -> Bool {
        guard let root = try? readRoot(configURL),
              let hooks = root["hooks"] as? [String: Any],
              let entries = hooks[hookKey(for: harnessID)] as? [[String: Any]]
        else { return false }
        return entries.contains { ($0["dreamux"] as? Bool) == true }
    }

    private func readRoot(_ url: URL) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        guard let data = try? Data(contentsOf: url) else { throw InstallError.unreadableConfig }
        if data.isEmpty { return [:] }
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw InstallError.unreadableConfig
        }
        return root
    }

    private func write(_ root: [String: Any], to url: URL) throws {
        guard let data = try? JSONSerialization.data(
            withJSONObject: root, options: [.prettyPrinted, .sortedKeys]
        ) else { throw InstallError.unwritableConfig }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
        } catch {
            throw InstallError.unwritableConfig
        }
    }
}
