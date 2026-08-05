import Foundation

/// Which of the spec's two color variants is in play.
enum TerminalAppearanceVariant: String, Codable, Sendable, CaseIterable {
    case dark, light

    var label: String {
        switch self {
        case .dark: "Dark"
        case .light: "Light"
        }
    }
}

enum TerminalCursorStyleSpec: String, Codable, Sendable, CaseIterable {
    case block, bar, underline

    var label: String {
        switch self {
        case .block: "Block"
        case .bar: "Bar"
        case .underline: "Underline"
        }
    }
}

/// Colors for one appearance variant. Hex is always "#RRGGBB", uppercase.
///
/// `background` and `foreground` are always emitted — ghostty 1.3.2 has
/// real defaults for both. The other five are optional because ghostty
/// has NO default for them (`ghostty_config_get` returns false); it
/// derives them from fg/bg at render time. `nil` means "Automatic": the
/// key is omitted entirely, which is exactly what Dreamux terminals do
/// today. Emitting a fixed value instead would restyle selection and
/// cursor rendering the day this ships.
struct TerminalColorSpec: Codable, Equatable, Sendable {
    var background: String
    var foreground: String
    var cursorColor: String?
    var cursorText: String?
    var selectionBackground: String?
    var selectionForeground: String?
    var boldColor: String?
    /// Exactly 16 entries, ANSI 0…15. `sanitized()` guarantees the count.
    var palette: [String]

    /// Ghostty 1.3.2's built-in ANSI palette, read out of libghostty with
    /// `ghostty_config_get`. `GhosttyConfigAcceptanceTests` re-reads the
    /// live values and fails if a version bump moves them.
    static let seedPalette: [String] = [
        "#1D1F21", "#CC6666", "#B5BD68", "#F0C674",
        "#81A2BE", "#B294BB", "#8ABEB7", "#C5C8C6",
        "#666666", "#D54E53", "#B9CA4A", "#E7C547",
        "#7AA6DA", "#C397D8", "#70C0B1", "#EAEAEA",
    ]

    /// Ghostty's own defaults — NOT a preset. Seeding from these is what
    /// makes shipping this feature a visual no-op until the user edits a
    /// swatch.
    static let seed = TerminalColorSpec(
        background: "#282C34",
        foreground: "#FFFFFF",
        cursorColor: nil,
        cursorText: nil,
        selectionBackground: nil,
        selectionForeground: nil,
        boldColor: nil,
        palette: seedPalette
    )

    /// `#RRGGBB` uppercase, or nil when `raw` isn't six hex digits (with
    /// or without a leading `#`).
    static func normalizedHex(_ raw: String?) -> String? {
        guard var value = raw?.trimmingCharacters(in: .whitespaces), !value.isEmpty
        else { return nil }
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6, UInt32(value, radix: 16) != nil else { return nil }
        return "#" + value.uppercased()
    }

    /// Force the invariants the renderer assumes: uppercase `#RRGGBB`
    /// everywhere, exactly 16 palette entries. Anything unparseable in a
    /// required slot falls back to the seed's value; in an optional slot
    /// it becomes Automatic.
    func sanitized() -> TerminalColorSpec {
        var clean = self
        clean.background = Self.normalizedHex(background) ?? Self.seed.background
        clean.foreground = Self.normalizedHex(foreground) ?? Self.seed.foreground
        clean.cursorColor = Self.normalizedHex(cursorColor)
        clean.cursorText = Self.normalizedHex(cursorText)
        clean.selectionBackground = Self.normalizedHex(selectionBackground)
        clean.selectionForeground = Self.normalizedHex(selectionForeground)
        clean.boldColor = Self.normalizedHex(boldColor)
        clean.palette = (0..<16).map { index in
            let raw = index < palette.count ? palette[index] : nil
            return Self.normalizedHex(raw) ?? Self.seedPalette[index]
        }
        return clean
    }
}

/// Two color variants plus the typography they share.
///
/// Font family, size, cursor style and blink are shared across light and
/// dark; only cursor *color* is per-variant. Semantic values are stored,
/// never rendered config text — a hex color cannot drift, a config key
/// can, so a ghostty key rename is one line in the renderer instead of a
/// migration across every user's stored blob.
struct TerminalThemeSpec: Codable, Equatable, Sendable {
    var dark: TerminalColorSpec
    var light: TerminalColorSpec
    /// nil = emit no `font-family` key at all (ghostty picks its own).
    var fontFamily: String?
    var fontSize: Double
    var cursorStyle: TerminalCursorStyleSpec
    var cursorBlink: Bool

    static let fontSizeRange: ClosedRange<Double> = 8...32

    /// Reproduces exactly what a Dreamux terminal renders today: ghostty
    /// 1.3.2's default colors for both variants, plus the typography
    /// `TabSession.init` used to hard-code (14pt, blinking bar cursor,
    /// ghostty's own font).
    static let seed = TerminalThemeSpec(
        dark: .seed,
        light: .seed,
        fontFamily: nil,
        fontSize: 14,
        cursorStyle: .bar,
        cursorBlink: true
    )

    subscript(variant: TerminalAppearanceVariant) -> TerminalColorSpec {
        get {
            switch variant {
            case .dark: dark
            case .light: light
            }
        }
        set {
            switch variant {
            case .dark: dark = newValue
            case .light: light = newValue
            }
        }
    }

    func sanitized() -> TerminalThemeSpec {
        var clean = self
        clean.dark = dark.sanitized()
        clean.light = light.sanitized()
        let family = fontFamily?.trimmingCharacters(in: .whitespaces)
        clean.fontFamily = (family?.isEmpty ?? true) ? nil : family
        clean.fontSize = min(max(fontSize, Self.fontSizeRange.lowerBound),
                             Self.fontSizeRange.upperBound)
        return clean
    }

    /// Absent, unreadable, or structurally incomplete JSON all give the
    /// seed — never a half-applied theme.
    static func decode(_ data: Data?) -> TerminalThemeSpec {
        guard let data,
              let decoded = try? JSONDecoder().decode(TerminalThemeSpec.self, from: data)
        else { return .seed }
        return decoded.sanitized()
    }

    func encoded() -> Data? {
        try? JSONEncoder().encode(self)
    }
}
