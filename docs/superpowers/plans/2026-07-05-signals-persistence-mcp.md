# Signals Persistence + dreamux-signals MCP Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Persist Dreamux's service logs and health transitions to a SQLite `signals.db`, expose them to external Claude Code agents through a vendored `dreamux-signals` MCP server (query + live-subscribe + emit via a Unix socket), and auto-install that server into agent working directories.

**Architecture:** Port cmux-main's proven Signals substrate (envelope model, SQLite store, bus, emit socket, MCP installer, bun MCP script) into a new `Sources/Dreamux/Signals/` module, renamed cmux→dreamux. Dreamux's existing in-memory `SignalStore` stays the UI's hot path; a forward hook fans app log lines onto the app-global `SignalBus` (persist + publish), a bus subscription surfaces external emits back into the UI, and hydration seeds the ring buffer from disk at project open. `RunnerManager` gains a status-transition hook that emits `service.health`.

**Tech Stack:** Swift/SwiftPM (SQLite3 C API — no new package deps), BSD sockets, Combine, bun + @modelcontextprotocol/sdk (vendored TypeScript, runs external to the app), XCTest.

## Global Constraints

- Platform floor `macOS(.v14)`; no new SwiftPM dependencies (SQLite3 and Combine are system).
- Bundle id is `com.dreamux.Dreamux` → DB at `~/Library/Application Support/com.dreamux.Dreamux/signals.db`, socket at `/tmp/dreamux-emit-com.dreamux.Dreamux.sock` (sun_path is capped at 104 bytes — sockets live under /tmp, never App Support).
- The MCP server name is `dreamux-signals`; MCP tool names stay `signals_recent/query/kinds_summary/sources_summary/subscribe/unsubscribe/emit`; env overrides are `DREAMUX_SIGNALS_DB`, `DREAMUX_PROJECT_DIR`, `DREAMUX_SIGNALS_ALL_PROJECTS`, `DREAMUX_SIGNALS_EMIT_SOCKET`.
- Signals schema is cmux-compatible verbatim: `signals(id TEXT PRIMARY KEY, source TEXT, kind TEXT, ts INTEGER ms, severity TEXT, tags_json TEXT, payload_json TEXT)`, WAL, indexes on (kind,ts DESC), (source,ts DESC), (ts DESC).
- `project_dir` tag = the Dreamux **project root path** (not the worktree); the installer pins `DREAMUX_PROJECT_DIR` to the project root in every `.mcp.json` entry so agents in feature dirs see the whole project's signals.
- App-origin envelopes carry tag `origin: "app"`; the bus→UI subscriber skips those (loop prevention) and UI-bound external appends never re-forward.
- Ports from cmux-main (`/Users/olliejarvis/Development/cmux-main/Sources/Signals/` and `/mcp/cmux-signals-mcp.ts`) preserve the original structure and comments except for the exact renames each task lists — implementers read the cmux source file directly and apply only the listed changes plus what the task's code blocks show.
- Retention is TTL-per-kind (terminal.line 3 days, service.health 30 days, default 30 days; hourly trim) — a deliberate improvement over the spec's "~200k row cap" sketch: it ports tested cmux code and bounds the DB by age rather than by an arbitrary count.
- Tests: XCTest in `Tests/DreamuxTests/`, `@MainActor` where the type is, doc comments explaining *why* (house style). Never write to the real App Support DB or the real socket path in tests — every test uses temp paths.
- Git: stage only named files; commit messages are plain sentences ending with `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`. Full `swift test` green before each task's final commit.
- Delivery branch `signals-persistence-mcp`; merge only after user approval (Task 5).

**Existing code this plan touches:**
- `Sources/Dreamux/Models/Signal.swift` — in-memory `SignalStore` (`@MainActor @Observable`, `append(source:line:at:)`, `appendChunk(source:_:buffer:)`, `entries`, `knownSources`, cap 10_000)
- `Sources/Dreamux/Models/RunnerManager.swift` — writes `statusByInstance[key]` in `start()` (`.failed` at :323, run start), the stdout/stderr readability handlers, the termination handler, and `stop()`; calls `signals.appendChunk`/`signals.append`
- `Sources/Dreamux/Models/ProjectSession.swift` — creates `SignalStore` (line ~71) and `RunnerManager(project:signals:)` (line ~72) per project
- `Sources/Dreamux/DreamuxApp.swift` — `init()` at line 8 (early-bootstrap point)
- `Sources/Dreamux/Views/WorkspaceSidebar.swift` — `openPlanningSession` (~line 794, tab at project root)
- `Sources/Dreamux/Shell/PlanRunCoordinator.swift` — `runPlan` opens the agent tab at `featureDir` (~line 76)
- `Sources/Dreamux/Shell/PlanPrompts.swift` — `runPlan(planRelativePath:docsLinkName:)` at line 26
- `Sources/Dreamux/Views/SignalsView.swift` — filter bar header (manual MCP install affordance goes here)
- `.claude/settings.local.json` — stale `"cmux-signals"` under `disabledMcpjsonServers`

---

### Task 1: Signal envelope + SQLite store (port)

**Files:**
- Create: `Sources/Dreamux/Signals/SignalEnvelope.swift` (port of cmux `Sources/Signals/Signal.swift`)
- Create: `Sources/Dreamux/Signals/SQLiteSignalStore.swift` (port of cmux `Sources/Signals/SignalStore.swift`)
- Test: `Tests/DreamuxTests/SQLiteSignalStoreTests.swift`

**Interfaces:**
- Consumes: nothing from this repo (pure port).
- Produces (later tasks rely on these exact names):
  - `struct Signal` (`id: String = UUID().uuidString, source: String, kind: String, ts: Date = Date(), severity: SignalSeverityLevel = .info, tags: [String: String] = [:], payload: SignalPayload = .null`) — Identifiable/Hashable/Codable/Sendable
  - `enum SignalSeverityLevel: String` (`info/success/warning/critical`)
  - `enum SignalKind` statics: `terminalLine = "terminal.line"`, `serviceHealth = "service.health"`
  - `indirect enum SignalPayload` with `.terminalLine(_:stream:)`, `static func from(json:) -> SignalPayload`, Codable
  - `struct SignalRetentionPolicy` with `static let default`
  - `final class SQLiteSignalStore` — `init(dbURL: URL) throws`, `static func defaultURL() throws -> URL`, `func append(_ Signal)`, `func query(kind: String?, source: String?, projectDir: String?, since: Date?, limit: Int) async throws -> [Signal]`, `func trim(policy:now:) async throws -> Int`, `func startPeriodicTrim(policy:interval:)`, `func recent(limit: Int = 200, projectDir: String? = nil) async throws -> [Signal]`

