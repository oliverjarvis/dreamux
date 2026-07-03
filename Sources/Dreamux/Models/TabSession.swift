import Foundation
import GhosttyTerminal

/// One tab inside a workspace: a single Ghostty surface backed by its own
/// PTY-managed shell. Lives as long as the user keeps the tab open.
@MainActor
@Observable
final class TabSession: Identifiable {
    let id = UUID()
    let viewState: TerminalViewState
    /// The working directory the shell was started in — nil means the
    /// caller's environment default. Exposed so callers that programmatically
    /// open a tab (e.g. `WorkspaceSession.openAgentTab`) can confirm where
    /// it landed.
    let cwd: String?
    /// True when this tab has had agent activity (terminal bell) since the
    /// user last looked at it. Drives the badge on the workspace tile.
    var hasUnread: Bool = false

    private let shell: PTYShellSession
    private var didStart = false

    init(
        cwd: String? = nil,
        onActivity: @escaping @Sendable (String?) -> Void = { _ in }
    ) {
        self.cwd = cwd
        self.shell = PTYShellSession(cwd: cwd, onActivity: onActivity)

        // Ghostty ships with default `super+<letter>` keybinds (super+t,
        // super+d, super+w, …) for actions its own app shell implements.
        // We embed the surface in our own multi-pane manager, so those
        // actions are no-ops here — but Ghostty's `performKeyEquivalent`
        // still *consumes* the events, blocking our SwiftUI command menu
        // from receiving them. Mark them `ignore` so the events bubble up
        // to AppKit and fire our shortcuts (Cmd+T, Cmd+D, Cmd+W, …).
        let releaseGhosttyShortcuts: (inout TerminalConfiguration.Builder) -> Void = { builder in
            // Ghostty's keybind grammar is `<trigger>=<action>`. The
            // `unbind` action removes the binding so `keyIsBinding`
            // returns false — letting the event flow up the responder
            // chain to AppKit's menu. `=ignore` keeps the binding alive
            // as a no-op which still gets consumed.
            for key in ["t", "n", "d", "w", "q"] {
                builder.withCustom("keybind", "super+\(key)=unbind")
                builder.withCustom("keybind", "shift+super+\(key)=unbind")
                builder.withCustom("keybind", "alt+super+\(key)=unbind")
                builder.withCustom("keybind", "shift+alt+super+\(key)=unbind")
            }
            builder.withCustom("keybind", "alt+super+left=unbind")
            builder.withCustom("keybind", "alt+super+right=unbind")
            builder.withCustom("keybind", "alt+super+up=unbind")
            builder.withCustom("keybind", "alt+super+down=unbind")
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

    @ObservationIgnored private var _terminalView: TerminalView?

    /// The tab's terminal NSView. Session-owned — not SwiftUI-owned — so
    /// the ghostty surface behind it (grid, scrollback, running TUI
    /// state) survives any view-tree teardown: project switches, layout
    /// restructures, tab drags. `TerminalSurfaceView` would instead
    /// create a view per mount, and the surface dies with its view's
    /// coordinator, taking the terminal contents with it. Mirrors how
    /// `WebTabSession`/`FileEditorTabSession` own their WKWebViews.
    /// Created on first host so headless code paths (tests) never touch
    /// the render stack.
    var terminalView: TerminalView {
        if let view = _terminalView { return view }
        let view = TerminalView(frame: .zero)
        // Same order as the package's TerminalViewRepresentable
        // .configureView(_:initial:): delegate, controller, then
        // configuration — the configuration assignment is what attaches
        // the in-memory backend and builds the surface.
        view.delegate = viewState
        view.controller = viewState.controller
        view.configuration = viewState.configuration
        _terminalView = view
        return view
    }

    /// Re-attach the hosted view to its controller if they ever diverge
    /// — called from the host's `updateNSView` for parity with the
    /// package representable, which re-ran this check on every SwiftUI
    /// update pass. Deliberately does NOT touch `configuration`: ours
    /// never changes after init, and re-assigning it rebuilds the
    /// surface, wiping the terminal.
    func resyncTerminalViewIfNeeded() {
        guard let view = _terminalView else { return }
        if view.controller !== viewState.controller {
            view.controller = viewState.controller
        }
    }

    /// Visible-viewport text of this tab's terminal, or `nil` when no
    /// surface is attached yet. e2e readback only.
    func readViewportText() -> String? {
        shell.terminalSession.readViewportText()
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

    /// Push text into the tab's shell as if the user typed it. Used by
    /// the Run-setup flow to drop a Claude prompt straight into a fresh
    /// tab. Caller controls the trailing newline.
    func send(_ text: String) {
        shell.send(text)
    }

    /// True when the shell has produced output and then stayed silent
    /// for `interval` — i.e. its prompt is drawn and the line editor is
    /// waiting. Programmatic senders must wait for this: zsh's startup
    /// flushes the PTY input queue (tcsetattr TCSAFLUSH), so text sent
    /// into a still-booting shell is silently discarded, and early
    /// output (title escapes, profile noise) makes "any output" an
    /// unsafe readiness signal.
    func isShellQuiescent(for interval: TimeInterval) -> Bool {
        shell.isQuiescent(for: interval)
    }

    /// When the shell last produced output — used by senders to verify
    /// their text was echoed (received) and not flushed by a
    /// still-initializing line editor.
    var lastShellOutputAt: Date? { shell.lastOutputTimestamp }
}
