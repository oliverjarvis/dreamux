// Tests/DreamuxTests/DreamuxHookFlowTests.swift
import XCTest
import Combine
@testable import Dreamux

/// End-to-end: run the real Tools/dreamux-hook script against a real
/// SignalEmitSocketServer on a temp socket and assert the signal
/// arrives on the bus. Covers the Python sink, the wire protocol, and
/// the kind/payload mapping in one shot.
final class DreamuxHookFlowTests: XCTestCase {
    private var bus: SignalBus!
    private var socketPath: String!
    private var subscriptions = Set<AnyCancellable>()

    /// Repo root, derived from this file's path:
    /// <root>/Tests/DreamuxTests/DreamuxHookFlowTests.swift
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // DreamuxTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // root
    }

    override func setUp() {
        super.setUp()
        bus = SignalBus(store: nil, startSocket: false)
        // sun_path limit: keep the socket path short — /tmp, not the sandbox.
        socketPath = "/tmp/dreamux-hook-test-\(UUID().uuidString.prefix(8)).sock"
        _ = bus.attachSocketServer(path: socketPath)
    }

    override func tearDown() {
        subscriptions.removeAll()
        try? FileManager.default.removeItem(atPath: socketPath)
        bus = nil
        super.tearDown()
    }

    private func runHook(args: [String], stdin: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", repoRoot.appendingPathComponent("Tools/dreamux-hook").path] + args
        var env = ProcessInfo.processInfo.environment
        env["DREAMUX_EMIT_SOCKET"] = socketPath
        process.environment = env
        let pipe = Pipe()
        process.standardInput = pipe
        process.standardOutput = Pipe() // swallow any OSC output
        try process.run()
        pipe.fileHandleForWriting.write(Data(stdin.utf8))
        pipe.fileHandleForWriting.closeFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }

    private func expectSignal(kind: String) -> (XCTestExpectation, () -> Signal?) {
        let expectation = expectation(description: "signal \(kind)")
        let box = SignalBox()
        bus.publisher
            .filter { $0.kind == kind }
            .sink { signal in box.set(signal); expectation.fulfill() }
            .store(in: &subscriptions)
        return (expectation, { box.get() })
    }

    func testSubagentStartBecomesAgentStartedSignal() throws {
        let (exp, received) = expectSignal(kind: SignalKind.agentStarted)
        try runHook(args: ["flow"], stdin: #"""
        {"hook_event_name":"SubagentStart","session_id":"s1","agent_id":"a1",
         "agent_type":"Explore","cwd":"/tmp/worktree","transcript_path":"/tmp/t.jsonl"}
        """#)
        wait(for: [exp], timeout: 5)
        let signal = received()
        XCTAssertEqual(signal?.source, "claude.hooks")
        XCTAssertEqual(signal?.tags["cwd"], "/tmp/worktree")
        guard case let .object(fields)? = signal?.payload else { return XCTFail("object payload expected") }
        XCTAssertEqual(fields["session_id"], .string("s1"))
        XCTAssertEqual(fields["agent_id"], .string("a1"))
        XCTAssertEqual(fields["agent_type"], .string("Explore"))
    }

    func testTaskCompletedMapsKind() throws {
        let (exp, _) = expectSignal(kind: SignalKind.taskCompleted)
        try runHook(args: ["flow"], stdin: #"""
        {"hook_event_name":"TaskCompleted","session_id":"s1","task_id":"3","cwd":"/w"}
        """#)
        wait(for: [exp], timeout: 5)
    }

    func testNotifyEmitsSessionNotification() throws {
        let (exp, received) = expectSignal(kind: SignalKind.sessionNotification)
        try runHook(args: ["notify"], stdin: #"""
        {"hook_event_name":"Notification","session_id":"s1","cwd":"/w",
         "message":"Claude needs permission to run npm"}
        """#)
        wait(for: [exp], timeout: 5)
        guard case let .object(fields)? = received()?.payload else { return XCTFail("object payload expected") }
        XCTAssertEqual(fields["message"], .string("Claude needs permission to run npm"))
    }

    func testUnknownEventAndMissingSocketAreSilentlyFine() throws {
        // Unknown hook_event_name → no signal, exit 0.
        try runHook(args: ["flow"], stdin: #"{"hook_event_name":"SomethingNew","session_id":"s1"}"#)
        // Missing socket → exit 0 (the sink must never break a session).
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", repoRoot.appendingPathComponent("Tools/dreamux-hook").path, "flow"]
        var env = ProcessInfo.processInfo.environment
        env["DREAMUX_EMIT_SOCKET"] = "/tmp/definitely-not-there-\(UUID().uuidString).sock"
        process.environment = env
        let pipe = Pipe()
        process.standardInput = pipe
        try process.run()
        pipe.fileHandleForWriting.write(Data(#"{"hook_event_name":"SubagentStop","session_id":"s","agent_id":"a"}"#.utf8))
        pipe.fileHandleForWriting.closeFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }

    func testNonDictStdinJSONIsSilentlyFine() throws {
        // Top-level JSON array (or any non-dict) → every handler's
        // payload.get(...) chain would AttributeError without the
        // isinstance(dict) guard in read_stdin_json(). exit 0 either way.
        try runHook(args: ["flow"], stdin: "[1,2,3]")
        try runHook(args: ["notify"], stdin: "[1,2,3]")
    }
}

/// Lock-boxed Signal for cross-queue capture in expectations.
final class SignalBox: @unchecked Sendable {
    private let lock = NSLock()
    private var signal: Signal?
    func set(_ s: Signal) { lock.lock(); signal = s; lock.unlock() }
    func get() -> Signal? { lock.lock(); defer { lock.unlock() }; return signal }
}