- [ ] **Step 1: Create the working branch**

```bash
cd /Users/olliejarvis/Development/clayspace
git worktree add .claude/worktrees/signals-persistence-mcp -b signals-persistence-mcp
cd .claude/worktrees/signals-persistence-mcp
```

- [ ] **Step 2: Port the envelope**

Copy `/Users/olliejarvis/Development/cmux-main/Sources/Signals/Signal.swift` → `Sources/Dreamux/Signals/SignalEnvelope.swift`, applying ONLY these changes:
1. In the header doc comment, replace "cmux" with "Dreamux" and drop the mention of "the HTTP API".
2. Delete the `previewString(maxLength:)` extension method entirely (UI-only in cmux; YAGNI here).
3. In `SignalKind`, keep only `terminalLine` and `serviceHealth` (delete `lintDiagnostic`, `testResult`, `boardItem` — no Dreamux emitter produces them; the MCP script doesn't enumerate kinds).
4. In `SignalSeverityLevel`'s doc comment, delete the sentence about "SignalSeverity in SignalsView.swift" (refers to a cmux file).

Everything else — `Signal`, `SignalPayload` with its Codable conformance and `from(json:)` — ports verbatim.

- [ ] **Step 3: Write the failing store tests**

Create `Tests/DreamuxTests/SQLiteSignalStoreTests.swift`:

```swift
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
```

- [ ] **Step 4: Run tests to verify they fail**

Run: `swift test --filter SQLiteSignalStoreTests 2>&1 | tail -10`
Expected: BUILD FAILURE — `cannot find 'SQLiteSignalStore' in scope`.

- [ ] **Step 5: Port the store**

Copy `/Users/olliejarvis/Development/cmux-main/Sources/Signals/SignalStore.swift` → `Sources/Dreamux/Signals/SQLiteSignalStore.swift`, applying ONLY these changes:

1. **Delete the `protocol SignalStore` and its extension** (lines 31–66 of the source) and delete `NoopSignalStore` if present (it lives in SignalBus.swift in cmux — just don't port it). Dreamux already has a `class SignalStore` (the in-memory UI store); the concrete `SQLiteSignalStore` stands alone. Move the `recent(limit:)` convenience onto `SQLiteSignalStore` itself as:

```swift
    /// Convenience: most recent N signals, optionally project-scoped.
    func recent(limit: Int = 200, projectDir: String? = nil) async throws -> [Signal] {
        try await query(kind: nil, source: nil, projectDir: projectDir, since: nil, limit: limit)
    }
```

2. **Class declaration** becomes `final class SQLiteSignalStore: @unchecked Sendable` (no protocol conformance). Keep `SignalRetentionPolicy` and `SignalStoreError` as-is, but trim `SignalRetentionPolicy.default`'s `perKindTTL` to the two kinds that exist here (`terminalLine`: 3 days, `serviceHealth`: 30 days) and keep `defaultTTL` 30 days.
3. **Queue label:** `"dreamux.signals.store"`.
4. **`defaultURL()`**: bundle-id fallback string becomes `"com.dreamux.Dreamux"` (instead of `"cmux"`).
5. **Add `projectDir` to querying.** `query` and `queryLocked` gain a `projectDir: String?` parameter (between `source` and `since`). In `queryLocked`'s SQL assembly add, after the `source` clause:

```swift
        if projectDir != nil { sql += " AND json_extract(tags_json, '$.project_dir') = ?" }
```

and in the bind sequence, after the `source` bind:

```swift
        if let projectDir { bindText(stmt, idx, projectDir); idx += 1 }
```

6. Everything else — WAL pragmas, schema DDL, indexes, prepared insert, `SQLITE_TRANSIENT_PTR`, trim logic, `startPeriodicTrim` — ports verbatim (comments included; "cmux" in comments → "Dreamux" where it appears).

- [ ] **Step 6: Run tests to verify they pass**

Run: `swift test --filter SQLiteSignalStoreTests 2>&1 | tail -5`
Expected: `Test Suite 'SQLiteSignalStoreTests' passed` — 4 tests.

- [ ] **Step 7: Full suite, then commit**

Run: `swift test 2>&1 | grep -E "Test Suite 'All tests'" ` → passed.

```bash
git add Sources/Dreamux/Signals/SignalEnvelope.swift Sources/Dreamux/Signals/SQLiteSignalStore.swift Tests/DreamuxTests/SQLiteSignalStoreTests.swift
git commit -m "Signal envelope and SQLite ledger ported from cmux

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: SignalBus + emit socket (port)

**Files:**
- Create: `Sources/Dreamux/Signals/SignalBus.swift` (simplified port of cmux `Sources/Signals/SignalBus.swift`)
- Create: `Sources/Dreamux/Signals/SignalEmitSocketServer.swift` (port of cmux `Sources/Signals/SignalEmitSocketServer.swift`)
- Modify: `Sources/Dreamux/DreamuxApp.swift:8-12` (`init()` — bootstrap the bus)
- Test: `Tests/DreamuxTests/SignalEmitSocketTests.swift`

**Interfaces:**
- Consumes: `Signal`, `SignalPayload`, `SignalSeverityLevel`, `SQLiteSignalStore` (Task 1).
- Produces:
  - `final class SignalBus: @unchecked Sendable` — `static let shared`, `let store: SQLiteSignalStore?`, `let publisher: AnyPublisher<Signal, Never>`, `func emit(_ Signal)`, and a test seam `init(store: SQLiteSignalStore?, startSocket: Bool)`
  - `final class SignalEmitSocketServer: @unchecked Sendable` — `init(bus: SignalBus)`, `func start(path: String)`, `func stop()`, `static func defaultSocketPath() -> String`

- [ ] **Step 1: Write SignalBus**

Create `Sources/Dreamux/Signals/SignalBus.swift`:

```swift
import Foundation
import Combine

/// App-wide hub every signal flows through. Producers call
/// `SignalBus.shared.emit(_:)`; the bus persists to SQLite and
/// republishes to in-process subscribers (project sessions surfacing
/// external emits, the emit-socket's subscribe streams).
///
/// Single global because there is one ledger per app instance; the
/// per-project scoping lives in the `project_dir` tag, not in separate
/// stores.
final class SignalBus: @unchecked Sendable {
    static let shared = SignalBus()

    /// nil when SQLite failed to open — the app keeps running, the live
    /// stream just won't retain history across launches.
    let store: SQLiteSignalStore?

    /// Combine fan-out. Sent on whatever thread `emit` was called from;
    /// subscribers hop schedulers as appropriate.
    let publisher: AnyPublisher<Signal, Never>
    private let subject = PassthroughSubject<Signal, Never>()
    private var socketServer: SignalEmitSocketServer?

    private convenience init() {
        let resolved: SQLiteSignalStore?
        do {
            let sqlite = try SQLiteSignalStore(dbURL: SQLiteSignalStore.defaultURL())
            sqlite.startPeriodicTrim()
            resolved = sqlite
        } catch {
            NSLog("SignalBus: persistence unavailable — %@", String(describing: error))
            resolved = nil
        }
        self.init(store: resolved, startSocket: true)
    }

    /// Test seam: inject a temp-path store (or nil) and skip the real
    /// socket. Production goes through `shared` only.
    init(store: SQLiteSignalStore?, startSocket: Bool) {
        self.store = store
        self.publisher = subject.eraseToAnyPublisher()
        if startSocket {
            let server = SignalEmitSocketServer(bus: self)
            self.socketServer = server
            DispatchQueue.global(qos: .utility).async {
                server.start(path: SignalEmitSocketServer.defaultSocketPath())
            }
        }
    }

    /// Test-only: attach a server on a custom path (temp dir sockets).
    func attachSocketServer(path: String) -> SignalEmitSocketServer {
        let server = SignalEmitSocketServer(bus: self)
        socketServer = server
        server.start(path: path)
        return server
    }

    /// Fan out a signal to disk and to subscribers. Safe from any thread.
    func emit(_ signal: Signal) {
        store?.append(signal)
        subject.send(signal)
    }
}
```

- [ ] **Step 2: Port the socket server**

Copy `/Users/olliejarvis/Development/cmux-main/Sources/Signals/SignalEmitSocketServer.swift` → `Sources/Dreamux/Signals/SignalEmitSocketServer.swift`, applying ONLY these changes:

1. Delete `static let shared` and make `init(bus: SignalBus)` non-private (the bus owns its server; tests build their own).
2. `defaultSocketPath()` loses `throws` and becomes:

```swift
    /// `/tmp/dreamux-emit-<bundle-id>.sock` — /tmp because sun_path is
    /// hard-capped at 104 bytes and App Support paths blow the limit.
    /// The MCP bridge derives the same path from the DB's parent dir.
    static func defaultSocketPath() -> String {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.dreamux.Dreamux"
        return "/tmp/dreamux-emit-\(bundleID).sock"
    }
```

3. `start()` becomes `start(path: String)`: delete the internal `defaultSocketPath()` call + do/catch; use the parameter (`unlink(path)` etc. unchanged).
4. Queue labels: `"dreamux.signals.emit-socket.accept"` / `"dreamux.signals.emit-socket.work"`; NSLog prefixes "SignalEmitSocketServer" stay.
5. Everything else ports verbatim: the accept loop, `handle(connectionFD:)`, `handleSubscribe` (EOF watcher, filter on kind/source/project_dir, max_events/timeout semantics, `{"closed": true}` farewell), `writeJSONLine`, `payloadAsAny`, `parseAndEmit` (including `source` default `"external"` and severity fallback `.info`).

- [ ] **Step 3: Write the failing socket tests**

Create `Tests/DreamuxTests/SignalEmitSocketTests.swift`:

```swift
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
    func testEmitPersistsAndPublishes() throws {
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

        wait(for: [published], timeout: 3)
        XCTAssertEqual(seen?.kind, "agent.note")
        XCTAssertEqual(seen?.source, "external", "source defaults when omitted")
        XCTAssertEqual(seen?.severity, .warning)

        let stored = try awaitRows()
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

    private func awaitRows() throws -> [Signal] {
        // append is async on the store queue; poll briefly.
        var rows: [Signal] = []
        let deadline = Date().addingTimeInterval(3)
        repeat {
            let exp = expectation(description: "query")
            Task {
                rows = (try? await store.query(kind: nil, source: nil, projectDir: nil, since: nil, limit: 10)) ?? []
                exp.fulfill()
            }
            wait(for: [exp], timeout: 3)
            if !rows.isEmpty { break }
            usleep(50_000)
        } while Date() < deadline
        return rows
    }
}
```

- [ ] **Step 4: Run tests to verify they fail**

Run: `swift test --filter SignalEmitSocketTests 2>&1 | tail -10`
Expected: BUILD FAILURE — `cannot find 'SignalBus' in scope`.

- [ ] **Step 5: Bootstrap the bus at app start**

In `Sources/Dreamux/DreamuxApp.swift`, inside `init()` (line 8), add as the first line:

```swift
        // Touch the signals bus so SQLite + the emit socket come up
        // before any project session or external MCP client needs them.
        _ = SignalBus.shared
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `swift test --filter SignalEmitSocketTests 2>&1 | tail -5`
Expected: `Test Suite 'SignalEmitSocketTests' passed` — 3 tests.

- [ ] **Step 7: Full suite, then commit**

Run: `swift test 2>&1 | grep -E "Test Suite 'All tests'"` → passed.

```bash
git add Sources/Dreamux/Signals/SignalBus.swift Sources/Dreamux/Signals/SignalEmitSocketServer.swift Sources/Dreamux/DreamuxApp.swift Tests/DreamuxTests/SignalEmitSocketTests.swift
git commit -m "Signal bus and emit socket give external agents a write path

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: Write-through, hydration, and health transitions

**Files:**
- Modify: `Sources/Dreamux/Models/Signal.swift` (in-memory `SignalStore`)
- Modify: `Sources/Dreamux/Models/RunnerManager.swift` (status choke point + stream tags)
- Modify: `Sources/Dreamux/Models/ProjectSession.swift` (wiring + hydration + subscription)
- Test: `Tests/DreamuxTests/SignalForwardingTests.swift`

**Interfaces:**
- Consumes: `Signal`, `SignalKind`, `SignalPayload`, `SignalBus` (Tasks 1–2); existing `SignalStore`, `RunnerManager`, `ProjectSession`.
- Produces:
  - `SignalStore.forward: ((SignalEntry, _ stream: String?) -> Void)?` — called once per appended line; nil in tests/by default
  - `SignalStore.appendExternal(source:line:at:)` — appends WITHOUT forwarding (hydration + bus-subscriber path)
  - `SignalStore.append(source:line:at:stream:)` — `stream` defaults nil, threads through to `forward`
  - `SignalStore.appendChunk(source:_:buffer:stream:)` — same threading
  - `RunnerManager.statusChanged: ((_ runnerName: String, _ branch: String, _ previous: RunnerStatus?, _ new: RunnerStatus) -> Void)?` — fires on every distinct write to `statusByInstance` (same value = no fire)
  - `ProjectSession` wires all of it against `SignalBus.shared`

- [ ] **Step 1: Write the failing tests**

Create `Tests/DreamuxTests/SignalForwardingTests.swift`:

```swift
import XCTest
@testable import Dreamux

/// The loop-prevention contract between the UI ring buffer and the
/// persistent bus: app-origin lines forward exactly once; hydrated and
/// external lines never forward (or external emits would bounce
/// UI→bus→UI forever and hydration would re-persist history every
/// launch).
@MainActor
final class SignalForwardingTests: XCTestCase {

    func testAppendForwardsOncePerLineWithStream() {
        let store = SignalStore()
        var forwarded: [(String, String?)] = []
        store.forward = { entry, stream in forwarded.append((entry.message, stream)) }

        store.append(source: "web", line: "hello", stream: "stdout")
        store.append(source: "web", line: "plain")

        XCTAssertEqual(forwarded.count, 2)
        XCTAssertEqual(forwarded[0].0, "hello")
        XCTAssertEqual(forwarded[0].1, "stdout")
        XCTAssertNil(forwarded[1].1, "stream is optional — events have none")
    }

    func testAppendExternalNeverForwards() {
        let store = SignalStore()
        var forwarded = 0
        store.forward = { _, _ in forwarded += 1 }

        store.appendExternal(source: "external.claude", line: "finding: X")

        XCTAssertEqual(forwarded, 0)
        XCTAssertEqual(store.entries.count, 1, "still lands in the UI ring")
        XCTAssertEqual(store.knownSources, ["external.claude"])
    }

    func testAppendChunkThreadsStream() {
        let store = SignalStore()
        var streams: [String?] = []
        store.forward = { _, stream in streams.append(stream) }
        var buffer = ""
        store.appendChunk(source: "web", "a\nb\n", buffer: &buffer, stream: "stderr")
        XCTAssertEqual(streams, ["stderr", "stderr"])
    }
}

/// The status choke point: every distinct transition fires the hook,
/// idempotent writes stay silent — service.health must not spam on
/// every poll or repeated stop.
@MainActor
final class RunnerStatusHookTests: XCTestCase {
    func testStatusHookFiresOnTransitionOnly() throws {
        let sandbox = try TestSandbox()
        defer { sandbox.destroy() }
        let project = try sandbox.makeProject(named: "hook-proj")
        let manager = RunnerManager(project: project, signals: SignalStore())

        var events: [(String, String, RunnerStatus?, RunnerStatus)] = []
        manager.statusChanged = { events.append(($0, $1, $2, $3)) }

        // start() against a cwd that doesn't exist: Process.run() throws,
        // and the manager records .failed — one transition, from nil.
        let runner = ParsedRunner(
            name: "ghost", cwd: "repos/nope/main", start: "echo hi",
            stop: nil, port: nil, portEnv: nil, open: nil)
        manager.reload(from: "[[runners]]\nname = \"ghost\"\ncwd = \"repos/nope/main\"\nstart = \"echo hi\"\n")
        manager.start(manager.runners[0])
        _ = runner  // silence unused warning if reload path differs

        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].0, "ghost")
        XCTAssertNil(events[0].2)
        if case .failed = events[0].3 {} else {
            XCTFail("expected .failed, got \(events[0].3)")
        }
    }
}
```

(If `RunnerManagerLogicTests`' existing bad-cwd start test records a different status shape, mirror that test's arrangement — the assertion that matters is: exactly one hook fire, previous nil, new non-running.)

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter SignalForwardingTests 2>&1 | tail -10`
Expected: BUILD FAILURE — `value of type 'SignalStore' has no member 'forward'`.

