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

    let binding = ClaudeSessionBinding()

    // MARK: - Face state

    enum TabFace: Equatable { case chat, terminal }
    /// Which face this tab shows. Terminal until a session first binds,
    /// then auto-flips to chat ONCE; after that the user's choice sticks
    /// (in-memory — tabs don't persist across launches).
    var face: TabFace = .terminal
    @ObservationIgnored private var didAutoFlip = false

    func autoFlipToChatOnce() {
        guard !didAutoFlip else { return }
        didAutoFlip = true
        face = .chat
    }

    private let shell: PTYShellSession
    private var didStart = false

    /// Held for this session's lifetime: dropping it removes the
    /// `.terminalThemeDidChange` observer.
    @ObservationIgnored private var themeObserver: TerminalThemeObserver?

    init(
        cwd: String? = nil,
        onActivity: @escaping @Sendable (String?) -> Void = { _ in }
    ) {
        self.cwd = cwd
        let binding = self.binding
        self.shell = PTYShellSession(
            cwd: cwd,
            onActivity: onActivity,
            onControl: { verb, json in
                Task { @MainActor in binding.handleControl(verb: verb, json: json) }
            }
        )

        // Colors, font, cursor, padding and the ghostty keybind unbinds
        // all come from the app-wide theme store now — one compile, two
        // layers, identical for every session. See
        // TerminalThemeCompiler for the precedence rule.
        let compiled = TerminalThemeStore.shared.compiled()
        self.viewState = TerminalViewState(
            theme: compiled.theme,
            terminalConfiguration: compiled.configuration
        )
        self.viewState.configuration = TerminalSurfaceOptions(
            backend: .inMemory(shell.terminalSession)
        )

        // The controller resolved and pushed that config during its own
        // init. If ghostty rejected it (a bad hand-edited ghostty.conf is
        // the usual cause) it silently kept the base config — including
        // NO keybind unbinds — so run the ladder to recover.
        if viewState.controller.lastConfigurationIssue != nil {
            applyThemeFromStore(force: true)
        }

        themeObserver = TerminalThemeObserver { [weak self] in
            self?.applyThemeFromStore()
        }
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

    // MARK: - Theme

    /// Recompile from the store and push, degrading rather than losing
    /// the theme if ghostty rejects something.
    ///
    /// `prepareConfig` treats ANY diagnostic as fatal for the ENTIRE
    /// config, so one stale key would otherwise throw away every color
    /// the user chose, with an NSLog as the only trace. Two ordered
    /// steps, cheapest loss first.
    func applyThemeFromStore(force: Bool = false) {
        let store = TerminalThemeStore.shared

        guard let issue = apply(store.compiled(), force: force) else { return }

        // 1. Drop the hand-edited conf: the least-validated input, and
        //    the likeliest culprit. Losing it costs the escape hatch
        //    rather than the theme. The app invariants stay — dropping
        //    the whole configuration layer would break Cmd+T/Cmd+W,
        //    which is worse than a wrong background.
        guard let degradedIssue = apply(
            store.compiled(includingAdvancedConf: false), force: force
        ) else {
            store.reportIssue(issue)
            return
        }

        // 2. background + foreground only — the two keys least likely
        //    to ever drift.
        if let minimalIssue = apply(
            TerminalThemeCompiler.minimal(spec: store.spec), force: force
        ) {
            store.reportIssue(minimalIssue)
        } else {
            store.reportIssue(degradedIssue)
        }
    }

    /// Push a compiled pair and return ghostty's complaint, or nil.
    ///
    /// Two rules, both learned from the wrapper's source:
    /// `setTheme`/`setTerminalConfiguration` return `false` for BOTH
    /// rejection and "unchanged", so their return value is useless —
    /// and `lastConfigurationIssue` is only meaningful right after a
    /// push that actually happened, since a successful second push
    /// clears a failed first one's issue.
    private func apply(_ compiled: CompiledTerminalTheme, force: Bool) -> String? {
        let configurationChanged = compiled.configuration != viewState.terminalConfiguration
        let themeChanged = compiled.theme != viewState.theme

        guard configurationChanged || themeChanged else {
            // Nothing to push. On the normal path that's success; on the
            // recovery path it means this rung of the ladder is
            // identical to the config that just failed, so keep falling.
            return force
                ? (viewState.controller.lastConfigurationIssue
                    ?? "ghostty rejected the terminal configuration")
                : nil
        }

        if configurationChanged {
            viewState.setTerminalConfiguration(compiled.configuration)
            if let issue = viewState.controller.lastConfigurationIssue { return issue }
        }
        if themeChanged {
            viewState.setTheme(compiled.theme)
            if let issue = viewState.controller.lastConfigurationIssue { return issue }
        }
        return nil
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

    // MARK: - Chat-face input (gated — never blind-type)

    /// Send a composer prompt into the bound claude TUI. Returns false
    /// (and sends nothing) unless the session is at its input prompt.
    /// `.waitingForUser` is deliberately excluded — it can mean a
    /// permission dialog is up (the transcript stays silent, only the
    /// Notification hook fires), and blind-typing a prompt there would
    /// send its CR straight into the dialog.
    @discardableResult
    func sendChatPrompt(_ text: String) -> Bool {
        guard binding.phase == .idle,
              binding.conversation?.pendingQuestion == nil,
              !text.isEmpty else { return false }
        shell.send(PromptKeystrokeRecipes.promptSend(text))
        return true
    }

    /// Answer the pending AskUserQuestion by option indices (single- or
    /// multi-select decided by the question itself).
    @discardableResult
    func answerQuestion(selecting indices: [Int]) -> Bool {
        guard binding.phase == .waitingForUser,
              let question = binding.conversation?.pendingQuestion?.questions.first,
              let first = indices.first, indices.allSatisfy({ (0..<question.options.count).contains($0) })
        else { return false }
        shell.send(question.multiSelect
            ? PromptKeystrokeRecipes.selectOptions(at: indices)
            : PromptKeystrokeRecipes.selectOption(at: first))
        return true
    }

    /// Answer the pending question with free text via its Other row.
    @discardableResult
    func answerQuestionOther(text: String) -> Bool {
        guard binding.phase == .waitingForUser,
              let question = binding.conversation?.pendingQuestion?.questions.first,
              !text.isEmpty else { return false }
        shell.send(PromptKeystrokeRecipes.selectOtherAndType(
            optionCount: question.options.count, text: text))
        return true
    }

    /// ESC — stop the current turn.
    func interruptClaude() {
        guard binding.isBound else { return }
        shell.send(PromptKeystrokeRecipes.interrupt)
    }
}
