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
    case projects, workspaces, commands, files

    var id: String { rawValue }

    var title: String {
        switch self {
        case .projects: "Projects"
        case .workspaces: "Workspaces & Plans"
        case .commands: "Commands"
        case .files: "Files"
        }
    }
}

/// A section's candidate feed. `candidates` is pulled fresh on every
/// `refresh()` (each palette open) so results reflect the live stores.
/// Sections with `showsOnEmptyQuery == false` (files, workspaces)
/// contribute rows only once the user types.
struct PaletteSource {
    let kind: PaletteSectionKind
    let cap: Int
    let showsOnEmptyQuery: Bool
    let candidates: @MainActor () -> [PaletteCandidate]
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

    /// Re-pull every source's candidates — called once per palette open.
    func refresh() {
        snapshot = [:]
        for source in sources {
            snapshot[source.kind] = source.candidates()
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