- [ ] **Step 3: Extend the in-memory SignalStore**

In `Sources/Dreamux/Models/Signal.swift`, inside `SignalStore`:

Add below `pendingSourceFocus`:

```swift
    /// Write-through hook: called once per appended line so the owning
    /// session can fan the line onto the persistent SignalBus. nil by
    /// default — tests and headless stores stay in-memory-only.
    /// `stream` is "stdout"/"stderr" when the caller knows it.
    var forward: ((SignalEntry, _ stream: String?) -> Void)?
```

Change `append` to:

```swift
    func append(source: String, line: String, at timestamp: Date = .now, stream: String? = nil) {
        let entry = insertEntry(source: source, line: line, at: timestamp)
        forward?(entry, stream)
    }

    /// Append WITHOUT forwarding — for lines that already live on the
    /// bus/disk (hydration at launch, external emits surfacing in the
    /// UI). Forwarding these would re-persist history or bounce
    /// external signals in a UI→bus→UI loop.
    func appendExternal(source: String, line: String, at timestamp: Date = .now) {
        _ = insertEntry(source: source, line: line, at: timestamp)
    }

    @discardableResult
    private func insertEntry(source: String, line: String, at timestamp: Date) -> SignalEntry {
        let entry = SignalEntry(
            id: nextID,
            timestamp: timestamp,
            source: source,
            level: Self.detectLevel(in: line),
            message: line
        )
        nextID &+= 1
        entries.append(entry)
        if entries.count > cap {
            entries.removeFirst(entries.count - cap)
        }
        if !knownSourcesSet.contains(source) {
            knownSourcesSet.insert(source)
            knownSources.append(source)
        }
        return entry
    }
```

