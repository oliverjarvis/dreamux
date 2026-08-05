import Foundation

/// Why an agent has stopped and handed control back to the user.
struct Blocked: Equatable, Sendable {
    enum Reason: String, Codable, Sendable {
        /// A tool call needs a permission decision.
        case permission
        /// The agent asked a question, or is idle waiting for the next
        /// instruction.
        case question
        /// An MCP server is requesting input.
        case elicitation
        /// A subagent needs user input.
        case subagentInput
    }

    let reason: Reason
    let message: String?
    let toolName: String?
    /// The harness's own identifier for the request this state
    /// describes — Claude Code supplies `tool_use_id` on
    /// `PermissionRequest`. Notification actions compare against this so
    /// a stale banner cannot answer a prompt that has already moved on.
    let requestID: String?
}

/// What one agent surface wants from you.
///
/// The distinction that earns this type: `blocked` means you are the
/// critical path, `done` means a turn ended and nothing is waiting. A
/// single "unread" boolean conflates them, which is why the old red dot
/// told you nothing worth acting on.
enum AgentAttention: Equatable, Sendable {
    case none
    case working
    case done(message: String?)
    case blocked(Blocked)

    /// Aggregation precedence: blocked > done > working > none.
    var rank: Int {
        switch self {
        case .blocked: return 3
        case .done: return 2
        case .working: return 1
        case .none: return 0
        }
    }

    var isBlocked: Bool {
        if case .blocked = self { return true }
        return false
    }

    var message: String? {
        switch self {
        case .done(let message): return message
        case .blocked(let blocked): return blocked.message
        case .working, .none: return nil
        }
    }

    /// Decode the body of a `agent-state` control OSC. Returns nil for
    /// anything unrecognized — a control event we cannot parse must
    /// never become a banner.
    init?(controlPayload: [String: Any]) {
        func text(_ key: String) -> String? {
            guard let value = controlPayload[key] as? String, !value.isEmpty else { return nil }
            return value
        }
        switch controlPayload["state"] as? String {
        case "none":
            self = .none
        case "working":
            self = .working
        case "done":
            self = .done(message: text("message"))
        case "blocked":
            // An unrecognized reason still means the user is blocked;
            // degrade to the general case rather than dropping it.
            let reason = Blocked.Reason(rawValue: text("reason") ?? "") ?? .question
            self = .blocked(Blocked(
                reason: reason,
                message: text("message"),
                toolName: text("tool"),
                requestID: text("request_id")
            ))
        default:
            return nil
        }
    }
}

/// Roll several tabs' attention up into one workspace-level state.
/// A free function rather than a method so it is testable without
/// standing up a session.
enum AttentionAggregate {
    static func combine(_ states: [AgentAttention]) -> AgentAttention {
        states.max { $0.rank < $1.rank } ?? .none
    }
}
