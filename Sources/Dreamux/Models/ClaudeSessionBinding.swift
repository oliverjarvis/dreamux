import Foundation
import Observation

/// Per-tab binding to a live Claude Code session. Consumes the control
/// events dreamux-hook writes into this tab's own PTY (session-start /
/// session-end / notify / stop) and backstops liveness against the
/// session registry file. The chat face renders this object; the write
/// path gates on `phase` — never blind-type.
@MainActor
@Observable
final class ClaudeSessionBinding {
    enum Phase: String, Equatable, Sendable {
        case unbound, working, waitingForUser, idle, ended
    }

    private(set) var phase: Phase = .unbound
    private(set) var sessionID: String?
    private(set) var claudePID: Int?
    private(set) var conversation: LiveConversation?
    /// Latest Notification-hook message (permission request / idle
    /// nudge) — these never appear in the transcript. Cleared when a
    /// turn completes or a new session binds.
    private(set) var lastNotification: String?
    /// Sticky: keeps the face toggle visible after a session ends.
    private(set) var hasEverBound = false

    var isBound: Bool { phase != .unbound && phase != .ended }

    /// `~/.claude/sessions` unless overridden (tests set it directly;
    /// e2e launches the app with DREAMUX_SESSIONS_DIR).
    var registryDirectory: URL = {
        if let override = ProcessInfo.processInfo.environment["DREAMUX_SESSIONS_DIR"] {
            return URL(fileURLWithPath: override)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/sessions")
    }()

    @ObservationIgnored private var registryTimer: Timer?
    /// True once a registry entry for this session has been read —
    /// gates death-detection so a not-yet-written registry isn't death.
    @ObservationIgnored private var registryEntrySeen = false

    func handleControl(verb: String, json: Data) {
        let payload = ((try? JSONSerialization.jsonObject(with: json)) as? [String: Any]) ?? [:]
        switch verb {
        case "session-start":
            guard let sessionID = payload["session_id"] as? String, !sessionID.isEmpty else { return }
            bind(sessionID: sessionID, payload: payload)
        case "session-end":
            end()
        case "notify":
            guard isBound else { return }
            if let message = payload["message"] as? String, !message.isEmpty {
                lastNotification = message
            }
            phase = .waitingForUser
        case "stop":
            guard isBound else { return }
            phase = .idle
            lastNotification = nil
        default:
            break // forward-compatible: unknown verbs are future protocol
        }
    }

    /// Test seam + timer body: reconcile phase against the registry.
    /// The registry file is named by claude's pid, but the pid the hook
    /// reports (its getppid) can be an intermediate shell's — so fall
    /// back to scanning the directory for our sessionId, and only treat
    /// a MISSING entry as death after we've actually seen one (the
    /// registry may simply not be written yet at bind time).
    func pollRegistryNow() {
        guard isBound else { return }
        guard let entry = registryEntry() else {
            if registryEntrySeen { end() }
            return
        }
        registryEntrySeen = true
        switch entry["status"] as? String {
        case "busy": phase = .working
        case "waiting": phase = .waitingForUser
        case "idle": phase = .idle
        default: break
        }
    }

    /// The registry dict for OUR session: the claimed-pid file if it
    /// matches our sessionId, else the first directory entry that does.
    private func registryEntry() -> [String: Any]? {
        func load(_ url: URL) -> [String: Any]? {
            guard let data = try? Data(contentsOf: url),
                  let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else { return nil }
            if let registrySession = dict["sessionId"] as? String,
               let bound = sessionID, registrySession != bound {
                return nil // different/stale session — not ours
            }
            return dict
        }
        if let pid = claudePID,
           let dict = load(registryDirectory.appendingPathComponent("\(pid).json")) {
            return dict
        }
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: registryDirectory, includingPropertiesForKeys: nil) else { return nil }
        for file in files where file.pathExtension == "json" {
            if let dict = load(file) { return dict }
        }
        return nil
    }

    private func bind(sessionID: String, payload: [String: Any]) {
        conversation?.stop()
        self.sessionID = sessionID
        claudePID = payload["claude_pid"] as? Int
        lastNotification = nil
        registryEntrySeen = false
        hasEverBound = true
        if let path = payload["transcript_path"] as? String, !path.isEmpty {
            conversation = LiveConversation(url: URL(fileURLWithPath: path))
        } else {
            conversation = nil
        }
        phase = .working
        registryTimer?.invalidate()
        registryTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollRegistryNow() }
        }
    }

    private func end() {
        guard phase != .ended else { return }
        phase = .ended
        registryTimer?.invalidate()
        registryTimer = nil
        conversation?.stop() // stop tailing; items stay readable
    }
}