Change `appendChunk`'s signature to `func appendChunk(source: String, _ chunk: String, buffer: inout String, stream: String? = nil)` and its `append(...)` call to `append(source: source, line: trimmed, stream: stream)`.

- [ ] **Step 4: RunnerManager — status choke point and stream tags**

In `Sources/Dreamux/Models/RunnerManager.swift`:

1. Add near `pendingIsolation`:

```swift
    /// Fires on every distinct status transition (same-value writes are
    /// swallowed) — the project session turns these into service.health
    /// signals. nil keeps tests and headless managers silent.
    var statusChanged: ((_ runnerName: String, _ branch: String, _ previous: RunnerStatus?, _ new: RunnerStatus) -> Void)?

    /// Single write path for `statusByInstance` so transitions can't
    /// slip past the hook. Same value → no event (health must not spam).
    private func setStatus(_ status: RunnerStatus, for key: RunnerInstanceKey) {
        let previous = statusByInstance[key]
        guard previous != status else { return }
        statusByInstance[key] = status
        statusChanged?(key.runnerName, key.branch, previous, status)
    }
```

2. Replace every direct assignment `statusByInstance[<key>] = <status>` in `start()`, the termination handler, and `stop()`/anywhere else with `setStatus(<status>, for: <key>)`. (The `reload(from:)` filter that *removes* entries stays as-is — removal is bookkeeping, not a health transition. Search: `grep -n "statusByInstance\[" Sources/Dreamux/Models/RunnerManager.swift` and convert each write; reads stay.) Note the termination handler runs off-actor and hops via `Task { @MainActor ... }` — `setStatus` is called inside that hop, unchanged.
3. In `start()`, the two readability handlers call `signals.appendChunk`. Add the stream: the stdout handler passes `stream: "stdout"`, the stderr handler `stream: "stderr"` (they hop to the main actor already — only the argument list changes).

