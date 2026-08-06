import XCTest
@testable import Dreamux

/// End-to-end for the statusline tap: run the real Tools/dreamux-hook
/// against a real SignalEmitSocketServer on a temp socket, with a fake
/// ~/.claude/settings.json and a private TMPDIR for the debounce cache.
/// Covers the post, the delegation, the silences, and the debounce.
final class DreamuxHookStatuslineTests: XCTestCase {
    private var bus: SignalBus!
    private var server: SignalEmitSocketServer!
    private var socketPath: String!
    private var sandbox: TestSandbox!
    private let captured = UsageCaptureBox()

    /// Repo root, from <root>/Tests/DreamuxTests/<this file>.
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    override func setUpWithError() throws {
        sandbox = try TestSandbox()
        bus = SignalBus(store: nil, startSocket: false)
        // sun_path limit: keep the socket path short — /tmp, not the sandbox.
        socketPath = "/tmp/dreamux-statusline-test-\(UUID().uuidString.prefix(8)).sock"
        server = bus.attachSocketServer(path: socketPath)
        server.usageSink = { [captured] in captured.append($0) }
        usleep(100_000) // let the utility-queue bind land
    }

    override func tearDown() {
        server.stop()
        try? FileManager.default.removeItem(atPath: socketPath)
        sandbox.destroy()
        sandbox = nil
        bus = nil
    }

    /// Write a settings file with the given statusLine command, and
    /// return its path for DREAMUX_CLAUDE_SETTINGS.
    private func settingsFile(statusLineCommand: String?) throws -> String {
        let url = sandbox.root.appendingPathComponent("settings-\(UUID().uuidString).json")
        let object: [String: Any] = statusLineCommand.map {
            ["statusLine": ["type": "command", "command": $0]]
        } ?? ["theme": "dark"]
        try JSONSerialization.data(withJSONObject: object).write(to: url)
        return url.path
    }

    /// Run `dreamux-hook statusline` with the given stdin, returning its
    /// stdout. Asserts exit 0 — the contract is that this can never fail.
    @discardableResult
    private func runStatusline(stdin: String, settingsPath: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "python3",
            repoRoot.appendingPathComponent("Tools/dreamux-hook").path,
            "statusline",
        ]
        var env = ProcessInfo.processInfo.environment
        env["DREAMUX_EMIT_SOCKET"] = socketPath
        env["DREAMUX_CLAUDE_SETTINGS"] = settingsPath
        // Private TMPDIR: the debounce cache must not leak between tests.
        env["TMPDIR"] = sandbox.root.path
        process.environment = env
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        try process.run()
        input.fileHandleForWriting.write(Data(stdin.utf8))
        input.fileHandleForWriting.closeFile()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "a hook must never fail the session")
        return String(decoding: data, as: UTF8.self)
    }

    private func payload(fivePercent: Double, sessionID: String = "s1") -> String {
        """
        {"session_id":"\(sessionID)","cwd":"/tmp/w","model":{"id":"claude-opus-5"},
         "rate_limits":{"five_hour":{"used_percentage":\(fivePercent),"resets_at":1785900000},
                        "seven_day":{"used_percentage":63.0,"resets_at":1786200000}}}
        """
    }

    private func waitForPosts(_ count: Int) {
        let deadline = Date().addingTimeInterval(3)
        while captured.count() < count, Date() < deadline { usleep(20_000) }
    }

    func testPostsRateLimitsToTheApp() throws {
        try runStatusline(stdin: payload(fivePercent: 41.2),
                          settingsPath: try settingsFile(statusLineCommand: nil))
        waitForPosts(1)
        let snapshot = try XCTUnwrap(captured.all().first)
        XCTAssertEqual(snapshot.fiveHour?.usedPercentage, 41.2)
        XCTAssertEqual(snapshot.fiveHour?.resetsAt, Date(timeIntervalSince1970: 1_785_900_000))
        XCTAssertEqual(snapshot.sevenDay?.usedPercentage, 63.0)
    }

    func testEchoesTheUsersStatuslineVerbatim() throws {
        let out = try runStatusline(
            stdin: payload(fivePercent: 41.2),
            settingsPath: try settingsFile(statusLineCommand: "printf 'my own bar'"))
        XCTAssertEqual(out, "my own bar",
                       "a Dreamux tab must render exactly the statusline it would render outside Dreamux")
    }

    func testPrintsNothingWhenTheUserHasNoStatusline() throws {
        let out = try runStatusline(stdin: payload(fivePercent: 41.2),
                                    settingsPath: try settingsFile(statusLineCommand: nil))
        XCTAssertEqual(out, "")
    }

    func testABrokenUserStatuslineCostsTheStatuslineNotTheReading() throws {
        let out = try runStatusline(
            stdin: payload(fivePercent: 41.2),
            settingsPath: try settingsFile(statusLineCommand: "printf 'partial'; exit 3"))
        XCTAssertEqual(out, "", "non-zero exit means its output is dropped")
        waitForPosts(1)
        XCTAssertEqual(captured.count(), 1, "the quota post already happened")
    }

    func testAMalformedPayloadIsSilentAndPostsNothing() throws {
        let settings = try settingsFile(statusLineCommand: nil)
        XCTAssertEqual(try runStatusline(stdin: "{not json", settingsPath: settings), "")
        XCTAssertEqual(try runStatusline(stdin: "[1,2,3]", settingsPath: settings), "")
        XCTAssertEqual(try runStatusline(stdin: "", settingsPath: settings), "")
        usleep(300_000)
        XCTAssertEqual(captured.count(), 0)
    }

    func testAPayloadWithoutRateLimitsPostsNothing() throws {
        // API-key users, non-subscribers, and any session before its
        // first API response.
        try runStatusline(stdin: #"{"session_id":"s1","cwd":"/tmp/w"}"#,
                          settingsPath: try settingsFile(statusLineCommand: nil))
        usleep(300_000)
        XCTAssertEqual(captured.count(), 0)
    }

    func testAnIdenticalSecondPayloadPostsNothing() throws {
        // A statusline re-renders several times a second while a
        // response streams; quota figures move slowly.
        let settings = try settingsFile(statusLineCommand: nil)
        try runStatusline(stdin: payload(fivePercent: 41.2), settingsPath: settings)
        waitForPosts(1)
        try runStatusline(stdin: payload(fivePercent: 41.2), settingsPath: settings)
        usleep(300_000)
        XCTAssertEqual(captured.count(), 1)

        // A changed figure posts again.
        try runStatusline(stdin: payload(fivePercent: 42.0), settingsPath: settings)
        waitForPosts(2)
        XCTAssertEqual(captured.count(), 2)
    }

    func testDebounceIsPerSession() throws {
        let settings = try settingsFile(statusLineCommand: nil)
        try runStatusline(stdin: payload(fivePercent: 41.2, sessionID: "s1"), settingsPath: settings)
        waitForPosts(1)
        try runStatusline(stdin: payload(fivePercent: 41.2, sessionID: "s2"), settingsPath: settings)
        waitForPosts(2)
        XCTAssertEqual(captured.count(), 2)
    }
}

/// Lock-boxed accumulator: the sink runs on the socket server's work
/// queue, the assertions on the test's.
final class UsageCaptureBox: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [ClaudeUsageSnapshot] = []
    func append(_ snapshot: ClaudeUsageSnapshot) { lock.lock(); values.append(snapshot); lock.unlock() }
    func all() -> [ClaudeUsageSnapshot] { lock.lock(); defer { lock.unlock() }; return values }
    func count() -> Int { lock.lock(); defer { lock.unlock() }; return values.count }
}
