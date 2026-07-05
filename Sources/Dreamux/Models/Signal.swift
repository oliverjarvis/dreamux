import Foundation
import Observation
import SwiftUI

/// Coarse severity bucket we infer from a log line. Lines without a
/// recognisable level (the vast majority) fall into `.info`. We deliberately
/// keep this small — adding more levels means more chips in the filter bar.
enum SignalLevel: String, CaseIterable, Identifiable, Hashable, Sendable {
    case debug, info, warn, error

    var id: String { rawValue }

    var label: String {
        switch self {
        case .debug: return "DEBUG"
        case .info: return "INFO"
        case .warn: return "WARN"
        case .error: return "ERROR"
        }
    }

    var tint: Color {
        switch self {
        case .debug: return .gray
        case .info: return .blue
        case .warn: return .orange
        case .error: return .red
        }
    }
}

/// One observed log line. `id` is a monotonically-increasing counter from
/// the store, not a UUID — it gives a deterministic order even when two
/// lines share the same timestamp (which happens when a burst of output
/// arrives in the same `readabilityHandler` callback).
struct SignalEntry: Identifiable, Hashable, Sendable {
    let id: UInt64
    let timestamp: Date
    let source: String
    let level: SignalLevel
    let message: String
}

/// Bounded ring of signal entries. Backed by a plain array because the
/// SwiftUI list needs index-based access; we trim from the front when the
/// cap is exceeded.
@MainActor
@Observable
final class SignalStore {
    /// Most recent entries last. The cap keeps memory in check for
    /// services that emit thousands of lines per second.
    private(set) var entries: [SignalEntry] = []
    let cap: Int = 10_000

    private var nextID: UInt64 = 0

    /// Sources we've ever seen, in first-appearance order. Drives the
    /// source-filter chip list — sticking around even after a runner
    /// stops so the user can still scroll their old logs.
    private(set) var knownSources: [String] = []
    private var knownSourcesSet: Set<String> = []

    /// A runner name the Signals page should focus its source filter
    /// on the next time it appears — parked by the header's services
    /// popover ("logs"), consumed and cleared by SignalsView.onAppear.
    /// The `RunnerManager.pendingIsolation` pattern again.
    var pendingSourceFocus: String?

    /// Sources belonging to one runner: the bare name plus any
    /// `name:branch` variants (see RunnerManager.signalSource). Falls
    /// back to the bare name when nothing matches yet, so focusing
    /// before the first log line still yields a filter that lights up
    /// once lines arrive.
    static func sourcesMatching(focus: String, in sources: [String]) -> Set<String> {
        let hits = sources.filter { $0 == focus || $0.hasPrefix("\(focus):") }
        return hits.isEmpty ? [focus] : Set(hits)
    }

    func append(source: String, line: String, at timestamp: Date = .now) {
        let level = Self.detectLevel(in: line)
        let entry = SignalEntry(
            id: nextID,
            timestamp: timestamp,
            source: source,
            level: level,
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
    }

    /// Buffer raw chunks, only flush complete lines. Stdout/stderr arrives
    /// in arbitrary-sized blobs; we want one entry per line.
    func appendChunk(source: String, _ chunk: String, buffer: inout String) {
        buffer.append(chunk)
        while let newline = buffer.firstIndex(of: "\n") {
            let raw = String(buffer[..<newline])
            buffer.removeSubrange(buffer.startIndex...newline)
            let trimmed = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            if trimmed.isEmpty { continue }
            append(source: source, line: trimmed)
        }
    }

    func clear() {
        entries.removeAll(keepingCapacity: true)
    }

    /// Most-recent entries for a given source, oldest-first. Used by the
    /// Run pane to show a small failure tail directly on a runner row
    /// and to feed Claude when the user clicks Diagnose.
    func recentEntries(forSource source: String, limit: Int) -> [SignalEntry] {
        var results: [SignalEntry] = []
        for entry in entries.reversed() where entry.source == source {
            results.append(entry)
            if results.count >= limit { break }
        }
        return results.reversed()
    }

    /// Heuristic level detection. Looks for the level token at the start
    /// of the line or in square brackets, in either case-insensitive form.
    /// Anything we can't classify gets `.info` — better than dropping the
    /// line into a "unknown" bucket the user has to remember to keep
    /// enabled.
    private static func detectLevel(in line: String) -> SignalLevel {
        let lower = line.lowercased()
        // Drop ANSI color escapes for matching only — we keep the raw
        // line in `message` so colour codes still render if we later
        // support styled output.
        let cleaned = lower.replacingOccurrences(
            of: #"\u{1B}\[[0-9;]*[A-Za-z]"#,
            with: "",
            options: .regularExpression
        )
        // Order matters — `error` first so "errored" doesn't match `warn`.
        if Self.contains(cleaned, anyOf: ["error", "err ", "fatal", "panic", "exception"]) { return .error }
        if Self.contains(cleaned, anyOf: ["warn", "warning"]) { return .warn }
        if Self.contains(cleaned, anyOf: ["debug", "trace"]) { return .debug }
        return .info
    }

    private static func contains(_ haystack: String, anyOf needles: [String]) -> Bool {
        needles.contains { haystack.contains($0) }
    }
}
