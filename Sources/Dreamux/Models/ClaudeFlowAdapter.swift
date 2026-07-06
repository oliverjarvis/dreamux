import Foundation

/// A tool-agnostic lifecycle event consumed by FlowStore. Adapters
/// produce these; nothing downstream knows where they came from.
enum FlowEvent: Equatable, Sendable {
    case agentStarted(sessionID: String, agentID: String, agentType: String?, description: String?, cwd: String?, at: Date)
    case agentStopped(sessionID: String, agentID: String, cwd: String?, at: Date)
    case taskCreated(sessionID: String, taskID: String?, subject: String?, cwd: String?, at: Date)
    case taskCompleted(sessionID: String, taskID: String?, cwd: String?, at: Date)
    case sessionStopped(sessionID: String, cwd: String?, at: Date)
    case notification(sessionID: String, message: String?, cwd: String?, at: Date)

    var at: Date {
        switch self {
        case let .agentStarted(_, _, _, _, _, at), let .agentStopped(_, _, _, at),
             let .taskCreated(_, _, _, _, at), let .taskCompleted(_, _, _, at),
             let .sessionStopped(_, _, at), let .notification(_, _, _, at):
            return at
        }
    }

    var cwd: String? {
        switch self {
        case let .agentStarted(_, _, _, _, cwd, _), let .agentStopped(_, _, cwd, _),
             let .taskCreated(_, _, _, cwd, _), let .taskCompleted(_, _, cwd, _),
             let .sessionStopped(_, cwd, _), let .notification(_, _, cwd, _):
            return cwd
        }
    }
}

/// The ONLY place that knows how claude's hook payloads are shaped.
/// (Registry parsing lives in ClaudeSessionRegistry; transcript
/// parsing arrives with Group 3 and lives here too.)
enum ClaudeFlowAdapter {
    /// nil for signals that aren't flow lifecycle events or that are
    /// missing the session id — never throws, never logs per-signal.
    static func event(from signal: Signal) -> FlowEvent? {
        guard case let .object(fields) = signal.payload else { return nil }
        guard let sessionID = string(fields["session_id"]), !sessionID.isEmpty else { return nil }
        let cwd = signal.tags["cwd"].flatMap { $0.isEmpty ? nil : $0 }
        let at = signal.ts

        switch signal.kind {
        case SignalKind.agentStarted:
            guard let agentID = string(fields["agent_id"]) else { return nil }
            return .agentStarted(
                sessionID: sessionID,
                agentID: agentID,
                agentType: string(fields["agent_type"]),
                description: string(fields["description"]),
                cwd: cwd,
                at: at
            )
        case SignalKind.agentStopped:
            guard let agentID = string(fields["agent_id"]) else { return nil }
            return .agentStopped(sessionID: sessionID, agentID: agentID, cwd: cwd, at: at)
        case SignalKind.taskCreated:
            return .taskCreated(
                sessionID: sessionID,
                taskID: string(fields["task_id"]),
                subject: string(fields["subject"]),
                cwd: cwd,
                at: at
            )
        case SignalKind.taskCompleted:
            return .taskCompleted(sessionID: sessionID, taskID: string(fields["task_id"]), cwd: cwd, at: at)
        case SignalKind.sessionStopped:
            return .sessionStopped(sessionID: sessionID, cwd: cwd, at: at)
        case SignalKind.sessionNotification:
            return .notification(sessionID: sessionID, message: string(fields["message"]), cwd: cwd, at: at)
        default:
            return nil
        }
    }

    private static func string(_ payload: SignalPayload?) -> String? {
        if case let .string(s)? = payload, !s.isEmpty { return s }
        return nil
    }
}
