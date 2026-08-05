import Foundation

/// Every ghostty config key string this app emits. Nothing else in
/// Dreamux may spell one out — if upstream renames a key, this enum is
/// the single-file edit, and `GhosttyConfigAcceptanceTests` is what
/// tells you it happened.
enum TerminalConfigKey: String {
    case background, foreground
    case cursorColor          = "cursor-color"
    case cursorText           = "cursor-text"
    case selectionBackground  = "selection-background"
    case selectionForeground  = "selection-foreground"
    case boldColor            = "bold-color"
    case palette
    case fontFamily           = "font-family"
    case fontSize             = "font-size"
    case cursorStyle          = "cursor-style"
    case cursorStyleBlink     = "cursor-style-blink"
    case backgroundOpacity    = "background-opacity"
}

/// Pure: `TerminalThemeSpec` → the `key = value` pairs ghostty wants.
/// Imports Foundation and nothing else — no ghostty types reach this
/// file, which is what makes the real logic testable without a surface.
enum TerminalThemeRenderer {

    /// The theme layer for one appearance variant, in a stable order.
    /// Callers hand the pairs to `TerminalThemeCompiler`, which turns
    /// each into `builder.withCustom(key, value)`.
    static func lines(
        for spec: TerminalThemeSpec,
        variant: TerminalAppearanceVariant,
        opacity: Double
    ) -> [(key: String, value: String)] {
        let spec = spec.sanitized()
        let colors = spec[variant]
        var lines: [(key: String, value: String)] = [
            (TerminalConfigKey.background.rawValue, colors.background),
            (TerminalConfigKey.foreground.rawValue, colors.foreground),
        ]

        // Automatic (nil) means: omit the key and let ghostty derive the
        // color from fg/bg, exactly as it does today.
        func appendIfSet(_ key: TerminalConfigKey, _ value: String?) {
            guard let value else { return }
            lines.append((key.rawValue, value))
        }
        appendIfSet(.cursorColor, colors.cursorColor)
        appendIfSet(.cursorText, colors.cursorText)
        appendIfSet(.selectionBackground, colors.selectionBackground)
        appendIfSet(.selectionForeground, colors.selectionForeground)
        appendIfSet(.boldColor, colors.boldColor)

        // Ghostty's repeatable form: `palette = 0=#1D1F21`. Indices are
        // 0…15 only — 1.3.2 accepts a 16+ index without complaint, so
        // this loop is the only guard against a silently-wrong write.
        for (index, color) in colors.palette.enumerated() {
            lines.append((TerminalConfigKey.palette.rawValue, "\(index)=\(color)"))
        }

        if let family = spec.fontFamily {
            lines.append((TerminalConfigKey.fontFamily.rawValue, family))
        }
        lines.append((TerminalConfigKey.fontSize.rawValue, fontSizeValue(spec.fontSize)))
        lines.append((TerminalConfigKey.cursorStyle.rawValue, spec.cursorStyle.rawValue))
        lines.append((TerminalConfigKey.cursorStyleBlink.rawValue, spec.cursorBlink ? "true" : "false"))

        let clamped = min(max(opacity, 0), 1)
        if clamped < 1 {
            lines.append((
                TerminalConfigKey.backgroundOpacity.rawValue,
                String(format: "%.2f", clamped)
            ))
        }
        return lines
    }

    /// `key = value` text, one pair per line — the same form
    /// `TerminalConfiguration.rendered` produces for `.custom` commands.
    /// Used by the acceptance tests to hand a config straight to the C
    /// API without building a controller.
    static func text(_ lines: [(key: String, value: String)]) -> String {
        lines.map { "\($0.key) = \($0.value)" }.joined(separator: "\n")
    }

    /// `14` rather than `14.0`, but `13.5` survives — ghostty accepts
    /// both, and the shorter form keeps rendered configs readable.
    private static func fontSizeValue(_ size: Double) -> String {
        size.rounded() == size
            ? String(Int(size))
            : String(format: "%.1f", size)
    }
}