- [ ] **Step 5: ProjectSession — wire hydration, forwarding, subscription, health**

In `Sources/Dreamux/Models/ProjectSession.swift` (it creates `signals` and `runners` around lines 71–72), add `import Combine` if missing, a cancellable property, and call a new private method at the end of `init`:

```swift
    private var busSubscription: AnyCancellable?
```

```swift
    /// Bridge this project's in-memory signal ring to the app-global
    /// persistent bus. Order matters: hydrate FIRST (appendExternal —
    /// no forwarding), only then install `forward`, so history is never
    /// re-persisted on launch.
    private func wireSignalPersistence() {
        let projectDir = project.rootPath.path
        let bus = SignalBus.shared
        let uiStore = signals

        // 1. Hydrate the ring with recent history for this project.
        if let disk = bus.store {
            Task { @MainActor in
                let rows = (try? await disk.query(
                    kind: SignalKind.terminalLine, source: nil,
                    projectDir: projectDir, since: nil, limit: 500)) ?? []
                for row in rows.reversed() {  // query is newest-first; ring wants oldest-first
                    guard case .object(let obj) = row.payload,
                          case .string(let text)? = obj["text"] else { continue }
                    uiStore.appendExternal(source: row.source, line: text, at: row.ts)
                }
                self.installSignalForwarding(projectDir: projectDir, bus: bus)
            }
        } else {
            installSignalForwarding(projectDir: projectDir, bus: bus)
        }

        // 2. Surface external emits (MCP signals_emit) in this project's
        //    Signals page, live. App-origin signals are skipped — they
        //    already went through the UI store on their way in.
        busSubscription = bus.publisher
            .receive(on: DispatchQueue.main)
            .sink { [weak uiStore] signal in
                guard signal.tags["origin"] != "app",
                      signal.tags["project_dir"] == projectDir else { return }
                uiStore?.appendExternal(
                    source: signal.source,
                    line: Self.externalLine(for: signal),
                    at: signal.ts)
            }

        // 3. Health transitions → service.health envelopes.
        runners.statusChanged = { runnerName, branch, previous, new in
            bus.emit(Signal(
                source: "services.\(runnerName)",
                kind: SignalKind.serviceHealth,
                severity: Self.healthSeverity(for: new),
                tags: [
                    "origin": "app",
                    "project_dir": projectDir,
                    "service": runnerName,
                    "branch": branch,
                ],
                payload: .object([
                    "previous": .string(previous.map(Self.statusWord) ?? "none"),
                    "current": .string(Self.statusWord(new)),
                ])))
        }
    }

    private func installSignalForwarding(projectDir: String, bus: SignalBus) {
        signals.forward = { entry, stream in
            var tags = [
                "origin": "app",
                "project_dir": projectDir,
                "service": entry.source,
                "level": entry.level.rawValue,
            ]
            if let stream { tags["stream"] = stream }
            bus.emit(Signal(
                source: entry.source,
                kind: SignalKind.terminalLine,
                ts: entry.timestamp,
                severity: entry.level == .error ? .warning : .info,
                tags: tags,
                payload: .terminalLine(entry.message, stream: stream ?? "combined")))
        }
    }

    /// Render an external signal as one log line for the UI ring.
    private static func externalLine(for signal: Signal) -> String {
        if case .object(let obj) = signal.payload,
           case .string(let text)? = obj["text"] {
            return "[\(signal.kind)] \(text)"
        }
        let payload: String
        if let data = try? JSONEncoder().encode(signal.payload),
           let s = String(data: data, encoding: .utf8) {
            payload = s
        } else {
            payload = ""
        }
        return "[\(signal.kind)] \(payload)"
    }

    private static func healthSeverity(for status: RunnerStatus) -> SignalSeverityLevel {
        switch status {
        case .running: return .success
        case .failed: return .critical
        case .exited(let code): return code == 0 ? .info : .warning
        case .idle: return .info
        }
    }

    private static func statusWord(_ status: RunnerStatus) -> String {
        switch status {
        case .idle: return "idle"
        case .running: return "running"
        case .failed: return "failed"
        case .exited(let code): return "exited(\(code))"
        }
    }
```

Call `wireSignalPersistence()` as the last line of `ProjectSession.init`. (Read the actual init first: adapt the property names the code above uses — `project`, `signals`, `runners` — to whatever `ProjectSession` actually calls its Project, SignalStore, and RunnerManager properties, and keep the call at the very end of `init` so everything it wires already exists.)

- [ ] **Step 6: Run tests to verify they pass**

