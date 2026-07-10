import XCTest
@testable import Dreamux

/// Covers two final-review composer-safety fixes:
///
/// 1. The chat composer must never blind-type into a permission dialog —
///    `.waitingForUser` can mean a `Notification` hook fired for a
///    permission request (the transcript stays silent), so `.idle` is
///    the ONLY send-eligible phase.
/// 2. A late `session-end` control event for an already-superseded
///    session (async hook delivery can land the OLD session's end after
///    a NEW session has bound) must not unbind the tab.
///
/// `TabSession()` with no PTY started is established practice (see
/// `ProjectSessionTests.testTerminalViewIsStableAndBoundToItsSurfaceState`)
/// — `send` is a no-op without a running shell, so these tests assert the
/// gate's return VALUE, not any PTY side effect.
@MainActor
final class ChatInputGatingTests: XCTestCase {
    private func control(_ dict: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: dict)
    }

    private func startSession(_ tab: TabSession, sessionID: String = "s-1") {
        tab.binding.handleControl(verb: "session-start", json: control([
            "session_id": sessionID, "transcript_path": "/nonexistent/t.jsonl",
            "claude_pid": 1,
        ]))
    }

    // MARK: - Fix 1: composer gate is `.idle` only

    func testSendChatPromptRefusesWaitingForUserButAllowsIdle() {
        let tab = TabSession()
        startSession(tab)
        XCTAssertEqual(tab.binding.phase, .working)

        // A permission dialog notification lands — phase goes
        // waitingForUser but nothing appears in the transcript. The
        // composer must refuse: typing here would send CR into the
        // dialog, not a chat prompt.
        tab.binding.handleControl(verb: "notify", json: control([
            "message": "Claude needs your permission to use Bash",
        ]))
        XCTAssertEqual(tab.binding.phase, .waitingForUser)
        XCTAssertFalse(
            tab.sendChatPrompt("hello"),
            "waitingForUser can mean a permission dialog is up — never blind-type")

        // The turn completes normally (Stop hook) — composer opens back up.
        tab.binding.handleControl(verb: "stop", json: control(["session_id": "s-1"]))
        XCTAssertEqual(tab.binding.phase, .idle)
        XCTAssertTrue(tab.sendChatPrompt("hello"))
    }

    // MARK: - Fix 2: session-end only unbinds a matching session id

    func testSessionEndIgnoresStaleSessionIDButHonorsCurrentOne() {
        let tab = TabSession()
        startSession(tab, sessionID: "s-1")
        XCTAssertTrue(tab.binding.isBound)

        // A late end event for a session we've since moved past (a stale
        // "s-0" — e.g. the old session's hook delivered after a rebind).
        tab.binding.handleControl(verb: "session-end", json: control(["session_id": "s-0"]))
        XCTAssertNotEqual(tab.binding.phase, .ended)
        XCTAssertTrue(tab.binding.isBound, "a stale session-end must not unbind the current session")

        // The end event for OUR session unbinds normally.
        tab.binding.handleControl(verb: "session-end", json: control(["session_id": "s-1"]))
        XCTAssertEqual(tab.binding.phase, .ended)
    }

    func testSessionEndWithNoSessionIDUnbindsConservatively() {
        let b = ClaudeSessionBinding()
        b.handleControl(verb: "session-start", json: control([
            "session_id": "s-1", "transcript_path": "/nonexistent/t.jsonl",
            "claude_pid": 1,
        ]))
        XCTAssertTrue(b.isBound)

        // No session_id at all in the payload — the conservative fallback:
        // still unbind, rather than risk leaking a dead session as bound.
        b.handleControl(verb: "session-end", json: control([:]))
        XCTAssertEqual(b.phase, .ended)
    }
}
