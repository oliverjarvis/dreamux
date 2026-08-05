import XCTest
@testable import Dreamux

/// Runs the real Tools/claude shim with PATH rigged so the "real"
/// claude is a fake that captures its argv, then asserts the injected
/// --settings JSON is valid and wires every expected hook.
final class ClaudeShimSettingsTests: XCTestCase {
    var sandbox: TestSandbox!

    override func setUpWithError() throws { sandbox = try TestSandbox() }
    override func tearDown() { sandbox.destroy(); sandbox = nil }

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func testShimInjectsLifecycleHooks() throws {
        let fakeBin = sandbox.root.appendingPathComponent("fakebin", isDirectory: true)
        try FileManager.default.createDirectory(at: fakeBin, withIntermediateDirectories: true)
        let capture = sandbox.root.appendingPathComponent("argv.txt")
        let fakeClaude = fakeBin.appendingPathComponent("claude")
        try """
        #!/bin/sh
        printf '%s\\n' "$@" > "\(capture.path)"
        """.write(to: fakeClaude, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeClaude.path)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [repoRoot.appendingPathComponent("Tools/claude").path, "--version"]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "\(repoRoot.appendingPathComponent("Tools").path):\(fakeBin.path):/usr/bin:/bin"
        process.environment = env
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)

        let argv = try String(contentsOf: capture, encoding: .utf8)
            .split(separator: "\n").map(String.init)
        XCTAssertEqual(argv.first, "--settings")
        XCTAssertEqual(argv.last, "--version")

        let settings = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(argv[1].utf8)) as? [String: Any]
        )
        let hooks = try XCTUnwrap(settings["hooks"] as? [String: Any])
        for event in ["Stop", "Notification", "SubagentStart", "SubagentStop", "TaskCreated", "TaskCompleted", "SessionEnd"] {
            XCTAssertNotNil(hooks[event], "missing hook registration for \(event)")
        }
        // Lifecycle hooks are async `dreamux-hook flow` commands.
        let subagentStart = try XCTUnwrap(hooks["SubagentStart"] as? [[String: Any]])
        let entry = try XCTUnwrap((subagentStart.first?["hooks"] as? [[String: Any]])?.first)
        XCTAssertEqual(entry["type"] as? String, "command")
        XCTAssertEqual(entry["async"] as? Bool, true)
        XCTAssertTrue((entry["command"] as? String ?? "").hasSuffix("\" flow"))
        // Task hooks take no matcher (hooks reference).
        let taskCreated = try XCTUnwrap(hooks["TaskCreated"] as? [[String: Any]])
        XCTAssertNil(taskCreated.first?["matcher"])
        // SessionEnd is the true once-per-session terminal event (unlike
        // Stop, which fires every turn) — same async flow-relay shape,
        // no matcher.
        let sessionEnd = try XCTUnwrap(hooks["SessionEnd"] as? [[String: Any]])
        XCTAssertNil(sessionEnd.first?["matcher"])
        let sessionEndEntry = try XCTUnwrap((sessionEnd.first?["hooks"] as? [[String: Any]])?.first)
        XCTAssertEqual(sessionEndEntry["type"] as? String, "command")
        XCTAssertEqual(sessionEndEntry["async"] as? Bool, true)
        XCTAssertTrue((sessionEndEntry["command"] as? String ?? "").hasSuffix("\" flow"))
    }

    /// Extract the injected settings JSON by running the real shim with
    /// PATH rigged so "real claude" is a fake that captures its argv.
    private func injectedHooks() throws -> [String: Any] {
        let fakeBin = sandbox.root.appendingPathComponent("fakebin2", isDirectory: true)
        try FileManager.default.createDirectory(at: fakeBin, withIntermediateDirectories: true)
        let capture = sandbox.root.appendingPathComponent("argv2.txt")
        let fakeClaude = fakeBin.appendingPathComponent("claude")
        try """
        #!/bin/sh
        printf '%s\\n' "$@" > "\(capture.path)"
        """.write(to: fakeClaude, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeClaude.path)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [repoRoot.appendingPathComponent("Tools/claude").path, "--version"]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "\(repoRoot.appendingPathComponent("Tools").path):\(fakeBin.path):/usr/bin:/bin"
        process.environment = env
        try process.run()
        process.waitUntilExit()

        let argv = try String(contentsOf: capture, encoding: .utf8)
            .split(separator: "\n").map(String.init)
        let settings = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(argv[1].utf8)) as? [String: Any]
        )
        return try XCTUnwrap(settings["hooks"] as? [String: Any])
    }

    private func command(_ hooks: [String: Any], _ event: String) throws -> String {
        let entries = try XCTUnwrap(hooks[event] as? [[String: Any]])
        let entry = try XCTUnwrap((entries.first?["hooks"] as? [[String: Any]])?.first)
        return try XCTUnwrap(entry["command"] as? String)
    }

    func testAttentionHooksRouteThroughTheNormalizer() throws {
        let hooks = try injectedHooks()
        for event in ["Stop", "Notification", "PermissionRequest", "UserPromptSubmit"] {
            XCTAssertNotNil(hooks[event], "missing hook registration for \(event)")
            XCTAssertTrue(
                try command(hooks, event).hasSuffix("\" event --harness claude"),
                "\(event) must route through the normalizer"
            )
        }
    }

    func testPermissionRequestAndUserPromptSubmitAreAsync() throws {
        let hooks = try injectedHooks()
        for event in ["PermissionRequest", "UserPromptSubmit"] {
            let entries = try XCTUnwrap(hooks[event] as? [[String: Any]])
            let entry = try XCTUnwrap((entries.first?["hooks"] as? [[String: Any]])?.first)
            XCTAssertEqual(entry["async"] as? Bool, true,
                           "\(event) must never block the agent")
        }
    }

    func testFlowHooksAreUnchanged() throws {
        let hooks = try injectedHooks()
        for event in ["SubagentStart", "SubagentStop", "TaskCreated", "TaskCompleted", "SessionEnd"] {
            XCTAssertTrue(try command(hooks, event).hasSuffix("\" flow"),
                          "\(event) still belongs to the flow relay")
        }
        XCTAssertTrue(try command(hooks, "SessionStart").hasSuffix("\" session-start"))
    }
}
