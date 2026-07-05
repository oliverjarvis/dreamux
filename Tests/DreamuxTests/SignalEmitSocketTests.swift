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

    /// One-shot client: connect, send one JSON line, read one line back.
    private func roundTrip(_ request: [String: Any]) throws -> [String: Any] {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { close(fd) }
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

        var data = try JSONSerialization.data(withJSONObject: request)
        data.append(0x0A)
        _ = data.withUnsafeBytes { send(fd, $0.baseAddress, data.count, 0) }

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
