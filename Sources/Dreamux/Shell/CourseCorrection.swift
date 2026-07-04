import Foundation

/// Writes a tracked *fix-task* into a plan file when the user files a
/// course correction (spec: "Phase 2 — course correction"). A completed-
/// looking task turns out wrong while the agent is phases ahead; rather
/// than typing untracked prose into the terminal, the correction becomes
/// a real task under the anchor phase — `### Task N.k: Fix — <summary>
/// *(course correction, <date>)*` with a single checkbox step — so it
/// renders in the expansion, counts in progress, and the whole-branch
/// review covers it.
///
/// The positioning logic is pure over its inputs (`insertion` takes a
/// parsed `PlanDoc`, the exact `contents` it was parsed from, and a
/// caller-supplied `date` — never `Date.now`), so the insertion point and
/// numbering are unit-testable without touching disk. `apply` is the thin
/// `@MainActor` I/O wrapper: it reads, computes, splices, and writes
/// atomically, leaving the existing `DocStore` watcher to notice the
/// change.
enum CourseCorrection {
    /// Where the fix-task attaches. A task row supplies its heading line;
    /// a phase row supplies the phase name; the plan row (no natural
    /// anchor) supplies `.currentPhase`, which resolves to the phase
    /// holding the current task — the first task with an unchecked step.
    enum Anchor: Equatable {
        case task(line: Int)
        case phase(name: String)
        case currentPhase
    }

    /// The computed edit: the multi-line `text` block to splice in and the
    /// 1-based `line` it is inserted before (existing content at that line
    /// and below shifts down). `text` leads with a blank separator line so
    /// the fix-task never abuts the preceding content, and carries no
    /// trailing newline.
    struct Insertion: Equatable {
        let line: Int
        let text: String
    }

    /// Compute the fix-task insertion for `anchor` in `doc`. `contents`
    /// must be the exact text `doc` was parsed from — the insertion line is
    /// read off the same 1-based line coordinates, and the phase headings
    /// are re-scanned with the parser's fence discipline so a fenced code
    /// example at the end of a phase can never swallow the insertion.
    ///
    /// The number continues the anchor phase's scheme: a dotted plan
    /// (`Task 1.9`) yields the next minor within the phase (`Task 1.10`); an
    /// integer plan yields the document-wide max plus one (`Task 8`). Body
    /// text collapses to a single step title (v1 keeps one step).
    static func insertion(
        in doc: PlanDoc,
        contents: String,
        anchor: Anchor,
        summary: String,
        body: String,
        date: String
    ) -> Insertion {
        let lines = contents.components(separatedBy: .newlines)
        let phaseHeadings = realPhaseHeadings(lines)
        let resolved = resolveAnchor(anchor, doc: doc, phaseHeadings: phaseHeadings)

        let number = nextNumber(doc: doc, anchorPhase: resolved.phaseName)
        let line = insertionLine(
            lines: lines, phaseStart: resolved.phaseStart, phaseHeadings: phaseHeadings)

        let text = """

        ### Task \(number): Fix — \(collapse(summary)) *(course correction, \(date))*

        - [ ] **Step 1: \(collapse(body))**
        """
        return Insertion(line: line, text: text)
    }

    /// Read `fileURL`, splice the computed fix-task in at its line, and
    /// write the file back atomically. The `DocStore` file watcher picks up
    /// the change on its own — no manual refresh, and this never touches
    /// `DocStore`. `date` is injected so the write stays deterministic in
    /// tests.
    ///
    /// Known limitation: this is a read-modify-write of a file the
    /// running agent also whole-file-writes (checkbox ticks, and Monaco
    /// saves) — a write landing inside our few-ms window is clobbered,
    /// last writer wins. Accepted: the window is tiny, ticks are sparse,
    /// and a lost tick self-heals when the agent next saves. Callers on
    /// a RUNNING plan should still prefer applying while the feature's
    /// shells are quiescent when they're already waiting for quiescence
    /// to deliver the nudge.
    @MainActor
    static func apply(
        to fileURL: URL,
        anchor: Anchor,
        summary: String,
        body: String,
        date: String
    ) throws {
        let contents = try String(contentsOf: fileURL, encoding: .utf8)
        let doc = PlanDoc.parse(fileURL: fileURL, contents: contents)
        let edit = insertion(
            in: doc, contents: contents, anchor: anchor,
            summary: summary, body: body, date: date)

        var lines = contents.components(separatedBy: .newlines)
        let index = max(0, min(edit.line - 1, lines.count))
        lines.insert(contentsOf: edit.text.components(separatedBy: "\n"), at: index)
        try lines.joined(separator: "\n").write(to: fileURL, atomically: true, encoding: .utf8)
    }

