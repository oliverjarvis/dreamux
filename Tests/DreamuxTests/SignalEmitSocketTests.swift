import XCTest
import Combine
@testable import Dreamux

/// End-to-end protocol coverage for the emit socket: a real BSD client
/// connects to a temp-path server, emits, and the signal lands in both
/// the injected store and the bus publisher. This is the same wire
/// contract the dreamux-signals MCP script speaks.
final class SignalEmitSocketTests: XCTestCase {
    private var dir: URL!
    private var store: SQLiteSignalStore!
    private var bus: SignalBus!
    private var server: SignalEmitSocketServer!
    private var socketPath: String!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("emit-sock-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        store = try SQLiteSignalStore(dbURL: dir.appendingPathComponent("signals.db"))
        bus = SignalBus(store: store, startSocket: false)
        // /tmp keeps sun_path short; unique suffix keeps tests parallel-safe.
        socketPath = "/tmp/dreamux-emit-test-\(UUID().uuidString.prefix(8)).sock"
        server = bus.attachSocketServer(path: socketPath)
        // Give the utility-queue bind a beat.
        usleep(100_000)
    }

    override func tearDownWithError() throws {
        server.stop()
        try? FileManager.default.removeItem(at: dir)
    }

    /// Connect a BSD client to the temp-path server. Caller closes.
    private func connectClient() -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = socketPath.utf8CString
        withUnsafeMutablePointer(to: &addr.sun_path) { sunPath in
            sunPath.withMemoryRebound(to: CChar.self, capacity: 104) { dst in
                bytes.withUnsafeBufferPointer { src in
                    dst.update(from: src.baseAddress!, count: min(bytes.count, 104))
                }
            }
        }
        let rc = withUnsafePointer(to: &addr) { ptr -> Int32 in
            let sa = UnsafeRawPointer(ptr).assumingMemoryBound(to: sockaddr.self)
            return Darwin.connect(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
        XCTAssertEqual(rc, 0, "connect failed errno=\(errno)")
        return fd
    }

    /// Send one newline-terminated JSON line.
    private func sendLine(fd: Int32, _ request: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: request)
        data.append(0x0A)
        _ = data.withUnsafeBytes { send(fd, $0.baseAddress, data.count, 0) }
    }