Run: `swift test --filter "SignalForwardingTests|RunnerStatusHookTests" 2>&1 | tail -5`
Expected: both suites pass (4 tests).

- [ ] **Step 7: Full suite, then commit**

Run: `swift test 2>&1 | grep -E "Test Suite 'All tests'"` → passed. (Existing `RunnerLifecycleTests` exercise the converted status writes with real processes — they must stay green.)

```bash
git add Sources/Dreamux/Models/Signal.swift Sources/Dreamux/Models/RunnerManager.swift Sources/Dreamux/Models/ProjectSession.swift Tests/DreamuxTests/SignalForwardingTests.swift
git commit -m "Service logs and health transitions persist through the signal bus

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: MCP script, installer, and agent awareness

**Files:**
- Create: `mcp/dreamux-signals-mcp.ts` (vendored port of `/Users/olliejarvis/Development/cmux-main/mcp/cmux-signals-mcp.ts`)
- Create: `mcp/README.md`
- Create: `Sources/Dreamux/Signals/MCPInstaller.swift` (port of cmux `Sources/Signals/MCPInstaller.swift`)
- Modify: `Sources/Dreamux/Views/WorkspaceSidebar.swift` (`openPlanningSession`, ~line 794)
- Modify: `Sources/Dreamux/Shell/PlanRunCoordinator.swift` (`runPlan`, ~line 76)
- Modify: `Sources/Dreamux/Shell/PlanPrompts.swift:26-46` (`runPlan` prompt)
- Modify: `Sources/Dreamux/Views/SignalsView.swift` (filter-bar header affordance)
- Modify: `Sources/Dreamux/Views/ContentView.swift` (`case .signals:` in `mainPane` — SignalsView gains a `projectDir` argument)
- Modify: `.claude/settings.local.json` (remove stale entry)
- Test: `Tests/DreamuxTests/MCPInstallerTests.swift`

**Interfaces:**
- Consumes: nothing new from Tasks 1–3 (installer is standalone file I/O).
- Produces: `enum MCPInstaller` — `static func status(at projectDir: String) -> Status` (`notInstalled` / `installed(commandPath:)` / `installedButScriptMissing(referencedPath:)` / `noScriptAvailable`), `@discardableResult static func installIfNeeded(at projectDir: String, force: Bool = false) -> InstallResult`, `static func resolveScriptPath() -> String?`, `static func resolveBunPath() -> String`.

- [ ] **Step 1: Vendor the MCP script**

Copy `/Users/olliejarvis/Development/cmux-main/mcp/cmux-signals-mcp.ts` → `mcp/dreamux-signals-mcp.ts`, applying ONLY these mechanical renames (the tool logic, SQL, subscription plumbing port verbatim):

1. Header comment: cmux→Dreamux; wire-up line becomes `claude mcp add dreamux-signals bun run /absolute/path/to/clayspace/mcp/dreamux-signals-mcp.ts` (the installer normally does this via `.mcp.json`).
2. Env vars: `CMUX_SIGNALS_DB`→`DREAMUX_SIGNALS_DB`, `CMUX_PROJECT_DIR`→`DREAMUX_PROJECT_DIR`, `CMUX_SIGNALS_ALL_PROJECTS`→`DREAMUX_SIGNALS_ALL_PROJECTS`, `CMUX_SIGNALS_EMIT_SOCKET`→`DREAMUX_SIGNALS_EMIT_SOCKET`.
3. `resolveDBPath()`: production path `join(root, "com.dreamux.Dreamux", "signals.db")`; the scan prefix `"com.cmuxterm.app"` → `"com.dreamux."`; error strings say Dreamux.
4. `resolveEmitSocketPath()`: `/tmp/cmux-emit-${bundleID}.sock` → `/tmp/dreamux-emit-${bundleID}.sock`; fallback bundle id `"cmux"` → `"com.dreamux.Dreamux"`.
5. Server metadata: `name: "cmux-signals"` → `name: "dreamux-signals"`; notification method `notifications/cmux/signal` → `notifications/dreamux/signal` (three occurrences: subscribe tool description, `jsonResult({... notification_method ...})`, and `server.notification({ method: ... })`).
6. stderr log prefixes `cmux-signals-mcp:` → `dreamux-signals-mcp:`; tool descriptions' prose mentions of cmux → Dreamux (descriptions only — tool NAMES stay `signals_*`).
7. Tool description for `signals_query`: the "Common kinds" list becomes `` `terminal.line`, `service.health`, plus whatever agents emit (`agent.note`, `bug.report`, …) ``.

Create `mcp/README.md`:

```markdown
# dreamux-signals MCP

Read/write bridge between external Claude Code agents and Dreamux's
signal ledger (`~/Library/Application Support/com.dreamux.Dreamux/signals.db`).
Read tools query SQLite directly (read-only, WAL-safe); `signals_emit`
and `signals_subscribe` talk to the running app over
`/tmp/dreamux-emit-com.dreamux.Dreamux.sock`.

Dreamux auto-installs this into a project's `.mcp.json` at agent-session
start (see `MCPInstaller.swift`). Manual wiring:

    claude mcp add dreamux-signals ~/.asdf/installs/bun/<ver>/bin/bun run <this repo>/mcp/dreamux-signals-mcp.ts

Env overrides: DREAMUX_SIGNALS_DB, DREAMUX_PROJECT_DIR,
DREAMUX_SIGNALS_ALL_PROJECTS=1, DREAMUX_SIGNALS_EMIT_SOCKET.
Requires bun (the installer probes ~/.bun, Homebrew, and asdf installs
for an absolute path — MCP servers spawn with a stripped PATH).
```

- [ ] **Step 2: Write the failing installer tests**

Create `Tests/DreamuxTests/MCPInstallerTests.swift`:

```swift
import XCTest
@testable import Dreamux

