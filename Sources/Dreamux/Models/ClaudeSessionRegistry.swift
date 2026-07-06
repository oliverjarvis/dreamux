import Foundation

/// Where Claude Code keeps its state. Tests and e2e point
/// DREAMUX_CLAUDE_HOME at a synthetic root; production resolves the
/// real `~/.claude`. Always route through here — never hardcode.
enum ClaudeHome {
    static func root(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let override = environment["DREAMUX_CLAUDE_HOME"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return URL(
            fileURLWithPath: NSString(string: "~/.claude").expandingTildeInPath,
            isDirectory: true
        )
    }
}

/// One running claude process, as advertised in
/// `<claude-home>/sessions/<pid>.json`. Untrusted, evolving input:
/// we decode only the fields we use and skip files that don't parse.
struct ClaudeSessionEntry: Decodable, Equatable, Sendable {
    let pid: Int32
    let sessionId: String
    let cwd: String
    /// Raw registry status: "idle" | "busy" | "waiting" (open set).
    let status: String
    let name: String?
    /// "interactive" | "bg" (open set).
    let kind: String
    let version: String?

    private enum CodingKeys: String, CodingKey {
        case pid, sessionId, cwd, status, name, kind, version
    }

    var isBackground: Bool { kind == "bg" }

    /// busy → running; waiting → waiting (blocked on the human);
    /// idle → done — an idle interactive session has nothing in
    /// flight, and unknown future statuses read as done rather than
    /// inventing activity. (Spec: degrade, never break.)
    var flowStatus: FlowStatus {
        switch status {
        case "busy": return .running
        case "waiting": return .waiting
        default: return .done
        }
    }
}

/// Reads the live-session registry. Pure with respect to its inputs:
/// `home` is injected (synthetic roots in tests) and the liveness
/// probe is injected (no real PIDs needed in tests).
struct ClaudeSessionRegistryReader {
    let home: URL
    let isAlive: (Int32) -> Bool

    init(
        home: URL,
        isAlive: @escaping (Int32) -> Bool = ClaudeSessionRegistryReader.processExists
    ) {
        self.home = home
        self.isAlive = isAlive
    }

    /// `kill(pid, 0)` == "does this process exist" without signaling.
    /// EPERM means it exists but isn't ours — still alive.
    static func processExists(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    /// Every well-formed, live entry under `<home>/sessions/`. Stale
    /// files (dead PIDs) and malformed JSON are silently skipped —
    /// claude cleans its own registry eventually; we don't wait for it.
    func entries() -> [ClaudeSessionEntry] {
        let dir = home.appendingPathComponent("sessions", isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil
        ) else { return [] }
        let decoder = JSONDecoder()
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> ClaudeSessionEntry? in
                guard let data = try? Data(contentsOf: url),
                      let entry = try? decoder.decode(ClaudeSessionEntry.self, from: data)
                else { return nil }
                return isAlive(entry.pid) ? entry : nil
            }
    }
}