    /// Read one newline-terminated JSON object from a NON-BLOCKING fd,
    /// polling until `deadline`. Bytes past the newline stay in `carry`
    /// for the next call. Returns nil when no full line arrived in time.
    private func readLine(fd: Int32, carry: inout Data, deadline: Date) throws -> [String: Any]? {
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            if let nl = carry.firstIndex(of: 0x0A) {
                let line = Data(carry[carry.startIndex..<nl])
                carry = Data(carry[carry.index(after: nl)...])
                let obj = try JSONSerialization.jsonObject(with: line)
                return obj as? [String: Any]
            }
            guard Date() < deadline else { return nil }
            let n = chunk.withUnsafeMutableBufferPointer { recv(fd, $0.baseAddress, $0.count, 0) }
            if n > 0 { carry.append(chunk, count: n) } else { usleep(20_000) }
        }
    }

    /// One-shot client: connect, send one JSON line, read one line back.
    private func roundTrip(_ request: [String: Any]) throws -> [String: Any] {
        let fd = connectClient()
        defer { close(fd) }
        try sendLine(fd: fd, request)

        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        let deadline = Date().addingTimeInterval(3)
        while !buffer.contains(0x0A), Date() < deadline {
            let n = chunk.withUnsafeMutableBufferPointer { recv(fd, $0.baseAddress, $0.count, 0) }
            if n > 0 { buffer.append(chunk, count: n) } else { usleep(20_000) }
        }
        guard let nl = buffer.firstIndex(of: 0x0A) else {
            XCTFail("no response line"); return [:]
        }
        let obj = try JSONSerialization.jsonObject(with: buffer.subdata(in: 0..<nl))
        return (obj as? [String: Any]) ?? [:]
    }

    /// The emit path: ack carries the assigned id; the signal is
    /// persisted with defaulted source and republished on the bus.
    func testEmitPersistsAndPublishes() async throws {
        let published = expectation(description: "bus published")
        var seen: Signal?
        let sub = bus.publisher.sink { seen = $0; published.fulfill() }
        defer { sub.cancel() }

        let ack = try roundTrip([
            "action": "emit",
            "signal": [
                "kind": "agent.note",
                "severity": "warning",
                "tags": ["project_dir": "/tmp/projA"],
                "payload": ["text": "found it"],
            ],
        ])
        XCTAssertEqual(ack["ok"] as? Bool, true)
        XCTAssertNotNil(ack["id"] as? String)

        await fulfillment(of: [published], timeout: 3)
        XCTAssertEqual(seen?.kind, "agent.note")
        XCTAssertEqual(seen?.source, "external", "source defaults when omitted")
        XCTAssertEqual(seen?.severity, .warning)

        let stored = try await awaitRows()
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored[0].tags["project_dir"], "/tmp/projA")
    }

    /// Bad requests get a structured refusal, not a dropped connection.
    func testEmitWithoutKindIsRefused() throws {
        let ack = try roundTrip(["action": "emit", "signal": ["source": "x"]])
        XCTAssertEqual(ack["ok"] as? Bool, false)
        XCTAssertNotNil(ack["error"] as? String)
    }

    /// Unknown actions are refused explicitly (protocol future-proofing).
    func testUnknownActionRefused() throws {
        let ack = try roundTrip(["action": "frobnicate"])
        XCTAssertEqual(ack["ok"] as? Bool, false)
    }

    /// The subscribe path end-to-end: ack, filtered envelope stream,
    /// max_events farewell, EOF — the same wire contract the MCP
    /// bridge's push tools speak. Finishes by emitting after teardown
    /// to prove dead-subscriber cleanup doesn't wedge the bus.
    func testSubscribeStreamsMatchingSignalThenClosesAtMaxEvents() async throws {
        let fd = connectClient()
        defer { close(fd) }
        try sendLine(fd: fd, [
            "action": "subscribe",
            "filter": ["kind": "test.kind"],
            "max_events": 1,
            "timeout_seconds": 0,
        ])
        // Client reads are polled non-blocking so a silent server fails
        // the test at its deadline instead of hanging the run.
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        var carry = Data()
        let ack = try XCTUnwrap(
            readLine(fd: fd, carry: &carry, deadline: Date().addingTimeInterval(5)),
            "no subscribe ack")
        XCTAssertEqual(ack["ok"] as? Bool, true)
        XCTAssertEqual(ack["subscribed"] as? Bool, true)

        // The ack goes out before the server registers its bus sink, so
        // one emit fired right after reading the ack can race past the
        // not-yet-live subscription. Re-emit the non-match + match pair
        // until the envelope shows up; max_events=1 caps delivery at
        // exactly one envelope regardless of how many emits it took.
        var envelope: [String: Any]?
        let deadline = Date().addingTimeInterval(5)
        while envelope == nil, Date() < deadline {
            bus.emit(Signal(source: "test", kind: "other.kind",
                            severity: .info, tags: [:], payload: .null))
            bus.emit(Signal(source: "test", kind: "test.kind",
                            severity: .info, tags: [:], payload: .string("ping")))
            envelope = try readLine(fd: fd, carry: &carry,
                                    deadline: Date().addingTimeInterval(0.2))
        }
        let signal = try XCTUnwrap(envelope?["signal"] as? [String: Any],
                                   "no envelope line before deadline")
        XCTAssertEqual(signal["kind"] as? String, "test.kind",
                       "filter must exclude the non-matching emit")

        // max_events reached → farewell, then EOF.
        let farewell = try XCTUnwrap(
            readLine(fd: fd, carry: &carry, deadline: Date().addingTimeInterval(5)),
            "no farewell line")
        XCTAssertEqual(farewell["closed"] as? Bool, true)

        var sawEOF = false
        var byte: UInt8 = 0
        let eofDeadline = Date().addingTimeInterval(5)
        while !sawEOF, Date() < eofDeadline {
            let n = recv(fd, &byte, 1, 0)
            if n == 0 { sawEOF = true } else { usleep(20_000) }
        }
        XCTAssertTrue(sawEOF, "server must close the connection after max_events")

        // Emitting after teardown must not crash the server, and the
        // signal still reaches the store (dead-subscriber cleanup).
        bus.emit(Signal(source: "test", kind: "test.kind.after",
                        severity: .info, tags: [:], payload: .null))
        var stored = false
        let storeDeadline = Date().addingTimeInterval(3)
        while !stored, Date() < storeDeadline {
            let rows = (try? await store.query(
                kind: "test.kind.after", source: nil, projectDir: nil,
                since: nil, limit: 5)) ?? []
            stored = !rows.isEmpty
            if !stored { try? await Task.sleep(nanoseconds: 50_000_000) }
        }
        XCTAssertTrue(stored, "post-teardown emit must still reach the store")
    }

    private func awaitRows() async throws -> [Signal] {
        // append is async on the store queue; poll briefly.
        let deadline = Date().addingTimeInterval(3)
        repeat {
            let rows = (try? await store.query(kind: nil, source: nil, projectDir: nil, since: nil, limit: 10)) ?? []
            if !rows.isEmpty { return rows }
            usleep(50_000)
        } while Date() < deadline
        return []
    }
}

extension SignalEmitSocketTests {
    /// `defaultSocketPath()` is now a thin call-through to the shared
    /// helper: same source of truth that SignalBus binds and
    /// PTYShellSession exports, so bind and export can't drift.
    func testDefaultSocketPathRoutesThroughBundleIdentity() {
        XCTAssertEqual(
            SignalEmitSocketServer.defaultSocketPath(),
            BundleIdentity.emitSocketPath()
        )
    }

    /// Untagged default is byte-identical to today.
    func testDefaultSocketPathUntaggedPin() {
        XCTAssertEqual(
            BundleIdentity.emitSocketPath(env: [:], bundleID: BundleIdentity.baseBundleID),
            "/tmp/dreamux-emit-com.dreamux.Dreamux.sock"
        )
    }
}
