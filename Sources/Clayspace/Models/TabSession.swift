import Foundation
import GhosttyTerminal

/// One tab inside a workspace: a single Ghostty surface backed by its own
/// PTY-managed shell. Lives as long as the user keeps the tab open.
@MainActor
final class TabSession: Identifiable {
    let id = UUID()
    let viewState: TerminalViewState
    private let shell: PTYShellSession
    private var didStart = false

    init(cwd: String? = nil) {
        self.shell = PTYShellSession(cwd: cwd)

        // Ghostty ships with default `super+<letter>` keybinds (super+t,
        // super+d, super+w, …) for actions its own app shell implements.
        // We embed the surface in our own multi-pane manager, so those
        // actions are no-ops here — but Ghostty's `performKeyEquivalent`
        // still *consumes* the events, blocking our SwiftUI command menu
        // from receiving them. Mark them `ignore` so the events bubble up
        // to AppKit and fire our shortcuts (Cmd+T, Cmd+D, Cmd+W, …).
        let releaseGhosttyShortcuts: (inout TerminalConfiguration.Builder) -> Void = { builder in
            for key in ["t", "n", "d", "w", "q",
                        "1", "2", "3", "4", "5", "6", "7", "8", "9"] {
                builder.withCustom("keybind", "super+\(key)=ignore")
                builder.withCustom("keybind", "shift+super+\(key)=ignore")
                builder.withCustom("keybind", "alt+super+\(key)=ignore")
            }
            builder.withCustom("keybind", "super+left=ignore")
            builder.withCustom("keybind", "super+right=ignore")
            builder.withCustom("keybind", "alt+super+left=ignore")
            builder.withCustom("keybind", "alt+super+right=ignore")
            builder.withCustom("keybind", "alt+super+up=ignore")
            builder.withCustom("keybind", "alt+super+down=ignore")
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
