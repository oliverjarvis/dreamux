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
/// completions. All thresholds are the spec's contract values.
enum LoopDetector {
    static let windowSize = 12

    /// Bash commands loop by their leading token ("Bash:swift"); every
    /// other tool loops by name alone — file paths vary per iteration,
    /// commands don't.
    static func signature(tool: String, summary: String?) -> String {
        guard tool == "Bash",
              let first = summary?.split(whereSeparator: \.isWhitespace).first,
              !first.isEmpty
        else { return tool }
        return "Bash:\(first)"
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
        let qualifying = counts.filter { $0.value.total >= 3 && $0.value.errors >= 2 && $0.value.lastIsError }
        guard let winner = qualifying.max(by: { lhs, rhs in
            if lhs.value.total != rhs.value.total { return lhs.value.total < rhs.value.total }
            return lhs.value.lastIndex < rhs.value.lastIndex
        }) else { return nil }
        return DetectedLoop(signature: winner.key, count: winner.value.total)
    }
}