    // MARK: - Anchor resolution

    /// The anchor phase's `## ` heading line (nil for an unsectioned plan
    /// or a pre-section task) and its name (nil likewise) — the two facts
    /// the numbering and the insertion point both need.
    private static func resolveAnchor(
        _ anchor: Anchor,
        doc: PlanDoc,
        phaseHeadings: [(line: Int, name: String)]
    ) -> (phaseStart: Int?, phaseName: String?) {
        switch anchor {
        case .task(let line):
            if let task = doc.tasks.first(where: { $0.line == line }) {
                return (task.phaseLine, task.phase)
            }
            return currentPhase(doc)
        case .phase(let name):
            if let heading = phaseHeadings.first(where: { $0.name == name }) {
                return (heading.line, name)
            }
            return (nil, nil)
        case .currentPhase:
            return currentPhase(doc)
        }
    }

    /// The phase holding the current task — the first task with an
    /// unchecked step. When every step is checked, the last task's phase
    /// keeps a late correction attaching at the end rather than nowhere.
    private static func currentPhase(_ doc: PlanDoc) -> (phaseStart: Int?, phaseName: String?) {
        if let task = doc.tasks.first(where: { $0.steps.contains { !$0.checked } }) {
            return (task.phaseLine, task.phase)
        }
        if let last = doc.tasks.last {
            return (last.phaseLine, last.phase)
        }
        return (nil, nil)
    }

    // MARK: - Numbering

    /// A parsed `Task <major>[.<minor>]` heading number. Deeper dotted
    /// levels (`Task 1.2.3`) collapse to their first two components — v1
    /// never mints below the minor.
    private struct TaskNumber { let major: Int; let minor: Int? }

    /// The next task number for a fix-task under `anchorPhase`. A dotted
    /// plan (any task carries a minor) continues the anchor phase's minor
    /// series — `major.(maxMinor + 1)` for the phase's dominant major; an
    /// integer plan takes the document-wide `max + 1`. A dotted plan whose
    /// anchor phase has no dotted task yet falls back to the doc's max
    /// major with a fresh `.1`.
    private static func nextNumber(doc: PlanDoc, anchorPhase: String?) -> String {
        let all = doc.tasks.compactMap { parseNumber($0.title) }
        let isDotted = all.contains { $0.minor != nil }

        guard isDotted else {
            let maxMajor = all.map(\.major).max() ?? 0
            return "\(maxMajor + 1)"
        }

        let phaseNumbers = doc.tasks
            .filter { $0.phase == anchorPhase }
            .compactMap { parseNumber($0.title) }
            .filter { $0.minor != nil }
        if let major = phaseNumbers.map(\.major).max() {
            let maxMinor = phaseNumbers.filter { $0.major == major }.compactMap(\.minor).max() ?? 0
            return "\(major).\(maxMinor + 1)"
        }
        let maxMajor = all.map(\.major).max() ?? 0
        return "\(maxMajor).1"
    }

