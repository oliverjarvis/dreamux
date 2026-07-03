import Foundation

/// A `### Task N:` heading and the checkbox steps beneath it. The title
/// is the full heading text (e.g. `Task 1: File-kind classifier`); the
/// synthetic bucket for checkboxes that precede any heading carries an
/// empty title.
struct PlanTask: Equatable {
    let title: String
    let steps: [PlanStep]
}

/// One `- [ ]` / `- [x]` checkbox line, with the readable title left
/// after stripping the `**Step k: …**` decoration.
struct PlanStep: Equatable {
    let title: String
    let checked: Bool
}

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
    /// Tasks in document order (`### Task N:` headings), each carrying
    /// its checkbox steps. `checkedSteps`/`totalSteps` above stay the
    /// authoritative totals — they are exactly the sums over these steps.
    let tasks: [PlanTask]

    static func parse(fileURL: URL, contents: String) -> PlanDoc {
        let lines = contents.components(separatedBy: .newlines)

        var firstH1: String?
        var goal: String?
        var specReference: String?
        var hasTaskHeading = false
        var checked = 0, total = 0

        // Tasks accumulate in the same pass. Each checkbox that bumps the
        // counters above also appends a step here, so the totals and the
        // per-task sums can never drift.
        var tasks: [(title: String, steps: [PlanStep])] = []
        func appendStep(_ step: PlanStep) {
            if tasks.isEmpty {
                // Checkboxes before any heading go in a synthetic untitled
                // bucket, created only when such steps actually exist.
                tasks.append((title: "", steps: [step]))
            } else {
                tasks[tasks.count - 1].steps.append(step)
            }
        }

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

            if line.hasPrefix("### ") {
                let heading = String(line.dropFirst(4)).trimmingCharacters(in: .whitespaces)
                if heading.range(of: #"^Task\s+\d+\s*[:—]"#, options: .regularExpression) != nil {
                    hasTaskHeading = true
                    tasks.append((title: heading, steps: []))
                } else if hasTaskHeading {
                    // A bare `### …` heading opens a task only once we're
                    // past the first Task heading (later phases sometimes
                    // drop the `Task N:` prefix).
                    tasks.append((title: heading, steps: []))
                }
                continue
            }

            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let isChecked = checkboxState(trimmed) {
                total += 1
                if isChecked { checked += 1 }
                appendStep(PlanStep(title: stepTitle(from: trimmed), checked: isChecked))
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
            totalSteps: total,
            tasks: tasks.map { PlanTask(title: $0.title, steps: $0.steps) }
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

    /// The slug that binds a spec, its phase plans, and their roadmap into
    /// one initiative family: the branch stem (date prefix and a trailing
    /// `-design`/`-roadmap`/`-plan` removed) with any `phase-N`/`part-N`
    /// segment dropped. `2026-07-02-gameboy-phase-1.md` → `gameboy`;
    /// `x-design.md` → `x`. A trailing `-N` that is not a phase marker
    /// stays put, so `x-design-2.md` → `x-design-2`, never family `x`.
    static func familyKey(forFileName name: String) -> String {
        var stem = stripDatePrefix(from: (name as NSString).deletingPathExtension)
        for suffix in ["-design", "-roadmap", "-plan"] where stem.hasSuffix(suffix) {
            stem = String(stem.dropLast(suffix.count))
            break
        }
        stem = stem.replacingOccurrences(
            of: #"(?i)-?\b(?:phase|part)-\d+"#, with: "", options: .regularExpression)
        stem = stem.replacingOccurrences(of: #"-{2,}"#, with: "-", options: .regularExpression)
        return stem.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    // MARK: - Helpers

    /// Checkbox state of a trimmed line: `true`/`false` for a checked or
    /// unchecked `- [ ]` item, `nil` when it isn't a checkbox. Shared by
    /// the totals counters and the step parse so they stay in lockstep.
    private static func checkboxState(_ trimmed: String) -> Bool? {
        if trimmed.hasPrefix("- [ ]") { return false }
        if trimmed.hasPrefix("- [x]") || trimmed.hasPrefix("- [X]") { return true }
        return nil
    }

    /// Readable step title: drop the `- [ ]` marker, a leading
    /// `**Step k:` numbering label, and any remaining `**` bold markers.
    /// `**Step 1: Model.** In …` → `Model. In …`; `plain item` → `plain item`.
    private static func stepTitle(from trimmed: String) -> String {
        var body = String(trimmed.dropFirst("- [ ]".count)).trimmingCharacters(in: .whitespaces)
        if let label = body.range(of: #"^\*\*Step\s+\d+\s*[:—]\s*"#, options: .regularExpression) {
            body.removeSubrange(label)
        }
        body = body.replacingOccurrences(of: "**", with: "")
        return body.trimmingCharacters(in: .whitespaces)
    }

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
