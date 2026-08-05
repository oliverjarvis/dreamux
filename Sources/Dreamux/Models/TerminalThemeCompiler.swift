import Foundation
import GhosttyTerminal

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
}
