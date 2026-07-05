import Foundation
import SQLite3

/// How long to keep each kind of signal before the store trims it.
/// Terminal lines are loud and short-lived; health transitions and
/// most analytical signals deserve a longer window. New kinds use
/// `defaultTTL` until they're called out explicitly here.
struct SignalRetentionPolicy: Sendable {
    /// Per-kind override, in seconds.
    var perKindTTL: [String: TimeInterval]
    /// Fallback for kinds not in `perKindTTL`.
    var defaultTTL: TimeInterval

    static let `default` = SignalRetentionPolicy(
        perKindTTL: [
            SignalKind.terminalLine:  TimeInterval(3 * 24 * 60 * 60),   // 3 days
            SignalKind.serviceHealth: TimeInterval(30 * 24 * 60 * 60),  // 30 days
        ],
        defaultTTL: TimeInterval(30 * 24 * 60 * 60)
    )

    func cutoff(forKind kind: String, now: Date) -> Date {
        let ttl = perKindTTL[kind] ?? defaultTTL
        return now.addingTimeInterval(-ttl)
    }
}

enum SignalStoreError: Error, CustomStringConvertible {
    case openFailed(String)
    case prepareFailed(String, sql: String)
    case stepFailed(String, sql: String)
    case codecFailed(String)

    var description: String {
        switch self {
        case .openFailed(let m): return "SignalStore open failed: \(m)"
        case .prepareFailed(let m, let sql): return "SignalStore prepare failed: \(m) — sql: \(sql)"
        case .stepFailed(let m, let sql): return "SignalStore step failed: \(m) — sql: \(sql)"
        case .codecFailed(let m): return "SignalStore codec failed: \(m)"
        }
    }
}

/// SQLite-backed signal ledger. Single writer queue, WAL journaling
/// so reads don't block the writer. Schema is intentionally
/// Postgres-compatible (`ts` as int64 millis-since-epoch, JSON text
/// for tags/payload) so the eventual remote backend is a port, not
/// a rewrite.
final class SQLiteSignalStore: @unchecked Sendable {
    private let dbURL: URL
    private let queue: DispatchQueue
    private var db: OpaquePointer?
    private var insertStmt: OpaquePointer?
    private var trimTimer: DispatchSourceTimer?

    /// `dbURL` is created if missing. Parent dir is also created.
    init(dbURL: URL) throws {
        self.dbURL = dbURL
        self.queue = DispatchQueue(label: "dreamux.signals.store", qos: .utility)
        try queue.sync { try self.openLocked() }
    }

    deinit {
        trimTimer?.cancel()
        if let stmt = insertStmt { sqlite3_finalize(stmt) }
        if let db = db { sqlite3_close_v2(db) }
    }

