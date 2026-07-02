import Foundation

/// One markdown document under the project docs home, classified by
/// SHAPE (never by path): superpowers-style plans and specs are
/// recognized wherever they sit, and anything else stays a plain doc.
struct PlanDoc: Identifiable, Equatable {
    enum Kind: String, Sendable { case plan, spec, doc }

    var id: URL { fileURL }
    let fileURL: URL
    let kind: Kind
    /// First `# ` heading, else the filename stem without date prefix.
    let title: String
    /// `YYYY-MM-DD` filename prefix when present.
    let date: String?
    /// The plan header's `**Goal:**` line, when present.
    let goal: String?
    /// The raw path from the plan header's `**Spec:**` line (backticks
    /// and trailing prose stripped), unresolved.
    let specReference: String?
    let checkedSteps: Int
    let totalSteps: Int

    static func parse(fileURL: URL, contents: String) -> PlanDoc {
        let lines = contents.components(separatedBy: .newlines)

        var firstH1: String?
        var goal: String?
        var specReference: String?
        var hasTaskHeading = false
        var checked = 0, total = 0

        for line in lines {
            if firstH1 == nil, line.hasPrefix("# ") {
                firstH1 = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            }
            if goal == nil, let value = headerValue(line, field: "Goal") {
                goal = value
            }
            if specReference == nil, let value = headerValue(line, field: "Spec") {
                specReference = stripDecoration(value)
            }
            if line.range(of: #"^###\s+Task\s+\d+:"#, options: .regularExpression) != nil {
                hasTaskHeading = true
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("- [ ]") { total += 1 }
            else if trimmed.hasPrefix("- [x]") || trimmed.hasPrefix("- [X]") {
                total += 1; checked += 1
            }
        }

        let stem = fileURL.deletingPathExtension().lastPathComponent
        let date = datePrefix(of: stem)
        let kind: Kind
        if firstH1?.hasSuffix("Implementation Plan") == true || (hasTaskHeading && total > 0) {
            kind = .plan
        } else if stem.hasSuffix("-design") {
            kind = .spec
        } else {
            kind = .doc
        }

        return PlanDoc(
            fileURL: fileURL,
            kind: kind,
            title: firstH1 ?? stripDatePrefix(from: stem),
            date: date,
            goal: goal,
            specReference: specReference,
            checkedSteps: checked,
            totalSteps: total
        )
    }

    /// `2026-07-02-universal-file-viewers.md` → `universal-file-viewers`;
    /// a `-design` suffix is dropped too so a spec derives the same
    /// branch as its plan.
    static func branchName(forFileName name: String) -> String {
        var stem = (name as NSString).deletingPathExtension
        stem = stripDatePrefix(from: stem)
        if stem.hasSuffix("-design") { stem = String(stem.dropLast("-design".count)) }
        return stem
    }

    // MARK: - Helpers

    /// `**Field:** value` → `value` (nil when the line isn't that field).
    private static func headerValue(_ line: String, field: String) -> String? {
        let prefix = "**\(field):**"
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix(prefix) else { return nil }
        return String(trimmed.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
    }

    /// Strip surrounding backticks and any ` — trailing prose`.
    private static func stripDecoration(_ value: String) -> String {
        var v = value
        if let dash = v.range(of: " — ") { v = String(v[..<dash.lowerBound]) }
        v = v.trimmingCharacters(in: .whitespaces)
        v = v.trimmingCharacters(in: CharacterSet(charactersIn: "`"))
        return v
    }

    private static func datePrefix(of stem: String) -> String? {
        guard let range = stem.range(of: #"^\d{4}-\d{2}-\d{2}-"#, options: .regularExpression)
        else { return nil }
        return String(stem[range].dropLast())
    }

    private static func stripDatePrefix(from stem: String) -> String {
        guard let range = stem.range(of: #"^\d{4}-\d{2}-\d{2}-"#, options: .regularExpression)
        else { return stem }
        return String(stem[range.upperBound...])
    }
}
