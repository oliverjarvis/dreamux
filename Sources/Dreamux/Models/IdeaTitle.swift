import Foundation

/// Tab titles for intake (idea-routing) sessions. Pure and testable: every
/// fired idea gets its OWN tab now, so ten concurrent routers must not all
/// read "planning" — the title has to say which conversation it is.
enum IdeaTitle {
    /// Characters of the idea itself the chip can carry before the tab
    /// strip starts scrolling. Deliberately generous-but-short: the chip is
    /// a label, not a summary.
    static let maxBodyLength = 24

    /// `idea: <first non-empty line, collapsed, clipped>` — or the bare
    /// word `idea` when there is nothing to say.
    static func tabTitle(for idea: String) -> String {
        let firstLine = idea
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first(where: { !$0.isEmpty }) ?? ""
        let collapsed = firstLine
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        guard !collapsed.isEmpty else { return "idea" }
        return "idea: \(clip(collapsed))"
    }

    /// Clip to `maxBodyLength` on a word boundary, marking the cut with an
    /// ellipsis. A single word longer than the budget has no boundary to
    /// fall back to, so it is cut hard.
    private static func clip(_ text: String) -> String {
        guard text.count > maxBodyLength else { return text }
        let budget = String(text.prefix(maxBodyLength))
        if let lastSpace = budget.lastIndex(of: " ") {
            let onBoundary = String(budget[..<lastSpace])
            if !onBoundary.isEmpty { return onBoundary + "…" }
        }
        return budget + "…"
    }
}