    /// Start a periodic background trim. Runs once immediately, then
    /// every `interval` seconds. Pure side-effect setup so the
    /// `SignalBus` can call this once at startup without owning the
    /// timer plumbing.
    func startPeriodicTrim(
        policy: SignalRetentionPolicy = .default,
        interval: TimeInterval = 60 * 60
    ) {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 5, repeating: interval)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            do { _ = try self.trimLocked(policy: policy, now: Date()) }
            catch { NSLog("SignalStore.trim failed: %@", String(describing: error)) }
        }
        timer.resume()
        trimTimer = timer
    }

    /// Default location: `~/Library/Application Support/<bundle-id>/signals.db`.
    /// Tagged debug builds get unique bundle IDs, so each tag gets its
    /// own ledger automatically.
    static func defaultURL() throws -> URL {
        let fm = FileManager.default
        let base = try fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let bundleID = Bundle.main.bundleIdentifier ?? "com.dreamux.Dreamux"
        let dir = base.appendingPathComponent(bundleID, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("signals.db")
    }

    // MARK: - Persistence API

    /// Append a signal. Fire-and-forget for hot paths (terminal line
    /// fan-out). The store is responsible for ordering writes; callers
    /// must not assume durability before the next `query` returns.
    func append(_ signal: Signal) {
        queue.async { [weak self] in
            guard let self else { return }
            do { try self.insertLocked(signal) }
            catch {
                NSLog("SignalStore.append failed: %@", String(describing: error))
            }
        }
    }

    /// Fetch recent signals, newest first by `ts`.
    /// - Parameters:
    ///   - kind: optional exact-match filter.
    ///   - source: optional exact-match filter.
    ///   - projectDir: optional exact-match filter on the `project_dir` tag.
    ///   - since: only return signals with `ts >= since`.
    ///   - limit: cap on rows returned.
    func query(
        kind: String?,
        source: String?,
        projectDir: String?,
        since: Date?,
        limit: Int
    ) async throws -> [Signal] {
        try await withCheckedThrowingContinuation { cont in
            queue.async { [weak self] in
                guard let self else {
                    cont.resume(returning: [])
                    return
                }
                do {
                    let rows = try self.queryLocked(
                        kind: kind, source: source, projectDir: projectDir, since: since, limit: limit
                    )
                    cont.resume(returning: rows)
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    /// Convenience: most recent N signals, optionally project-scoped.
    func recent(limit: Int = 200, projectDir: String? = nil) async throws -> [Signal] {
        try await query(kind: nil, source: nil, projectDir: projectDir, since: nil, limit: limit)
    }

    /// Delete rows older than the policy allows. Returns total rows
    /// deleted across all kinds. Idempotent and cheap; safe to run
    /// hourly.
    @discardableResult
    func trim(policy: SignalRetentionPolicy, now: Date) async throws -> Int {
        try await withCheckedThrowingContinuation { cont in
            queue.async { [weak self] in
                guard let self else { cont.resume(returning: 0); return }
                do { cont.resume(returning: try self.trimLocked(policy: policy, now: now)) }
                catch { cont.resume(throwing: error) }
            }
        }
    }

    // MARK: - Locked (queue-only) primitives

    private func openLocked() throws {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(dbURL.path, &handle, flags, nil)
        guard rc == SQLITE_OK, let handle else {
            let msg = handle.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "rc=\(rc)"
            if let handle { sqlite3_close_v2(handle) }
            throw SignalStoreError.openFailed(msg)
        }
        self.db = handle

        // WAL: readers don't block the writer; useful when query() runs
        // from the UI thread while emitters are pumping in lines.
        try execLocked("PRAGMA journal_mode=WAL;")
        try execLocked("PRAGMA synchronous=NORMAL;")

        try execLocked("""
            CREATE TABLE IF NOT EXISTS signals (
                id           TEXT PRIMARY KEY,
                source       TEXT NOT NULL,
                kind         TEXT NOT NULL,
                ts           INTEGER NOT NULL,
                severity     TEXT NOT NULL,
                tags_json    TEXT NOT NULL,
                payload_json TEXT NOT NULL
            );
        """)
        try execLocked("CREATE INDEX IF NOT EXISTS idx_signals_kind_ts ON signals(kind, ts DESC);")
        try execLocked("CREATE INDEX IF NOT EXISTS idx_signals_source_ts ON signals(source, ts DESC);")
        try execLocked("CREATE INDEX IF NOT EXISTS idx_signals_ts ON signals(ts DESC);")

        try prepareInsertLocked()
    }

    private func execLocked(_ sql: String) throws {
        guard let db else { throw SignalStoreError.openFailed("db not open") }
        var err: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &err)
        if rc != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "rc=\(rc)"
            sqlite3_free(err)
            throw SignalStoreError.stepFailed(msg, sql: sql)
        }
    }

    private func prepareInsertLocked() throws {
        guard let db else { throw SignalStoreError.openFailed("db not open") }
        let sql = """
            INSERT OR REPLACE INTO signals
                (id, source, kind, ts, severity, tags_json, payload_json)
            VALUES (?, ?, ?, ?, ?, ?, ?);
        """
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let stmt else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw SignalStoreError.prepareFailed(msg, sql: sql)
        }
        self.insertStmt = stmt
    }

    private func insertLocked(_ s: Signal) throws {
        guard let stmt = insertStmt else { throw SignalStoreError.openFailed("insert stmt missing") }
        sqlite3_reset(stmt)
        sqlite3_clear_bindings(stmt)

        let tagsJson = try Self.encodeJSON(s.tags)
        let payloadJson = try Self.encodeJSON(s.payload)
        let tsMillis = Int64(s.ts.timeIntervalSince1970 * 1000)

        bindText(stmt, 1, s.id)
        bindText(stmt, 2, s.source)
        bindText(stmt, 3, s.kind)
        sqlite3_bind_int64(stmt, 4, tsMillis)
        bindText(stmt, 5, s.severity.rawValue)
        bindText(stmt, 6, tagsJson)
        bindText(stmt, 7, payloadJson)

        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE else {
            let msg = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "rc=\(rc)"
            throw SignalStoreError.stepFailed(msg, sql: "INSERT signals")
        }
    }

    private func queryLocked(
        kind: String?,
        source: String?,
        projectDir: String?,
        since: Date?,
        limit: Int
    ) throws -> [Signal] {
        guard let db else { throw SignalStoreError.openFailed("db not open") }

        var sql = """
            SELECT id, source, kind, ts, severity, tags_json, payload_json
            FROM signals
            WHERE 1=1
        """
        if kind != nil { sql += " AND kind = ?" }
        if source != nil { sql += " AND source = ?" }
        if projectDir != nil { sql += " AND json_extract(tags_json, '$.project_dir') = ?" }
        if since != nil { sql += " AND ts >= ?" }
        sql += " ORDER BY ts DESC LIMIT \(max(0, limit));"

        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let stmt else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw SignalStoreError.prepareFailed(msg, sql: sql)
        }
        defer { sqlite3_finalize(stmt) }

        var idx: Int32 = 1
        if let kind { bindText(stmt, idx, kind); idx += 1 }
        if let source { bindText(stmt, idx, source); idx += 1 }
        if let projectDir { bindText(stmt, idx, projectDir); idx += 1 }
        if let since {
            sqlite3_bind_int64(stmt, idx, Int64(since.timeIntervalSince1970 * 1000))
            idx += 1
        }

        var rows: [Signal] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = readText(stmt, 0) ?? ""
            let src = readText(stmt, 1) ?? ""
            let knd = readText(stmt, 2) ?? ""
            let tsMillis = sqlite3_column_int64(stmt, 3)
            let sev = readText(stmt, 4) ?? "info"
            let tagsJson = readText(stmt, 5) ?? "{}"
            let payloadJson = readText(stmt, 6) ?? "null"

            let tags: [String: String] = (try? Self.decodeJSON(tagsJson)) ?? [:]
            let payload: SignalPayload = (try? Self.decodeJSON(payloadJson)) ?? .null

            rows.append(Signal(
                id: id,
                source: src,
                kind: knd,
                ts: Date(timeIntervalSince1970: TimeInterval(tsMillis) / 1000.0),
                severity: SignalSeverityLevel(rawValue: sev) ?? .info,
                tags: tags,
                payload: payload
            ))
        }
        return rows
    }

    @discardableResult
    private func trimLocked(policy: SignalRetentionPolicy, now: Date) throws -> Int {
        guard let db else { throw SignalStoreError.openFailed("db not open") }
        var total = 0

        // Per-kind cutoffs.
        for (kind, _) in policy.perKindTTL {
            let cutoff = policy.cutoff(forKind: kind, now: now)
            let cutoffMs = Int64(cutoff.timeIntervalSince1970 * 1000)
            let sql = "DELETE FROM signals WHERE kind = ? AND ts < ?;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
                throw SignalStoreError.prepareFailed(String(cString: sqlite3_errmsg(db)), sql: sql)
            }
            bindText(stmt, 1, kind)
            sqlite3_bind_int64(stmt, 2, cutoffMs)
            if sqlite3_step(stmt) == SQLITE_DONE {
                total += Int(sqlite3_changes(db))
            }
            sqlite3_finalize(stmt)
        }

        // Default cutoff for any kind not enumerated above.
        let knownKinds = Array(policy.perKindTTL.keys)
        let cutoff = now.addingTimeInterval(-policy.defaultTTL)
        let cutoffMs = Int64(cutoff.timeIntervalSince1970 * 1000)
        let placeholders = knownKinds.isEmpty
            ? ""
            : "AND kind NOT IN (\(knownKinds.map { _ in "?" }.joined(separator: ",")))"
        let sql = "DELETE FROM signals WHERE ts < ? \(placeholders);"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw SignalStoreError.prepareFailed(String(cString: sqlite3_errmsg(db)), sql: sql)
        }
        sqlite3_bind_int64(stmt, 1, cutoffMs)
        for (i, kind) in knownKinds.enumerated() {
            bindText(stmt, Int32(2 + i), kind)
        }
        if sqlite3_step(stmt) == SQLITE_DONE {
            total += Int(sqlite3_changes(db))
        }
        sqlite3_finalize(stmt)

        return total
    }

    // MARK: - Helpers

    private func bindText(_ stmt: OpaquePointer, _ idx: Int32, _ value: String) {
        // SQLITE_TRANSIENT tells SQLite to copy the bytes; the Swift
        // string buffer would otherwise dangle the moment withCString
        // returns.
        _ = value.withCString { cstr in
            sqlite3_bind_text(stmt, idx, cstr, -1, SQLITE_TRANSIENT_PTR)
        }
    }

    private func readText(_ stmt: OpaquePointer, _ idx: Int32) -> String? {
        guard let cstr = sqlite3_column_text(stmt, idx) else { return nil }
        return String(cString: cstr)
    }

    private static func encodeJSON<T: Encodable>(_ value: T) throws -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        let data: Data
        do { data = try enc.encode(value) }
        catch { throw SignalStoreError.codecFailed("encode: \(error)") }
        guard let s = String(data: data, encoding: .utf8) else {
            throw SignalStoreError.codecFailed("encode: utf8")
        }
        return s
    }

    private static func decodeJSON<T: Decodable>(_ json: String) throws -> T {
        guard let data = json.data(using: .utf8) else {
            throw SignalStoreError.codecFailed("decode: utf8")
        }
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw SignalStoreError.codecFailed("decode: \(error)") }
    }
}

// SQLITE_TRANSIENT is `(sqlite3_destructor_type)-1` in C; Swift can't
// import the macro directly. Tells SQLite to copy the bound bytes so
// the source buffer can be released immediately after binding.
private let SQLITE_TRANSIENT_PTR = unsafeBitCast(
    -1, to: sqlite3_destructor_type.self
)
