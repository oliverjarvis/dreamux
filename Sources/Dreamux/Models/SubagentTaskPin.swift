import Foundation

/// Best-effort match of a live subagent to the plan task it's working.
/// Conservative by design: it pins ONLY when the subagent's text names a
/// task by number (`Task 3`, `Task 0.2`) and exactly one plan task carries
/// that number. No token, no numbered match, or an ambiguous number → nil,
/// so the checklist never badges the wrong row.
enum SubagentTaskPin {
    static func line(forAgentText text: String, tasks: [PlanTask]) -> Int? {
        guard let wanted = firstTaskNumber(in: text) else { return nil }
        let matches = tasks.filter { taskNumber(of: $0.title) == wanted }
        guard matches.count == 1 else { return nil }
        return matches.first?.line
    }

    /// The first `Task <n>[.<m>…]` number mentioned in free text (whole-word
    /// `task`, so `subtask 3` never matches), normalized.
    private static func firstTaskNumber(in text: String) -> String? {
        guard let range = text.range(
            of: #"(?i)\btask\s+\d+(?:\.\d+)*"#, options: .regularExpression)
        else { return nil }
        return normalize(String(text[range]))
    }

    /// The `Task N[.M…]` number a task title declares (anchored at the
    /// start), normalized, or nil.
    private static func taskNumber(of title: String) -> String? {
        guard let range = title.range(
            of: #"(?i)^task\s+\d+(?:\.\d+)*"#, options: .regularExpression)
        else { return nil }
        return normalize(String(title[range]))
    }

    /// `"Task 03"` / `"task  3"` → `"3"`; `"Task 0.2"` → `"0.2"`. Strips the
    /// word and collapses each numeric segment (drops leading zeros) so a
    /// mention and a title compare equal regardless of spacing/padding.
    private static func normalize(_ token: String) -> String {
        token
            .replacingOccurrences(of: #"(?i)^task\s+"#, with: "", options: .regularExpression)
            .split(separator: ".")
            .map { String(Int($0) ?? 0) }
            .joined(separator: ".")
    }
}
