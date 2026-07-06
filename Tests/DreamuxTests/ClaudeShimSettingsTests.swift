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
        for event in ["Stop", "Notification", "SubagentStart", "SubagentStop", "TaskCreated", "TaskCompleted"] {
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
    }
}