/// Merge semantics for `.mcp.json`: the installer must add or refresh
/// the dreamux-signals entry without ever clobbering other servers or
/// a malformed file — agents' hand-written config is not ours to lose.
final class MCPInstallerTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-install-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Pin the script override so tests don't depend on this
        // machine's dev-checkout layout.
        let script = dir.appendingPathComponent("dreamux-signals-mcp.ts")
        try "// stub".write(to: script, atomically: true, encoding: .utf8)
        UserDefaults.standard.set(script.path, forKey: MCPInstaller.scriptPathDefaultsKey)
    }

    override func tearDownWithError() throws {
        UserDefaults.standard.removeObject(forKey: MCPInstaller.scriptPathDefaultsKey)
        try? FileManager.default.removeItem(at: dir)
    }

    private func readServers() throws -> [String: Any] {
        let data = try Data(contentsOf: dir.appendingPathComponent(".mcp.json"))
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (root?["mcpServers"] as? [String: Any]) ?? [:]
    }

    func testFreshInstallWritesEntryWithProjectEnv() throws {
        let result = MCPInstaller.installIfNeeded(at: dir.path)
        guard case .installed = result else {
            return XCTFail("expected .installed, got \(result)")
        }
        let servers = try readServers()
        let entry = servers["dreamux-signals"] as? [String: Any]
        XCTAssertNotNil(entry)
        let env = entry?["env"] as? [String: String]
        XCTAssertEqual(env?["DREAMUX_PROJECT_DIR"], dir.path,
                       "agents run in feature subdirs; scoping must pin the project root")
        if case .installed = MCPInstaller.status(at: dir.path) {} else {
            XCTFail("status should read back installed")
        }
    }

    func testExistingServersArePreserved() throws {
        let existing = ["mcpServers": ["other": ["command": "/bin/echo"]]]
        let data = try JSONSerialization.data(withJSONObject: existing, options: [.prettyPrinted])
        try data.write(to: dir.appendingPathComponent(".mcp.json"))

        _ = MCPInstaller.installIfNeeded(at: dir.path)

        let servers = try readServers()
        XCTAssertNotNil(servers["other"], "merge must not drop unrelated servers")
        XCTAssertNotNil(servers["dreamux-signals"])
    }

    func testMalformedJSONIsNotClobbered() throws {
        let url = dir.appendingPathComponent(".mcp.json")
        try "{ not json".write(to: url, atomically: true, encoding: .utf8)

        let result = MCPInstaller.installIfNeeded(at: dir.path)
        if case .skippedReason = result {} else {
            XCTFail("malformed file must be left alone, got \(result)")
        }
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "{ not json")
    }

    func testWorkingEntryIsNotRewrittenWithoutForce() throws {
        _ = MCPInstaller.installIfNeeded(at: dir.path)
        let before = try Data(contentsOf: dir.appendingPathComponent(".mcp.json"))
        let second = MCPInstaller.installIfNeeded(at: dir.path)
        if case .alreadyInstalled = second {} else {
            XCTFail("idempotence: got \(second)")
        }
        XCTAssertEqual(before, try Data(contentsOf: dir.appendingPathComponent(".mcp.json")),
                       "no git churn from repeated session starts")
    }

    func testStaleReferenceIsRefreshed() throws {
        let url = dir.appendingPathComponent(".mcp.json")
        let stale = ["mcpServers": ["dreamux-signals": ["command": "/bun", "args": ["run", "/gone.ts"]]]]
        try JSONSerialization.data(withJSONObject: stale).write(to: url)

        let result = MCPInstaller.installIfNeeded(at: dir.path)
        if case .installed = result {} else {
            XCTFail("stale path must be refreshed, got \(result)")
        }
    }
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `swift test --filter MCPInstallerTests 2>&1 | tail -10`
Expected: BUILD FAILURE — `cannot find 'MCPInstaller' in scope`.

- [ ] **Step 4: Port the installer**

Copy `/Users/olliejarvis/Development/cmux-main/Sources/Signals/MCPInstaller.swift` → `Sources/Dreamux/Signals/MCPInstaller.swift`, applying ONLY these changes:

