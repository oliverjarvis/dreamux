import Foundation

/// Result of a fuzzy match: a rank score plus the character offsets in
/// the target that matched, so views can bold the hit characters.
struct FuzzyMatch: Equatable {
    /// Higher is better. Comparable only between matches of the SAME query.
    let score: Int
    /// Character offsets into the target string, ascending.
    let matchedOffsets: [Int]
}

/// Case-insensitive greedy subsequence matcher shared by every palette
/// provider. Scoring favors prefix matches, matches at word/segment
/// boundaries (space, -, _, /, ., camelCase humps), and consecutive
/// runs; shorter targets win ties.
enum FuzzyMatcher {
    static func match(_ query: String, in target: String) -> FuzzyMatch? {
        if query.isEmpty { return FuzzyMatch(score: 0, matchedOffsets: []) }
        let queryChars = Array(query.lowercased())
        let targetChars = Array(target)
        let lowerTarget = Array(target.lowercased())
        guard queryChars.count <= targetChars.count else { return nil }

        var offsets: [Int] = []
        var score = 0
        var queryIndex = 0
        var previousMatch = -2
        for targetIndex in 0..<lowerTarget.count {
            guard queryIndex < queryChars.count else { break }
            guard lowerTarget[targetIndex] == queryChars[queryIndex] else { continue }
            var charScore = 1
            if targetIndex == previousMatch + 1 { charScore += 4 }
            if targetIndex == 0 {
                charScore += 8
            } else if isBoundary(targetChars[targetIndex - 1], targetChars[targetIndex]) {
                charScore += 6
            }
            score += charScore
            offsets.append(targetIndex)
            previousMatch = targetIndex
            queryIndex += 1
        }
        guard queryIndex == queryChars.count else { return nil }
        // Length penalty: on equal hits, the shorter target ranks higher.
        score -= targetChars.count / 4
        return FuzzyMatch(score: score, matchedOffsets: offsets)
    }

    private static func isBoundary(_ previous: Character, _ current: Character) -> Bool {
        if " -_/.".contains(previous) { return true }
        return previous.isLowercase && current.isUppercase
    }
}
