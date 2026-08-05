import Foundation
import GhosttyTerminal

/// The two halves `TerminalController` keeps separate, compiled together
/// so every session reaches the same verdict from the same input.
struct CompiledTerminalTheme: Equatable {
    /// Light + dark colors — the layer that wins for every key Settings owns.
    let theme: TerminalTheme
    /// App invariants plus the user's `ghostty.conf`, below the theme.
    let configuration: TerminalConfiguration
}

/// Turns rendered `key = value` pairs into the two config objects
/// `TerminalController` keeps separate: per-session `configuration`
/// overrides and the light/dark `theme`.
///
/// The ONLY file in Dreamux that touches `GhosttyTerminal` config types,
/// and it uses `builder.withCustom(key, value)` exclusively — never
/// `withBackground`, `withPalette`, or any other typed helper. The
/// escape hatch is the stable surface; the typed helpers are the wrapper
/// author's own API and the likeliest thing to churn on a version bump.
enum TerminalThemeCompiler {

    /// App invariants: the keybind unbinds and window padding that must
    /// survive every degrade step.
    ///
    /// Ghostty ships default `super+<letter>` keybinds for actions its
    /// own app shell implements. We embed the surface in our own pane
    /// manager, so those actions are no-ops here — but ghostty's
    /// `performKeyEquivalent` still CONSUMES the events, blocking our
    /// SwiftUI command menu. `unbind` removes the binding so the event
    /// bubbles up to AppKit and fires Cmd+T / Cmd+D / Cmd+W (`=ignore`
    /// would keep a no-op binding that still swallows the event).
    static func invariantLines() -> [(key: String, value: String)] {
        var lines: [(key: String, value: String)] = []
        for key in ["t", "n", "d", "w", "q"] {
            lines.append(("keybind", "super+\(key)=unbind"))
            lines.append(("keybind", "shift+super+\(key)=unbind"))
            lines.append(("keybind", "alt+super+\(key)=unbind"))
            lines.append(("keybind", "shift+alt+super+\(key)=unbind"))
        }
        for arrow in ["left", "right", "up", "down"] {
            lines.append(("keybind", "alt+super+\(arrow)=unbind"))
        }
        lines.append(("window-padding-x", "8"))
        lines.append(("window-padding-y", "8"))
        return lines
    }

    /// Full compile: invariants + advanced conf in the configuration
    /// layer, colors/font/cursor/opacity in the theme layer.
    static func compile(
        spec: TerminalThemeSpec,
        advancedConfLines: [String],
        cardOpacity: Double
    ) -> CompiledTerminalTheme {
        let configuration = TerminalConfiguration { builder in
            for line in invariantLines() {
                builder.withCustom(line.key, line.value)
            }
            for raw in advancedConfLines {
                guard let pair = customPair(from: raw) else { continue }
                builder.withCustom(pair.key, pair.value)
            }
        }
        return CompiledTerminalTheme(
            theme: TerminalTheme(
                light: themeConfiguration(spec: spec, variant: .light, opacity: cardOpacity),
                dark: themeConfiguration(spec: spec, variant: .dark, opacity: cardOpacity)
            ),
            configuration: configuration
        )
    }

    /// Last-resort degrade: `background` + `foreground` only — the two
    /// keys least likely to ever drift — and the app invariants without
    /// any advanced-conf lines.
    static func minimal(spec: TerminalThemeSpec) -> CompiledTerminalTheme {
        let clean = spec.sanitized()
        func colorsOnly(_ variant: TerminalAppearanceVariant) -> TerminalConfiguration {
            TerminalConfiguration { builder in
                builder.withCustom(
                    TerminalConfigKey.background.rawValue, clean[variant].background)
                builder.withCustom(
                    TerminalConfigKey.foreground.rawValue, clean[variant].foreground)
            }
        }
        return CompiledTerminalTheme(
            theme: TerminalTheme(light: colorsOnly(.light), dark: colorsOnly(.dark)),
            configuration: TerminalConfiguration { builder in
                for line in invariantLines() {
                    builder.withCustom(line.key, line.value)
                }
            }
        )
    }

    /// Split one raw `ghostty.conf` line into a key/value pair. Comments,
    /// blanks, and lines without a key before the first `=` are skipped
    /// rather than forwarded — ghostty would reject them, and one bad
    /// line costs the WHOLE config.
    static func customPair(from line: String) -> (key: String, value: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
        guard let separator = trimmed.firstIndex(of: "=") else { return nil }
        let key = trimmed[trimmed.startIndex..<separator]
            .trimmingCharacters(in: .whitespaces)
        let value = trimmed[trimmed.index(after: separator)...]
            .trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return nil }
        return (key, value)
    }

    private static func themeConfiguration(
        spec: TerminalThemeSpec,
        variant: TerminalAppearanceVariant,
        opacity: Double
    ) -> TerminalConfiguration {
        let lines = TerminalThemeRenderer.lines(
            for: spec, variant: variant, opacity: opacity)
        return TerminalConfiguration { builder in
            for line in lines {
                builder.withCustom(line.key, line.value)
            }
        }
    }
}
