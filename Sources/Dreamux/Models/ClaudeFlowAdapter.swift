import Foundation

struct WorkflowRunArtifacts: Equatable, Sendable {
    let runID: String
    let name: String?
    let phases: [String]

    /// The workflow meta block is required to be a pure literal, so a
    /// line-oriented scan is reliable enough — and when it isn't, we
    /// return nil and the lane simply shows no phase nodes. Degrade,
    /// never break.
    static func parse(scriptText: String, runID: String) -> WorkflowRunArtifacts? {
        guard scriptText.contains("export const meta") else { return nil }
        func firstMatch(_ pattern: String, in text: String) -> String? {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  match.numberOfRanges > 1,
                  let range = Range(match.range(at: 1), in: text)
            else { return nil }
            return String(text[range])
        }
        let name = firstMatch(#"name:\s*['"]([^'"]+)['"]"#, in: scriptText)
        var phases: [String] = []
        if let phasesBlock = firstMatch(#"phases:\s*\[([\s\S]*?)\]"#, in: scriptText) {
            let regex = try? NSRegularExpression(pattern: #"title:\s*['"]([^'"]+)['"]"#)
            let range = NSRange(phasesBlock.startIndex..., in: phasesBlock)
            regex?.enumerateMatches(in: phasesBlock, range: range) { match, _, _ in
                if let match, match.numberOfRanges > 1, let r = Range(match.range(at: 1), in: phasesBlock) {
                    phases.append(String(phasesBlock[r]))
                }
            }
        }
        if name == nil && phases.isEmpty { return nil }
        return WorkflowRunArtifacts(runID: runID, name: name, phases: phases)
    }
}

struct SubagentMeta: Equatable, Sendable {
    let agentID: String
    let agentType: String?
    let description: String?
    let toolUseID: String?
    let spawnDepth: Int?

    /// Filename convention: agent-<id>.meta.json. Tolerant of unknown
    /// keys (team-member metas carry extras) and missing fields.
    static func parse(url: URL) -> SubagentMeta? {
        let name = url.lastPathComponent
        guard name.hasPrefix("agent-"), name.hasSuffix(".meta.json") else { return nil }
        let agentID = String(name.dropFirst("agent-".count).dropLast(".meta.json".count))
        guard !agentID.isEmpty,
              let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return SubagentMeta(
            agentID: agentID,
            agentType: obj["agentType"] as? String,
            description: obj["description"] as? String,
            toolUseID: obj["toolUseId"] as? String,
            spawnDepth: obj["spawnDepth"] as? Int
        )
    }
}

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

enum TranscriptEvent: Equatable, Sendable {
    case toolStarted(toolUseID: String, tool: String, summary: String?, at: Date?)
    case toolFinished(toolUseID: String, isError: Bool, at: Date?)
    case agentSpawned(toolUseID: String, agentType: String?, description: String?, at: Date?)
    // NOTE deliberately no agentReturned case: the parser cannot know
    // whether a tool_result closes an agent — FlowStore's toolUse→agent
    // join map makes that call when it applies toolFinished.
}

extension ClaudeFlowAdapter {
    /// Line cap: a single transcript line (huge pastes, base64 images)
    /// must never balloon parsing. Spec guardrail.
    private static let maxLineBytes = 1_048_576
    private static let agentToolNames: Set<String> = ["Agent", "Task"]

    static func transcriptEvents(fromLines lines: [String]) -> (events: [TranscriptEvent], skipped: Int) {
        var events: [TranscriptEvent] = []
        var skipped = 0
        let isoParser = ISO8601DateFormatter()
        isoParser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoPlain = ISO8601DateFormatter()

        for line in lines {
            if line.isEmpty { continue }
            guard line.utf8.count <= maxLineBytes,
                  let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = obj["type"] as? String
            else { skipped += 1; continue }

            let at = (obj["timestamp"] as? String).flatMap { isoParser.date(from: $0) ?? isoPlain.date(from: $0) }

            switch type {
            case "assistant":
                guard let message = obj["message"] as? [String: Any],
                      let content = message["content"] as? [[String: Any]] else { continue }
                for block in content where (block["type"] as? String) == "tool_use" {
                    guard let id = block["id"] as? String,
                          let name = block["name"] as? String else { continue }
                    let input = block["input"] as? [String: Any] ?? [:]
                    if agentToolNames.contains(name) {
                        events.append(.agentSpawned(
                            toolUseID: id,
                            agentType: input["subagent_type"] as? String,
                            description: input["description"] as? String,
                            at: at
                        ))
                    } else {
                        events.append(.toolStarted(
                            toolUseID: id, tool: name, summary: toolSummary(name: name, input: input), at: at
                        ))
                    }
                }
            case "user":
                guard let message = obj["message"] as? [String: Any],
                      let content = message["content"] as? [[String: Any]] else { continue }
                for block in content where (block["type"] as? String) == "tool_result" {
                    guard let id = block["tool_use_id"] as? String else { continue }
                    let isError = (block["is_error"] as? Bool) ?? false
                    // The store decides agent-vs-tool via its toolUse→agent
                    // join map when applying this event.
                    events.append(.toolFinished(toolUseID: id, isError: isError, at: at))
                }
            default:
                // All other types are silent skips by design — forward compat.
                // `skipped` counts only lines that failed to parse (malformed,
                // oversized, or missing type field), not unknown message types.
                break
            }
        }
        return (events, skipped)
    }

    /// One-line human summary for the inspector's "last activity".
    private static func toolSummary(name: String, input: [String: Any]) -> String? {
        let raw: String?
        switch name {
        case "Bash": raw = input["command"] as? String
        case "Read", "Write", "Edit": raw = input["file_path"] as? String
        default: raw = input["description"] as? String ?? input["prompt"] as? String
        }
        guard let raw, !raw.isEmpty else { return nil }
        let firstLine = raw.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? raw
        return firstLine.count > 120 ? String(firstLine.prefix(120)) + "…" : firstLine
    }

    /// Last-activity summary from a subagent transcript's appended lines:
    /// the most recent toolStarted summary, if any.
    static func lastActivity(fromAgentLines lines: [String]) -> String? {
        let (events, _) = transcriptEvents(fromLines: lines)
        for event in events.reversed() {
            if case let .toolStarted(_, _, summary, _) = event, let summary { return summary }
        }
        return nil
    }
}
