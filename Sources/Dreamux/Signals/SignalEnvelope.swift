import Foundation

/// A single envelope in the signal log. Every piece of feedback that
/// flows through Dreamux — terminal lines, lint findings, test results,
/// board items, telemetry — is one of these. Tabs, flows, and the MCP
/// tool are all views over a stream of `Signal`s.
///
/// Field guide:
/// - `id` — globally unique identifier. Currently UUID; will move to
///   ULID/snowflake when we ship the remote/multi-writer side.
/// - `source` — the concrete upstream emitter, e.g.
///   `services.main.api`, `github.projects.dreamux-board`. Free-form
///   string so adapter manifests can name themselves without a
///   centrally-managed enum.
/// - `kind` — what shape the payload has. See `SignalKind` for the
///   well-known values; new sources may introduce new kinds.
/// - `ts` — emission time (UTC).
/// - `severity` — `info` / `success` / `warning` / `critical`. Defaults
///   to `info` when the source can't classify.
/// - `tags` — string→string map for routing, filtering, and
///   transform-time joins. Examples: `project=dreamux`, `env=main`,
///   `service=api`, `stream=stdout`.
/// - `payload` — the source-native JSON shape. Consumers (Board tab,
///   flows, etc.) re-shape it through registered transforms; the raw
///   payload is preserved verbatim so we never lose information.
struct Signal: Identifiable, Hashable, Codable, Sendable {
    let id: String
    let source: String
    let kind: String
    let ts: Date
    let severity: SignalSeverityLevel
    let tags: [String: String]
    let payload: SignalPayload

    init(
        id: String = UUID().uuidString,
        source: String,
        kind: String,
        ts: Date = Date(),
        severity: SignalSeverityLevel = .info,
        tags: [String: String] = [:],
        payload: SignalPayload = .null
    ) {
        self.id = id
        self.source = source
        self.kind = kind
        self.ts = ts
        self.severity = severity
        self.tags = tags
        self.payload = payload
    }
}

/// Severity ladder used by the signal substrate.
enum SignalSeverityLevel: String, CaseIterable, Codable, Sendable {
    case info
    case success
    case warning
    case critical
}

/// Well-known kinds. Sources are free to introduce new strings; these
/// constants are just the ones the built-in adapters and tabs know how
/// to render specially.
enum SignalKind {
    static let terminalLine = "terminal.line"
    static let serviceHealth = "service.health"

    // Flow lifecycle events emitted by dreamux-hook (Flows spec,
    // 2026-07-06). Exact strings are load-bearing: the hook script
    // and the replay query both use them.
    static let agentStarted = "agent.started"
    static let agentStopped = "agent.stopped"
    static let taskCreated = "task.created"
    static let taskCompleted = "task.completed"
    static let sessionStopped = "session.stopped"
    static let sessionNotification = "session.notification"

    /// Every kind FlowStore consumes — subscription filter + replay set.
    static let flowKinds: [String] = [
        agentStarted, agentStopped, taskCreated,
        taskCompleted, sessionStopped, sessionNotification,
    ]

    /// Pre-hop Combine predicate. MUST be passed by function reference
    /// (`.filter(SignalKind.isFlowSignal)`) — a closure literal formed in
    /// a @MainActor context is MainActor-isolated under Swift 6 even when
    /// it touches nothing isolated, and Combine invokes filters
    /// synchronously on the upstream queue (this exact shape trapped at
    /// runtime in Group 2). A nonisolated named function has no isolation
    /// to violate.
    nonisolated static func isFlowSignal(_ signal: Signal) -> Bool {
        flowKinds.contains(signal.kind)
    }
}

/// Type-erased JSON value used for `payload`. Lets us round-trip
/// arbitrary upstream shapes without committing to a schema, while
/// still being Codable for storage and API exposure.
indirect enum SignalPayload: Hashable, Sendable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([SignalPayload])
    case object([String: SignalPayload])

    /// Convenience for the common terminal-line case: a single
    /// `{ "text": "<line>", "stream": "stdout" }` shape.
    static func terminalLine(_ text: String, stream: String) -> SignalPayload {
        .object([
            "text": .string(text),
            "stream": .string(stream),
        ])
    }
}

extension SignalPayload: Codable {
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let i = try? c.decode(Int64.self) { self = .int(i); return }
        if let d = try? c.decode(Double.self) { self = .double(d); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let a = try? c.decode([SignalPayload].self) { self = .array(a); return }
        if let o = try? c.decode([String: SignalPayload].self) { self = .object(o); return }
        throw DecodingError.dataCorruptedError(
            in: c,
            debugDescription: "SignalPayload: unrecognized JSON value"
        )
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .int(let i): try c.encode(i)
        case .double(let d): try c.encode(d)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
}

extension SignalPayload {
    /// Convert a JSONSerialization result (`Any` with NSNumber /
    /// NSString / NSNull / NSArray / NSDictionary) into the typed
    /// `SignalPayload` graph. Useful for ingesting arbitrary JSON
    /// from upstream APIs.
    static func from(json: Any) -> SignalPayload {
        if json is NSNull { return .null }
        if let s = json as? String { return .string(s) }
        if let b = json as? Bool, type(of: json) == type(of: NSNumber(value: true)) {
            // Disambiguate `Bool` from `NSNumber(0/1)` by checking the
            // underlying objc type — NSJSONSerialization returns
            // booleans as `__NSCFBoolean`. Fallback below covers
            // pure-Swift Bool values too.
            return .bool(b)
        }
        if let n = json as? NSNumber {
            // `__NSCFBoolean` is an NSNumber subclass; check explicitly.
            let typeID = CFGetTypeID(n)
            if typeID == CFBooleanGetTypeID() {
                return .bool(n.boolValue)
            }
            // Integer if the number has no fractional component.
            if CFNumberIsFloatType(n) {
                return .double(n.doubleValue)
            }
            return .int(n.int64Value)
        }
        if let arr = json as? [Any] {
            return .array(arr.map { SignalPayload.from(json: $0) })
        }
        if let dict = json as? [String: Any] {
            var out: [String: SignalPayload] = [:]
            for (k, v) in dict { out[k] = SignalPayload.from(json: v) }
            return .object(out)
        }
        return .null
    }
}
