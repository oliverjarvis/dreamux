import XCTest
@testable import Dreamux

/// Round-trip coverage for the SQLite signals ledger. Every test uses a
/// temp-dir DB — never the real App Support path — so suites can run in
/// parallel and leave nothing behind.
final class SQLiteSignalStoreTests: XCTestCase {
    private var dir: URL!
    private var store: SQLiteSignalStore!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("signals-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        store = try SQLiteSignalStore(dbURL: dir.appendingPathComponent("signals.db"))
    }

    override func tearDownWithError() throws {
        store = nil
        try? FileManager.default.removeItem(at: dir)
    }

    private func signal(
        source: String = "web",
        kind: String = SignalKind.terminalLine,
        ts: Date = .now,
        severity: SignalSeverityLevel = .info,
        tags: [String: String] = ["project_dir": "/tmp/projA"],
        payload: SignalPayload = .terminalLine("hello", stream: "stdout")
    ) -> Signal {
        Signal(source: source, kind: kind, ts: ts, severity: severity, tags: tags, payload: payload)
    }

    /// The whole point of the store: what goes in comes back out intact —
    /// including the typed JSON payload and tags — newest first.
    func testAppendQueryRoundTrip() async throws {
        let older = signal(source: "web", ts: Date(timeIntervalSinceNow: -10))
        let newer = signal(source: "api", severity: .warning,
                           payload: .object(["n": .int(3), "ok": .bool(true)]))
        store.append(older)
        store.append(newer)

        let rows = try await store.query(kind: nil, source: nil, projectDir: nil, since: nil, limit: 10)
        XCTAssertEqual(rows.map(\.id), [newer.id, older.id], "newest first by ts")
        XCTAssertEqual(rows[0].severity, .warning)
        XCTAssertEqual(rows[0].payload, .object(["n": .int(3), "ok": .bool(true)]))
        XCTAssertEqual(rows[1].tags["project_dir"], "/tmp/projA")
    }

    /// kind/source/since filters AND together; each alone must narrow.
    func testQueryFilters() async throws {
        let cutoff = Date()
        store.append(signal(source: "web", kind: SignalKind.terminalLine,
                            ts: cutoff.addingTimeInterval(-100)))
        store.append(signal(source: "web", kind: SignalKind.serviceHealth,
                            ts: cutoff.addingTimeInterval(10)))
        store.append(signal(source: "api", kind: SignalKind.terminalLine,
                            ts: cutoff.addingTimeInterval(20)))

        let webOnly = try await store.query(kind: nil, source: "web", projectDir: nil, since: nil, limit: 10)
        XCTAssertEqual(webOnly.count, 2)
        let healthOnly = try await store.query(kind: SignalKind.serviceHealth, source: nil, projectDir: nil, since: nil, limit: 10)
        XCTAssertEqual(healthOnly.count, 1)
        let recentOnly = try await store.query(kind: nil, source: nil, projectDir: nil, since: cutoff, limit: 10)
        XCTAssertEqual(recentOnly.count, 2, "since is inclusive lower bound on ts")
    }

    /// projectDir filters on json_extract(tags_json, '$.project_dir') —
    /// the same expression the MCP script uses, so app-side hydration and
    /// agent-side queries agree on scoping.
    func testQueryProjectDirScoping() async throws {
        store.append(signal(tags: ["project_dir": "/tmp/projA"]))
        store.append(signal(tags: ["project_dir": "/tmp/projB"]))
        store.append(signal(tags: [:]))

        let a = try await store.query(kind: nil, source: nil, projectDir: "/tmp/projA", since: nil, limit: 10)
        XCTAssertEqual(a.count, 1)
        XCTAssertEqual(a[0].tags["project_dir"], "/tmp/projA")
    }

    /// Retention: terminal lines older than their TTL are trimmed while
    /// longer-lived kinds survive, and trim reports what it deleted.
    func testTrimHonorsPerKindTTL() async throws {
        let now = Date()
        let policy = SignalRetentionPolicy(
            perKindTTL: [SignalKind.terminalLine: 60],  // 1 minute
            defaultTTL: 3600)
        store.append(signal(kind: SignalKind.terminalLine, ts: now.addingTimeInterval(-120)))
        store.append(signal(kind: SignalKind.terminalLine, ts: now.addingTimeInterval(-30)))
        store.append(signal(kind: SignalKind.serviceHealth, ts: now.addingTimeInterval(-120)))

        let deleted = try await store.trim(policy: policy, now: now)
        XCTAssertEqual(deleted, 1, "only the stale terminal line goes")
        let rows = try await store.query(kind: nil, source: nil, projectDir: nil, since: nil, limit: 10)
        XCTAssertEqual(rows.count, 2)
    }
}
