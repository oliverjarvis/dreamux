import Foundation

/// One finished tool call, reduced to what the loop heuristic needs.
struct ToolCompletion: Equatable, Sendable {
    let signature: String
    let isError: Bool
    let at: Date?
}

/// A detected repetition worth surfacing. A badge, never a judgment —
/// the UI must not claim the loop is stuck (spec).
struct DetectedLoop: Equatable, Sendable {
    let signature: String
    let count: Int
}

/// Conservative repetition heuristic over a lane's recent tool
/// completions. Real-world data (210 transcripts, 39 badge appearances)
/// showed that tool-name-wide signatures (Edit, Read, etc.) produce
/// 22 false positives at ≥2 errors — 11-element windows with 9 successes
/// are common churn, not stuck loops. Bash command-specific signatures
/// ("Bash:swift", "Bash:npm") stay stricter: measured 5 plausible detections
/// vs 0 false at floor 3, but the floor 2 semantic holds for true Bash loops.
/// This heuristic applies floor 2 to Bash/* only; all other tools require ≥3.
enum LoopDetector {
    static let windowSize = 12

    /// Bash commands loop by their leading token ("Bash:swift"); a
    /// path-invoked command normalizes to its basename instead
    /// ("Bash:foo" for "/Users/x/bin/foo …" or "~/bin/foo …") so a
    /// signature never leaks a full path into a print or UI surface.
    /// Every other tool loops by name alone — file paths vary per
    /// iteration, commands don't.
    static func signature(tool: String, summary: String?) -> String {
        guard tool == "Bash",
              let first = summary?.split(whereSeparator: \.isWhitespace).first,
              !first.isEmpty
        else { return tool }
        let token = String(first)
        guard token.contains("/") || token.hasPrefix("~") else { return "Bash:\(token)" }
        return "Bash:\((token as NSString).lastPathComponent)"
    }

    static func detect(window: [ToolCompletion]) -> DetectedLoop? {
        guard !window.isEmpty else { return nil }
        var counts: [String: (total: Int, errors: Int, lastIndex: Int, lastIsError: Bool)] = [:]
        for (index, completion) in window.enumerated() {
            var entry = counts[completion.signature] ?? (0, 0, 0, false)
            entry.total += 1
            if completion.isError { entry.errors += 1 }
            entry.lastIndex = index
            entry.lastIsError = completion.isError
            counts[completion.signature] = entry
        }
        let qualifying = counts.filter { signature, entry in
            let minErrors = signature == "Bash" || signature.hasPrefix("Bash:") ? 2 : 3
            return entry.total >= 3 && entry.errors >= minErrors && entry.lastIsError
        }
        guard let winner = qualifying.max(by: { lhs, rhs in
            if lhs.value.total != rhs.value.total { return lhs.value.total < rhs.value.total }
            return lhs.value.lastIndex < rhs.value.lastIndex
        }) else { return nil }
        return DetectedLoop(signature: winner.key, count: winner.value.total)
    }
}
