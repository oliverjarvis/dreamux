import Foundation
import Observation

/// One selectable palette row's identity + action. `perform` runs on the
/// main actor when the row is executed (Return or click); the view is
/// responsible for dismissing afterwards.
struct PaletteCandidate: Identifiable {
    let id: String
    let title: String
    let subtitle: String?
    /// SF Symbol name for the row's leading glyph.
    let icon: String
    let perform: @MainActor () -> Void
}

/// The palette's result groups, in display order.
enum PaletteSectionKind: String, CaseIterable, Identifiable {
    /// A typed URL or bare host. Leads the list: when the query IS an
    /// address, that is almost certainly what the user meant.
    case url
    case projects, workspaces, commands, files

    var id: String { rawValue }

    var title: String {
        switch self {
        case .url: "Open URL"
        case .projects: "Projects"
        case .workspaces: "Workspaces & Plans"
        case .commands: "Commands"
        case .files: "Files"
        }
    }
}

/// A section's candidate feed. Ordinary sources are pulled fresh on every
/// `refresh()` (each palette open) so results reflect the live stores, and
/// then fuzzy-filtered by the query. Sections with
/// `showsOnEmptyQuery == false` (files, workspaces) contribute rows only
/// once the user types.
struct PaletteSource {
    let kind: PaletteSectionKind
    let cap: Int
    let showsOnEmptyQuery: Bool
    /// True when this source's candidates ARE a function of the live query
    /// (the URL source). Such a source can't be snapshotted at `refresh()`:
    /// it is re-pulled on every keystroke, and its rows are taken verbatim
    /// rather than fuzzy-filtered — it already decided what this query
    /// yields, and re-scoring "Open github.com" against "github.com" would
    /// only be able to reject it.
    let dependsOnQuery: Bool
    /// Receives the current query; snapshot sources ignore it.
    let candidates: @MainActor (String) -> [PaletteCandidate]

    init(
        kind: PaletteSectionKind,
        cap: Int,
        showsOnEmptyQuery: Bool,
        dependsOnQuery: Bool = false,
        candidates: @escaping @MainActor (String) -> [PaletteCandidate]
    ) {
        self.kind = kind
        self.cap = cap
        self.showsOnEmptyQuery = showsOnEmptyQuery
        self.dependsOnQuery = dependsOnQuery
        self.candidates = candidates
    }
}

struct PaletteRow: Identifiable {
    let candidate: PaletteCandidate
    let match: FuzzyMatch
    var id: String { candidate.id }
}

struct PaletteResultSection: Identifiable {
    let kind: PaletteSectionKind
    let rows: [PaletteRow]
    var id: String { kind.id }
}

/// Query + selection + result composition for the ⌘K palette. Pure data —
/// no view dependencies — so it's unit-testable with fake sources.
@MainActor
@Observable
final class PaletteModel {
    var query: String = "" {
        didSet {
            guard query != oldValue else { return }
            rebuild()
        }
    }
    private(set) var sections: [PaletteResultSection] = []
    private(set) var selectedRowID: String?

    private let sources: [PaletteSource]
    private var snapshot: [PaletteSectionKind: [PaletteCandidate]] = [:]

    init(sources: [PaletteSource]) {
        self.sources = sources
    }

    /// Re-pull every snapshot source's candidates — called once per palette
    /// open. Query-dependent sources are skipped here; `rebuild` pulls them.
    func refresh() {
        snapshot = [:]
        for source in sources where !source.dependsOnQuery {
            snapshot[source.kind] = source.candidates("")
        }
        rebuild()
    }

    var flatRows: [PaletteRow] { sections.flatMap(\.rows) }

    var selectedRow: PaletteRow? {
        flatRows.first { $0.id == selectedRowID }
    }

    func select(_ rowID: String) {
        selectedRowID = rowID
    }

    /// Clamped linear movement across all sections' rows.
    func moveSelection(by delta: Int) {
        let flat = flatRows
        guard !flat.isEmpty else { return }
        let current = flat.firstIndex { $0.id == selectedRowID } ?? 0
        let next = min(max(current + delta, 0), flat.count - 1)
        selectedRowID = flat[next].id
    }

    /// Runs the selected row's action. Returns false when nothing is
    /// selectable (caller keeps the palette open).
    @discardableResult
    func executeSelected() -> Bool {
        guard let row = selectedRow else { return false }
        row.candidate.perform()
        return true
    }

    private func rebuild() {
        sections = sources.compactMap { source in
            if source.dependsOnQuery {
                guard !query.isEmpty else { return nil }
                let rows = source.candidates(query).prefix(source.cap).map {
                    PaletteRow(candidate: $0, match: FuzzyMatch(score: 0, matchedOffsets: []))
                }
                return rows.isEmpty
                    ? nil
                    : PaletteResultSection(kind: source.kind, rows: Array(rows))
            }
            let candidates = snapshot[source.kind] ?? []
            let rows: [PaletteRow]
            if query.isEmpty {
                guard source.showsOnEmptyQuery else { return nil }
                rows = candidates.prefix(source.cap).map {
                    PaletteRow(candidate: $0, match: FuzzyMatch(score: 0, matchedOffsets: []))
                }
            } else {
                // Sort by (score desc, original index) — Swift's sort is
                // not guaranteed stable, so carry the index explicitly.
                rows = candidates.enumerated()
                    .compactMap { index, candidate -> (Int, PaletteRow)? in
                        guard let match = FuzzyMatcher.match(query, in: candidate.title) else {
                            return nil
                        }
                        return (index, PaletteRow(candidate: candidate, match: match))
                    }
                    .sorted { a, b in
                        if a.1.match.score != b.1.match.score {
                            return a.1.match.score > b.1.match.score
                        }
                        return a.0 < b.0
                    }
                    .prefix(source.cap)
                    .map(\.1)
            }
            return rows.isEmpty ? nil : PaletteResultSection(kind: source.kind, rows: rows)
        }
        let flat = flatRows
        if !flat.contains(where: { $0.id == selectedRowID }) {
            selectedRowID = flat.first?.id
        }
    }
}
