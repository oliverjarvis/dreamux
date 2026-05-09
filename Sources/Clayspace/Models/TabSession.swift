import Foundation
import GhosttyTerminal

/// One tab inside a workspace: a single Ghostty surface backed by its own
/// PTY-managed shell. Lives as long as the user keeps the tab open.
@MainActor
@Observable
final class TabSession: Identifiable {
    let id = UUID()
    let viewState: TerminalViewState
    /// True when this tab has had agent activity (terminal bell) since the
    /// user last looked at it. Drives the badge on the workspace tile.
    var hasUnread: Bool = false

    private let shell: PTYShellSession
    private var didStart = false

    init(
        cwd: String? = nil,
        onBell: @escaping @Sendable () -> Void = {}
    ) {
        self.shell = PTYShellSession(cwd: cwd, onBell: onBell)

        // Ghostty ships with default `super+<letter>` keybinds (super+t,
        // super+d, super+w, …) for actions its own app shell implements.
        // We embed the surface in our own multi-pane manager, so those
        // actions are no-ops here — but Ghostty's `performKeyEquivalent`
        // still *consumes* the events, blocking our SwiftUI command menu
        // from receiving them. Mark them `ignore` so the events bubble up
        // to AppKit and fire our shortcuts (Cmd+T, Cmd+D, Cmd+W, …).
        let releaseGhosttyShortcuts: (inout TerminalConfiguration.Builder) -> Void = { builder in
            // `unbind:` actually removes the binding so Ghostty's
            // `keyIsBinding` returns false — letting the event flow up the
            // responder chain to AppKit's menu. `=ignore` keeps the binding
            // alive (as a no-op) and Ghostty still consumes the event,
            // which is why Cmd+T was silently dropped before.
            for key in ["t", "n", "d", "w", "q"] {
                builder.withCustom("keybind", "unbind:super+\(key)")
                builder.withCustom("keybind", "unbind:shift+super+\(key)")
                builder.withCustom("keybind", "unbind:alt+super+\(key)")
                builder.withCustom("keybind", "unbind:shift+alt+super+\(key)")
            }
            builder.withCustom("keybind", "unbind:alt+super+left")
            builder.withCustom("keybind", "unbind:alt+super+right")
            builder.withCustom("keybind", "unbind:alt+super+up")
            builder.withCustom("keybind", "unbind:alt+super+down")
        }

        let theme = TerminalTheme(
            light: TerminalConfiguration { builder in
                builder.withFontSize(13)
                builder.withCursorStyle(.bar)
                builder.withCursorStyleBlink(true)
                builder.withWindowPaddingX(8)
                builder.withWindowPaddingY(8)
                releaseGhosttyShortcuts(&builder)
            },
            dark: TerminalConfiguration { builder in
                builder.withFontSize(13)
                builder.withCursorStyle(.bar)
                builder.withCursorStyleBlink(true)
                builder.withWindowPaddingX(8)
                builder.withWindowPaddingY(8)
                releaseGhosttyShortcuts(&builder)
            }
        )

        self.viewState = TerminalViewState(theme: theme)
        self.viewState.configuration = TerminalSurfaceOptions(
            backend: .inMemory(shell.terminalSession)
        )
    }

    var title: String {
        let t = viewState.title
        return t.isEmpty ? "shell" : t
    }

    /// Idempotent — safe to call from `onAppear`.
    func startIfNeeded() {
        guard !didStart else { return }
        didStart = true
        shell.start()
    }

    func stop() {
        shell.stop()
    }
}