1. Server key `"cmux-signals"` → `"dreamux-signals"` (all occurrences: `status`, `installIfNeeded`).
2. Defaults keys: `"cmux.signals.mcpScriptPath"` → `"dreamux.signals.mcpScriptPath"`, `"cmux.signals.mcpBunPath"` → `"dreamux.signals.mcpBunPath"`.
3. `resolveRunner()`: bundled binary path `"bin/cmux-signals-mcp"` → `"bin/dreamux-signals-mcp"` (keep the branch — it just won't resolve until we ever bundle one); bundled script `"mcp/cmux-signals-mcp.ts"` → `"mcp/dreamux-signals-mcp.ts"`.
4. `resolveScriptPath()` dev candidates become:

```swift
        let candidates = [
            "\(home)/Development/clayspace/mcp/dreamux-signals-mcp.ts",
            "\(home)/Development/dreamux/mcp/dreamux-signals-mcp.ts",
            "\(home)/.dreamux/mcp/dreamux-signals-mcp.ts",
        ]
```

5. `installIfNeeded` gains project scoping: the method signature stays, but the `desired` dict adds an `env` key in BOTH runner shapes:

```swift
        let desired: [String: Any]
        let installedPath: String
        let env = ["DREAMUX_PROJECT_DIR": projectDir]
        switch runner {
        case .compiledBinary(let path):
            desired = ["command": path, "env": env]
            installedPath = path
        case .bunScript(let bun, let script):
            desired = [
                "command": bun,
                "args": ["run", script],
                "env": env,
            ]
            installedPath = script
        }
```

6. `resolveBunPath()` ports verbatim (it already probes `~/.bun/bin/bun`, Homebrew, and `~/.asdf/installs/bun/<ver>/bin/bun` — the asdf branch is the one that matters on this machine; the shim alone fails with "No version is set").
7. Doc comments: cmux→dreamux, `EnvironmentInstance.init` reference → "agent-session start (planning tab / plan run)".

- [ ] **Step 5: Run installer tests**

Run: `swift test --filter MCPInstallerTests 2>&1 | tail -5`
Expected: `Test Suite 'MCPInstallerTests' passed` — 5 tests.

- [ ] **Step 6: Call the installer at session starts + prompt line + UI affordance + config cleanup**

1. `Sources/Dreamux/Views/WorkspaceSidebar.swift`, in `openPlanningSession` right before `reuseOrOpenPlanningTab(at: repoStore.project.rootPath.path)` is called, add:

```swift
        MCPInstaller.installIfNeeded(at: repoStore.project.rootPath.path)
```

2. `Sources/Dreamux/Shell/PlanRunCoordinator.swift`, in `runPlan` right before `session.openPlanAgentTab(at: featureDir.path, ...)`, add:

```swift
        MCPInstaller.installIfNeeded(at: featureDir.path)
```

3. `Sources/Dreamux/Shell/PlanPrompts.swift`, in `runPlan(planRelativePath:docsLinkName:)`, add one bullet to the contract list (after the "Commit exactly…" bullet):

```swift
        - The `dreamux-signals` MCP is available: `signals_query` / \
        `signals_recent` read this project's live service logs (useful \
        when a dev server misbehaves), and `signals_emit` records \
        findings the app surfaces in its Signals page.
```

4. `Sources/Dreamux/Views/SignalsView.swift`: in the filter bar's first `HStack` (the row with the search field), add a trailing compact button before the clear button:

```swift
                mcpStatusButton
```

and the supporting members on the view:

```swift
    @State private var mcpStatus: MCPInstaller.Status?

    /// Manual (re)install affordance for the dreamux-signals MCP —
    /// mirrors the auto-install at session start, for when the user
    /// wants to wire a project up (or repair a stale path) by hand.
    private var mcpStatusButton: some View {
        Button {
            _ = MCPInstaller.installIfNeeded(at: projectDir, force: true)
            mcpStatus = MCPInstaller.status(at: projectDir)
        } label: {
            switch mcpStatus {
            case .installed:
                Label("MCP ready", systemImage: "checkmark.seal")
            case .installedButScriptMissing:
                Label("Repair MCP", systemImage: "exclamationmark.triangle")
            case .noScriptAvailable:
                Label("MCP unavailable", systemImage: "xmark.seal")
            default:
                Label("Install MCP", systemImage: "puzzlepiece.extension")
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .help("Give agents signal access via .mcp.json (dreamux-signals)")
        .onAppear { mcpStatus = MCPInstaller.status(at: projectDir) }
    }
```

`SignalsView` needs the project directory for this: add `let projectDir: String` to its stored properties and pass it at the construction site in `Sources/Dreamux/Views/ContentView.swift` (`case .signals:` in `mainPane`): `SignalsView(signals: signals, runners: runners, projectDir: repoStore.project.rootPath.path)`.

5. `.claude/settings.local.json` (repo root): delete the `"cmux-signals"` element so the array reads `"disabledMcpjsonServers": []`. Keep everything else byte-identical.

- [ ] **Step 7: Full suite, then commit**

Run: `swift test 2>&1 | grep -E "Test Suite 'All tests'"` → passed.

```bash
git add mcp/dreamux-signals-mcp.ts mcp/README.md Sources/Dreamux/Signals/MCPInstaller.swift Sources/Dreamux/Views/WorkspaceSidebar.swift Sources/Dreamux/Shell/PlanRunCoordinator.swift Sources/Dreamux/Shell/PlanPrompts.swift Sources/Dreamux/Views/SignalsView.swift Sources/Dreamux/Views/ContentView.swift .claude/settings.local.json Tests/DreamuxTests/MCPInstallerTests.swift
git commit -m "dreamux-signals MCP: vendored server, auto-installer, agent prompt line

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 5: End-to-end verification + merge gate

**Files:** none created (verification + git only)

- [ ] **Step 1: Build the bundle and relaunch from the worktree**

```bash
./scripts/make-app.sh
PID=$(pgrep -x Dreamux); if [ -n "$PID" ]; then kill -TERM "$PID"; while kill -0 "$PID" 2>/dev/null; do sleep 0.3; done; fi
open ./Dreamux.app --args -ApplePersistenceIgnoreState YES
sleep 4
```

- [ ] **Step 2: Verify persistence end-to-end with sqlite3**

Start any configured runner from the app header (or ask the controller to). Then:

```bash
sqlite3 "$HOME/Library/Application Support/com.dreamux.Dreamux/signals.db" \
  "SELECT kind, source, substr(payload_json,1,60) FROM signals ORDER BY ts DESC LIMIT 5;"
```

Expected: recent `terminal.line` rows (and a `service.health` row from the start transition). Also verify the socket exists: `ls -l /tmp/dreamux-emit-com.dreamux.Dreamux.sock`.

- [ ] **Step 3: Smoke the MCP script over stdio**

```bash
BUN="$HOME/.asdf/installs/bun/1.3.13/bin/bun"
printf '%s\n%s\n%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"smoke","version":"0"}}}' \
  '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"signals_recent","arguments":{"limit":3}}}' \
  | DREAMUX_SIGNALS_ALL_PROJECTS=1 "$BUN" run mcp/dreamux-signals-mcp.ts 2>/dev/null | tail -1
```

Expected: a JSON-RPC result whose content is the 3 most recent signals. (If bun needs `@modelcontextprotocol/sdk`, run `cd mcp && "$BUN" add @modelcontextprotocol/sdk && cd ..` first and commit the resulting `mcp/package.json` + lockfile with a follow-up commit "mcp: pin @modelcontextprotocol/sdk".) Then smoke `signals_emit` the same way and confirm the line appears in the app's Signals page (external emit → bus → UI path).

- [ ] **Step 4: Verify `.mcp.json` install path**

In the app, open a planning session (or run `MCPInstaller` indirectly by clicking "Install MCP" in Signals). Then:

```bash
cat <the project's root>/.mcp.json
```

Expected: a `dreamux-signals` entry with absolute bun path, absolute script path, and `env.DREAMUX_PROJECT_DIR` = project root.

- [ ] **Step 5: Present results to the user and wait for merge approval.** Do not merge without it.

- [ ] **Step 6: Merge and push (after approval)**

```bash
cd /Users/olliejarvis/Development/clayspace
git status --short && git log --oneline -1
git merge --ff-only signals-persistence-mcp || git merge --no-edit signals-persistence-mcp
swift test 2>&1 | grep -E "Test Suite 'All tests'"
git push origin main
git worktree remove .claude/worktrees/signals-persistence-mcp
git branch -d signals-persistence-mcp
./scripts/make-app.sh
PID=$(pgrep -x Dreamux); if [ -n "$PID" ]; then kill -TERM "$PID"; while kill -0 "$PID" 2>/dev/null; do sleep 0.3; done; fi
open /Users/olliejarvis/Development/clayspace/Dreamux.app
```

Expected: ff merge (re-verify SHAs — main may move from parallel sessions), suite green on main, push accepted, canonical app relaunched from main.
