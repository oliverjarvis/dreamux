import Foundation

/// How Dreamux gets its hooks in front of a harness.
///
/// `processInjection` — a PATH shim `exec`s the real binary with hook
/// config passed inline, per invocation. Writes nothing to disk.
/// `userConfigBlock` — a marker-delimited block written into the
/// harness's own global config file, behind explicit user consent.
///
/// A third strategy (`configDirOverlay`, redirecting `CODEX_HOME`-style
/// env vars at a Dreamux-managed overlay) is deliberately absent: no
/// harness needing it is installed, so it would ship untested.
enum InjectionStrategy: String, Codable, Sendable {
    case processInjection
    case userConfigBlock
}

/// One entry in a harness's event table: what attention state a hook
/// event means, and where in the payload its human-readable body lives.
struct AttentionTransition: Codable, Equatable, Sendable {
    /// "none" | "working" | "done" | "blocked".
    let state: String
    /// `Blocked.Reason` raw value. Only meaningful when `state` is
    /// "blocked".
    let reason: String?
    /// Payload key to lift the notification body from. Falls back to
    /// "message" when absent.
    let messageField: String?

    init(state: String, reason: String? = nil, messageField: String? = nil) {
        self.state = state
        self.reason = reason
        self.messageField = messageField
    }
}

/// Everything Dreamux knows about one coding harness. Adding a harness
/// is a record in `Tools/harnesses.json`, not a code change — provided
/// its `strategy` is one Dreamux already implements.
struct HarnessAdapter: Codable, Equatable, Sendable {
    let id: String
    let displayName: String
    let binaryNames: [String]
    let strategy: InjectionStrategy
    /// Keyed by hook event name, optionally suffixed with a payload
    /// discriminator: "Notification:permission_prompt" beats "Notification".
    let events: [String: AttentionTransition]
}

struct HarnessCatalog: Codable, Equatable, Sendable {
    let version: Int
    let harnesses: [HarnessAdapter]

    /// Compiled-in last resort. A missing or corrupt `harnesses.json`
    /// must degrade to the behaviour Dreamux already had, never to
    /// silence.
    static let claudeOnlyFallback = HarnessCatalog(
        version: 1,
        harnesses: [
            HarnessAdapter(
                id: "claude",
                displayName: "Claude Code",
                binaryNames: ["claude"],
                strategy: .processInjection,
                events: [
                    "Notification:permission_prompt": AttentionTransition(state: "blocked", reason: "permission"),
                    "Notification:idle_prompt": AttentionTransition(state: "blocked", reason: "question"),
                    "Notification:agent_needs_input": AttentionTransition(state: "blocked", reason: "subagentInput"),
                    "Notification:elicitation_dialog": AttentionTransition(state: "blocked", reason: "elicitation"),
                    "Notification:agent_completed": AttentionTransition(state: "done"),
                    "PermissionRequest": AttentionTransition(state: "blocked", reason: "permission"),
                    "Stop": AttentionTransition(state: "done", messageField: "last_assistant_message"),
                    "UserPromptSubmit": AttentionTransition(state: "working"),
                    "PreToolUse": AttentionTransition(state: "working"),
                    "SessionEnd": AttentionTransition(state: "none"),
                ]
            )
        ]
    )
}
