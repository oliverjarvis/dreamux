import Foundation
import GhosttyTheme

/// The 485 themes bundled with `libghostty-spm`, mapped into our own
/// value type. They SEED the editor rather than locking it: pick one as
/// a starting point, then edit any swatch.
///
/// Imports `GhosttyTheme` (a plain value catalog) but never
/// `GhosttyTerminal` — the version-churny typed config API still has
/// exactly one caller, `TerminalThemeCompiler`.
enum TerminalThemePresets {
    static var count: Int { GhosttyThemeCatalog.allThemes.count }

    /// Case-insensitive substring match over theme names. A linear scan
    /// over 485 entries — fine at that size.
    ///
    /// An empty query means "everything", which is what the picker shows
    /// before the user types. That case is handled here rather than
    /// delegated: `GhosttyThemeCatalog.search("")` returns NOTHING,
    /// because it filters on `String.contains`, and Foundation's
    /// overload is backed by `range(of:)` — which is nil for an empty
    /// needle. Delegating would leave the picker blank on open.
    static func search(_ query: String) -> [GhosttyThemeDefinition] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return GhosttyThemeCatalog.allThemes }
        return GhosttyThemeCatalog.search(trimmed)
    }

    /// One catalog theme → one variant's colors. Catalog hex has no
    /// leading `#` and is lowercase; `sanitized()` normalizes both. A
    /// color the theme omits stays Automatic; a palette slot it omits
    /// falls back to ghostty's own default for that index.
    static func colorSpec(from definition: GhosttyThemeDefinition) -> TerminalColorSpec {
        TerminalColorSpec(
            background: definition.background,
            foreground: definition.foreground,
            cursorColor: definition.cursorColor,
            cursorText: definition.cursorText,
            selectionBackground: definition.selectionBackground,
            selectionForeground: definition.selectionForeground,
            // The catalog has no bold color; leaving it Automatic means
            // ghostty renders bold in the foreground color, as it does now.
            boldColor: nil,
            palette: (0..<16).map { definition.palette[$0] ?? TerminalColorSpec.seedPalette[$0] }
        ).sanitized()
    }
}
