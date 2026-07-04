import Foundation

/// A `### Task N:` heading and the checkbox steps beneath it. The title
/// is the full heading text (e.g. `Task 1: File-kind classifier`); the
/// synthetic bucket for checkboxes that precede any heading carries an
/// empty title. `phase` is the `## ` section the task falls under
/// (`Phase 1 — Core mechanic`), nil when the plan has no H2 sections —
/// single-file phased plans group their expansion rows by it.
/// `line`/`phaseLine` are 1-based document lines of the task's heading
/// and its section's `## ` heading — the sidebar's jump-to-section
/// targets. The synthetic bucket's `line` is its first checkbox's line.
struct PlanTask: Equatable {
    let title: String
    let steps: [PlanStep]
    let phase: String?
    let line: Int
    let phaseLine: Int?

    init(
        title: String,
        steps: [PlanStep],
        phase: String? = nil,
        line: Int = 1,
        phaseLine: Int? = nil
    ) {
        self.title = title
        self.steps = steps
        self.phase = phase
        self.line = line
        self.phaseLine = phaseLine
    }
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
        var tasks: [(title: String, phase: String?, line: Int, phaseLine: Int?, steps: [PlanStep])] = []
        // The `## ` section the parser is currently inside — recorded on
        // each task so single-file phased plans can group by it, along
        // with the heading's 1-based line for jump-to-section.
        var currentPhase: String?
        var currentPhaseLine: Int?
        func appendStep(_ step: PlanStep, at lineNumber: Int) {
            if tasks.isEmpty {
                // Checkboxes before any heading go in a synthetic untitled
                // bucket, created only when such steps actually exist.
                tasks.append((title: "", phase: currentPhase, line: lineNumber,
                              phaseLine: currentPhaseLine, steps: [step]))
            } else {
                tasks[tasks.count - 1].steps.append(step)
            }
        }

        // Fenced code blocks routinely contain lines that LOOK like
        // headings or checkboxes (```md examples, `## ` comments in
        // ```bash) — matching them would miscount steps or stamp phantom
        // phases. Track the fence state and skip everything inside.
        var insideFence = false

        for (index, line) in lines.enumerated() {
            let lineNumber = index + 1
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                insideFence.toggle()
                continue
            }
            if insideFence { continue }

            if firstH1 == nil, line.hasPrefix("# ") {
                firstH1 = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            }
            if goal == nil, let value = headerValue(line, field: "Goal") {
                goal = value
            }
            if specReference == nil, let value = headerValue(line, field: "Spec") {
                specReference = specPathToken(value)
            }

            if line.hasPrefix("### ") {
                let heading = String(line.dropFirst(4)).trimmingCharacters(in: .whitespaces)
                // Dotted numbering (`Task 0.1:`) is what phased
                // single-file plans produce — accept any depth.
                if heading.range(of: #"^Task\s+\d+(?:\.\d+)*\s*[:—]"#, options: .regularExpression) != nil {
                    hasTaskHeading = true
                    tasks.append((title: heading, phase: currentPhase, line: lineNumber,
                                  phaseLine: currentPhaseLine, steps: []))
                } else if hasTaskHeading {
                    // A bare `### …` heading opens a task only once we're
                    // past the first Task heading (later phases sometimes
                    // drop the `Task N:` prefix).
                    tasks.append((title: heading, phase: currentPhase, line: lineNumber,
                                  phaseLine: currentPhaseLine, steps: []))
                }
                continue
            }

            if line.hasPrefix("## ") {
                // H2 opens a section; tasks record the one they fall
                // under. Generic sections (Global Constraints, …) carry
                // no tasks, so they never surface as phases.
                currentPhase = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                currentPhaseLine = lineNumber
                continue
            }

            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let isChecked = checkboxState(trimmed) {
                total += 1
                if isChecked { checked += 1 }
                appendStep(PlanStep(title: stepTitle(from: trimmed), checked: isChecked),
                           at: lineNumber)
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
            tasks: tasks.map {
                PlanTask(title: $0.title, steps: $0.steps, phase: $0.phase,
                         line: $0.line, phaseLine: $0.phaseLine)
            }
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

    /// A `**Spec:**` value is a path plus optional prose or qualifiers
    /// (`docs/x-design.md — read it first`, `docs/x-design.md (§6 Queue)`,
    /// `docs/x-design.md (section "…")`). Resolving the whole string as a
    /// path silently breaks backlink pairing, so take the first token
    /// ending in `.md`; fall back to the decoration-stripped value for
    /// references that aren't markdown paths.
    private static func specPathToken(_ value: String) -> String {
        let stripped = stripDecoration(value)
        if let range = stripped.range(of: #"\S+\.md\b"#, options: .regularExpression) {
            return String(stripped[range])
        }
        return stripped
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
