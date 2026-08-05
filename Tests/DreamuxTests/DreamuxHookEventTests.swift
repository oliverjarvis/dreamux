import XCTest
@testable import Dreamux

/// Runs the real `Tools/dreamux-hook` as a subprocess with a fake tty
/// (its stdout, since the hook falls back to stdout when no terminal is
/// reachable) and decodes the control OSCs it writes.
final class DreamuxHookEventTests: XCTestCase {
    var sandbox: TestSandbox!

    override func setUpWithError() throws { sandbox = try TestSandbox() }
    override func tearDown() { sandbox.destroy(); sandbox = nil }

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    /// Every `OSC 777;dreamux;<verb>;<base64url>` in `output`, decoded.
    private func controls(in output: String) throws -> [(verb: String, body: [String: Any])] {
        var results: [(String, [String: Any])] = []
        for chunk in output.components(separatedBy: "\u{1B}]777;dreamux;").dropFirst() {
            let payload = chunk.components(separatedBy: "\u{07}")[0]
            let parts = payload.components(separatedBy: ";")
            guard parts.count >= 2 else { continue }
            var b64 = parts[1].replacingOccurrences(of: "-", with: "+")
                .replacingOccurrences(of: "_", with: "/")
            while b64.count % 4 != 0 { b64 += "=" }
            guard let data = Data(base64Encoded: b64),
                  let body = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            results.append((parts[0], body))
        }
        return results
    }

