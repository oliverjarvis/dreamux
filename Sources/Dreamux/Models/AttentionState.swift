import Foundation
import Observation

/// One tab's attention state. A separate object rather than a stored
/// property on `TabSession` for the same reason `ClaudeSessionBinding`
/// is: `TabSession` builds its PTY callbacks during `init`, before
/// `self` exists, so the callback has to capture something that already
/// does.
@MainActor
@Observable
final class AttentionState {
    private(set) var value: AgentAttention = .none

    /// Consume a control OSC from `dreamux-hook`. Only `agent-state`
    /// moves attention; every other verb belongs to
    /// `ClaudeSessionBinding` and is ignored here.
    func handleControl(verb: String, json: Data) {
        guard verb == "agent-state" else { return }
        guard let payload = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any],
              let next = AgentAttention(controlPayload: payload)
        else { return }
        value = next
    }

    /// An OSC 9 / OSC 777;notify body from something Dreamux has no
    /// adapter for. It carries a real message, so it is worth a `done`
    /// — but it must never overwrite a live block, because an unadapted
    /// emitter cannot tell us the block has cleared.
    func noteNotification(_ message: String) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !value.isBlocked else { return }
        value = .done(message: trimmed)
    }

    /// Looking at the tab acknowledges a finished turn. It does NOT
    /// acknowledge a block: a permission prompt still sitting on screen
    /// is still blocking you, whether or not you glanced at it. Only the
    /// harness or an explicit dismiss clears that.
    func acknowledgeIfDone() {
        if case .done = value { value = .none }
    }

    /// Explicit user dismissal — clears any state, including a block.
    func dismiss() {
        value = .none
    }
}