    /// Parse the `Task <major>[.<minor>]` number off a task title, matching
    /// the parser's heading grammar (`Task N`, `Task N.M`, dotted deeper).
    /// A fix-task title (`Task 8: Fix — …`) parses as `Task 8` like any
    /// other, so re-running numbering after a correction still counts it.
    private static func parseNumber(_ title: String) -> TaskNumber? {
        guard let range = title.range(
            of: #"^Task\s+(\d+)(?:\.(\d+))*"#, options: .regularExpression)
        else { return nil }
        let head = title[range]
        let digits = head
            .replacingOccurrences(of: #"^Task\s+"#, with: "", options: .regularExpression)
            .split(separator: ".")
            .compactMap { Int($0) }
        guard let major = digits.first else { return nil }
        return TaskNumber(major: major, minor: digits.count > 1 ? digits[1] : nil)
    }

    // MARK: - Insertion point

    /// The 1-based line the fix-task block is inserted before: the end of
    /// the anchor phase's content, i.e. the line after the phase's last
    /// non-blank line, which is also just before the next `## ` heading (or
    /// end of document for the last / an unsectioned phase). Computed off
    /// fence-aware `phaseHeadings`, so a fenced example ending a phase — its
    /// closing ``` is the phase's last content line — pushes the insertion
    /// safely past the fence.
    private static func insertionLine(
        lines: [String],
        phaseStart: Int?,
        phaseHeadings: [(line: Int, name: String)]
    ) -> Int {
        let lineCount = lines.count
        let windowStart: Int
        let windowEnd: Int   // exclusive, 1-based; == first `## ` past the phase, or lineCount+1
        if let phaseStart {
            windowStart = phaseStart + 1
            windowEnd = phaseHeadings.map(\.line).filter { $0 > phaseStart }.min() ?? (lineCount + 1)
        } else {
            // No anchor phase: an unsectioned plan spans the whole document,
            // but a task that precedes the first `## ` stops at that heading.
            windowStart = 1
            windowEnd = phaseHeadings.map(\.line).min() ?? (lineCount + 1)
        }

        // The insertion sits right after the phase's last non-blank line.
        // Scanning for blankness needs no fence awareness — every line in
        // the window belongs to the phase, fenced or not, and the fix-task
        // goes after all of it.
        var lastContent = windowStart - 1
        var i = min(windowEnd - 1, lineCount)
        while i >= windowStart {
            if !lines[i - 1].trimmingCharacters(in: .whitespaces).isEmpty {
                lastContent = i
                break
            }
            i -= 1
        }
        // An empty phase (no content between headings) anchors at its own
        // heading line so the fix-task still lands inside the phase.
        return max(lastContent + 1, windowStart)
    }

    // MARK: - Summary derivation

    /// Derive the fix-task's one-line heading summary from the user's typed
    /// observation: the first line with actual content, whitespace-collapsed
    /// and, if longer than `maxLength`, clipped with a trailing ellipsis. The
    /// full observation becomes the step body; this line becomes the
    /// `### Task N.k: Fix — <summary>` heading, so it must stay short and
    /// single-line. Skipping leading blank lines keeps a stray newline before
    /// the real text from yielding an empty heading (the sheet already
    /// disables submit on all-whitespace input, but this stays total).
    static func summaryLine(from observation: String, maxLength: Int = 60) -> String {
        let firstContentLine = observation
            .split(whereSeparator: \.isNewline)
            .lazy
            .map { collapse(String($0)) }
            .first { !$0.isEmpty } ?? ""
        guard firstContentLine.count > maxLength else { return firstContentLine }
        return firstContentLine.prefix(maxLength).trimmingCharacters(in: .whitespaces) + "…"
    }

    // MARK: - Helpers

    /// The 1-based lines of real `## ` headings (with their names), scanned
    /// with the parser's fence discipline so headings inside ``` examples
    /// are invisible — the guarantee the insertion point leans on.
    private static func realPhaseHeadings(_ lines: [String]) -> [(line: Int, name: String)] {
        var out: [(line: Int, name: String)] = []
        var insideFence = false
        for (index, line) in lines.enumerated() {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                insideFence.toggle()
                continue
            }
            if insideFence { continue }
            if line.hasPrefix("## ") {
                out.append((index + 1, String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)))
            }
        }
        return out
    }

    /// Collapse every run of whitespace (including newlines) to one space
    /// and trim — a multi-line observation becomes a single heading/step
    /// line the parser round-trips.
    private static func collapse(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}