    private func runHook(payload: [String: Any], harness: String = "claude") throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "python3", repoRoot.appendingPathComponent("Tools/dreamux-hook").path,
            "event", "--harness", harness,
        ]
        var env = ProcessInfo.processInfo.environment
        env["DREAMUX_HARNESSES_JSON"] = repoRoot.appendingPathComponent("Tools/harnesses.json").path
        env.removeValue(forKey: "DREAMUX_EMIT_SOCKET")
        process.environment = env

        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = Pipe()
        try process.run()
        stdin.fileHandleForWriting.write(try JSONSerialization.data(withJSONObject: payload))
        stdin.fileHandleForWriting.closeFile()
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    func testPermissionPromptNormalizesToBlocked() throws {
        let output = try runHook(payload: [
            "hook_event_name": "Notification",
            "notification_type": "permission_prompt",
            "message": "Claude wants to run: npm test",
            "session_id": "s1",
        ])
        let state = try XCTUnwrap(try controls(in: output).first { $0.verb == "agent-state" })
        XCTAssertEqual(state.body["state"] as? String, "blocked")
        XCTAssertEqual(state.body["reason"] as? String, "permission")
        XCTAssertEqual(state.body["message"] as? String, "Claude wants to run: npm test")
        XCTAssertEqual(state.body["harness"] as? String, "claude")
    }

    func testIdlePromptIsAlsoBlocked() throws {
        let output = try runHook(payload: [
            "hook_event_name": "Notification",
            "notification_type": "idle_prompt",
            "message": "Waiting for your input",
            "session_id": "s1",
        ])
        let state = try XCTUnwrap(try controls(in: output).first { $0.verb == "agent-state" })
        XCTAssertEqual(state.body["state"] as? String, "blocked")
        XCTAssertEqual(state.body["reason"] as? String, "question")
    }

    func testAgentCompletedIsDone() throws {
        let output = try runHook(payload: [
            "hook_event_name": "Notification",
            "notification_type": "agent_completed",
            "message": "Subagent finished",
            "session_id": "s1",
        ])
        let state = try XCTUnwrap(try controls(in: output).first { $0.verb == "agent-state" })
        XCTAssertEqual(state.body["state"] as? String, "done")
    }

    func testPermissionRequestCarriesToolAndRequestID() throws {
        let output = try runHook(payload: [
            "hook_event_name": "PermissionRequest",
            "tool_name": "Bash",
            "tool_use_id": "toolu_01ABC",
            "session_id": "s1",
        ])
        let state = try XCTUnwrap(try controls(in: output).first { $0.verb == "agent-state" })
        XCTAssertEqual(state.body["state"] as? String, "blocked")
        XCTAssertEqual(state.body["tool"] as? String, "Bash")
        XCTAssertEqual(state.body["request_id"] as? String, "toolu_01ABC")
    }

    func testStopLiftsLastAssistantMessageFromThePayload() throws {
        let output = try runHook(payload: [
            "hook_event_name": "Stop",
            "last_assistant_message": "The deployment was successful",
            "session_id": "s1",
        ])
        let state = try XCTUnwrap(try controls(in: output).first { $0.verb == "agent-state" })
        XCTAssertEqual(state.body["state"] as? String, "done")
        XCTAssertEqual(state.body["message"] as? String, "The deployment was successful")
    }

    func testInterruptedTurnEmitsNothing() throws {
        let output = try runHook(payload: [
            "hook_event_name": "Stop",
            "last_assistant_message": "[Request interrupted by user]",
            "session_id": "s1",
        ])
        XCTAssertTrue(try controls(in: output).filter { $0.verb == "agent-state" }.isEmpty)
    }

    func testLongMessagesAreClipped() throws {
        let long = String(repeating: "a", count: 500)
        let output = try runHook(payload: [
            "hook_event_name": "Stop", "last_assistant_message": long, "session_id": "s1",
        ])
        let state = try XCTUnwrap(try controls(in: output).first { $0.verb == "agent-state" })
        let message = try XCTUnwrap(state.body["message"] as? String)
        XCTAssertLessThanOrEqual(message.count, 201)
        XCTAssertTrue(message.hasSuffix("…"))
    }

    func testUnknownEventEmitsNothing() throws {
        let output = try runHook(payload: [
            "hook_event_name": "CwdChanged", "session_id": "s1",
        ])
        XCTAssertTrue(try controls(in: output).isEmpty)
    }

    func testUnknownHarnessEmitsNothing() throws {
        let output = try runHook(
            payload: ["hook_event_name": "Stop", "last_assistant_message": "x", "session_id": "s1"],
            harness: "nosuchagent"
        )
        XCTAssertTrue(try controls(in: output).isEmpty)
    }

    func testLegacyBindingVerbsStillFire() throws {
        let done = try controls(in: try runHook(payload: [
            "hook_event_name": "Stop", "last_assistant_message": "done", "session_id": "s1",
        ]))
        XCTAssertTrue(done.contains { $0.verb == "stop" },
                      "ClaudeSessionBinding still needs the stop verb")

        let blocked = try controls(in: try runHook(payload: [
            "hook_event_name": "Notification", "notification_type": "permission_prompt",
            "message": "may I?", "session_id": "s1",
        ]))
        XCTAssertTrue(blocked.contains { $0.verb == "notify" },
                      "ClaudeSessionBinding still needs the notify verb")
    }

    func testMissingCatalogFallsBackToClaudeOnly() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "python3", repoRoot.appendingPathComponent("Tools/dreamux-hook").path,
            "event", "--harness", "claude",
        ]
        var env = ProcessInfo.processInfo.environment
        env["DREAMUX_HARNESSES_JSON"] = sandbox.root.appendingPathComponent("missing.json").path
        env.removeValue(forKey: "DREAMUX_EMIT_SOCKET")
        process.environment = env
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = Pipe()
        try process.run()
        stdin.fileHandleForWriting.write(try JSONSerialization.data(withJSONObject: [
            "hook_event_name": "Stop", "last_assistant_message": "ok", "session_id": "s1",
        ]))
        stdin.fileHandleForWriting.closeFile()
        let output = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        let state = try XCTUnwrap(try controls(in: output).first { $0.verb == "agent-state" })
        XCTAssertEqual(state.body["state"] as? String, "done")
    }
}
