import XCTest
@testable import Dreamux

@MainActor
final class ClaudeSessionBindingTests: XCTestCase {
    private func control(_ dict: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: dict)
    }

    func testBindUnbindLifecycle() {
        let b = ClaudeSessionBinding()
        XCTAssertEqual(b.phase, .unbound)
        XCTAssertFalse(b.hasEverBound)

        b.handleControl(verb: "session-start", json: control([
            "session_id": "s-1", "transcript_path": "/nonexistent/t.jsonl",
            "cwd": "/tmp", "source": "startup", "claude_pid": 4242,
        ]))
        XCTAssertEqual(b.phase, .working)
        XCTAssertEqual(b.sessionID, "s-1")
        XCTAssertEqual(b.claudePID, 4242)
        XCTAssertNotNil(b.conversation)
        XCTAssertTrue(b.isBound && b.hasEverBound)

        b.handleControl(verb: "notify", json: control(["message": "Claude needs your permission"]))
        XCTAssertEqual(b.phase, .waitingForUser)
        XCTAssertEqual(b.lastNotification, "Claude needs your permission")

        b.handleControl(verb: "stop", json: control(["session_id": "s-1"]))
        XCTAssertEqual(b.phase, .idle)
        XCTAssertNil(b.lastNotification, "a finished turn clears the stale banner")

        b.handleControl(verb: "session-end", json: control(["session_id": "s-1"]))
        XCTAssertEqual(b.phase, .ended)
        XCTAssertFalse(b.isBound)
        XCTAssertNotNil(b.conversation, "ended chat stays readable")
    }

    func testRebindReplacesSession() {
        let b = ClaudeSessionBinding()
        b.handleControl(verb: "session-start", json: control(["session_id": "s-1", "transcript_path": "/a.jsonl", "claude_pid": 1]))
        let first = b.conversation
        b.handleControl(verb: "session-start", json: control(["session_id": "s-2", "transcript_path": "/b.jsonl", "claude_pid": 2]))
        XCTAssertEqual(b.sessionID, "s-2")
        XCTAssertFalse(first === b.conversation)
    }

    func testRegistryDrivesPhaseAndDeathDetection() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("registry-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let b = ClaudeSessionBinding()
        b.registryDirectory = dir
        b.handleControl(verb: "session-start", json: control(["session_id": "s-1", "transcript_path": "/t.jsonl", "claude_pid": 777]))

        try #"{"sessionId":"s-1","status":"waiting","cwd":"/tmp"}"#
            .write(to: dir.appendingPathComponent("777.json"), atomically: true, encoding: .utf8)
        b.pollRegistryNow()
        XCTAssertEqual(b.phase, .waitingForUser)

        try #"{"sessionId":"s-1","status":"busy","cwd":"/tmp"}"#
            .write(to: dir.appendingPathComponent("777.json"), atomically: true, encoding: .utf8)
        b.pollRegistryNow()
        XCTAssertEqual(b.phase, .working)

        // Registry file vanishes while bound → claude died (kill -9).
        try FileManager.default.removeItem(at: dir.appendingPathComponent("777.json"))
        b.pollRegistryNow()
        XCTAssertEqual(b.phase, .ended)
    }

    func testRegistryScanFallbackWhenClaimedPidIsWrong() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("registry-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let b = ClaudeSessionBinding()
        b.registryDirectory = dir
        // claude_pid 111 is an intermediate shell's pid — no 111.json ever.
        b.handleControl(verb: "session-start", json: control(["session_id": "s-9", "transcript_path": "/t.jsonl", "claude_pid": 111]))

        // Registry not written yet → grace, NOT death.
        b.pollRegistryNow()
        XCTAssertEqual(b.phase, .working)

        // Entry appears under claude's real pid; matched by sessionId.
        try #"{"sessionId":"s-9","status":"waiting"}"#
            .write(to: dir.appendingPathComponent("222.json"), atomically: true, encoding: .utf8)
        b.pollRegistryNow()
        XCTAssertEqual(b.phase, .waitingForUser)

        // A previously-seen entry vanishing IS death.
        try FileManager.default.removeItem(at: dir.appendingPathComponent("222.json"))
        b.pollRegistryNow()
        XCTAssertEqual(b.phase, .ended)
    }

    func testUnknownVerbAndGarbageJsonAreIgnored() {
        let b = ClaudeSessionBinding()
        b.handleControl(verb: "mystery", json: Data("nonsense".utf8))
        b.handleControl(verb: "session-start", json: Data("nonsense".utf8))
        XCTAssertEqual(b.phase, .unbound)
    }
}
