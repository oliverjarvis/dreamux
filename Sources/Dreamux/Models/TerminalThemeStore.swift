import Foundation

extension Notification.Name {
    /// The terminal theme (or the card transparency that renders into
    /// it) changed. Every live `TabSession` re-applies on this.
    static let terminalThemeDidChange = Notification.Name("terminalThemeDidChange")
}

/// App-wide terminal theme: the spec the user edits, its persistence,
/// the optional hand-edited `ghostty.conf`, and the debounced broadcast
/// that makes open terminals restyle.
@MainActor
@Observable
final class TerminalThemeStore {
    /// App-wide instance. A `var` so tests can swap in a store bound to
    /// a scratch defaults suite and a sandboxed conf path; production
    /// code never reassigns it.
    static var shared = TerminalThemeStore()

    private(set) var spec: TerminalThemeSpec
    /// The most recent ghostty rejection, surfaced in Settings. Cleared
    /// at the start of each apply cycle, never by an individual session
    /// reporting success.
    private(set) var lastIssue: String?

    private let defaults: UserDefaults
    /// Instance-level so tests can redirect it. Production always uses
    /// `defaultAdvancedConfURL`.
    var advancedConfURL: URL

    @ObservationIgnored private var notifyTask: Task<Void, Never>?

    /// Trailing coalesce window. A ColorPicker drag fires continuously;
    /// recompiling and re-pushing a config per pixel across every open
    /// terminal would stutter.
    private static let debounce = Duration.milliseconds(60)

    /// `<state root>/ghostty.conf` — the app's global state root, which
    /// is per-bundle-tag isolated and honours `DREAMUX_STATE_DIR`.
    static var defaultAdvancedConfURL: URL {
        ProjectStore.stateRootURL().appendingPathComponent("ghostty.conf")
    }

    init(
        defaults: UserDefaults = .standard,
        advancedConfURL: URL = TerminalThemeStore.defaultAdvancedConfURL
    ) {
        self.defaults = defaults
        self.advancedConfURL = advancedConfURL
        self.spec = TerminalThemeSpec.decode(
            defaults.data(forKey: AppearanceSettings.terminalThemeKey))
    }

    // MARK: - Editing

    /// Persist immediately (so the UI and the preview stay responsive)
    /// and coalesce the broadcast, so N sessions see one apply per
    /// gesture rather than N per drag frame.
    func update(_ spec: TerminalThemeSpec) {
        let clean = spec.sanitized()
        self.spec = clean
        defaults.set(clean.encoded(), forKey: AppearanceSettings.terminalThemeKey)
        requestReapply()
    }

    /// Coalesced re-apply without a spec change — used by the card
    /// transparency slider, whose value lives in `AppearanceSettings`
    /// but renders into the terminal's theme layer, and by the advanced
    /// conf's Reload button.
    func requestReapply() {
        notifyTask?.cancel()
        notifyTask = Task { [weak self] in
            try? await Task.sleep(for: Self.debounce)
            guard !Task.isCancelled, let self else { return }
            // A fresh cycle: sessions only ever ADD an issue, so the
            // clear has to happen here or a fixed problem would stick.
            self.lastIssue = nil
            NotificationCenter.default.post(name: .terminalThemeDidChange, object: nil)
        }
    }

    // MARK: - Compiling

    /// The compiled pair every session applies. Reads `ghostty.conf`
    /// fresh each time — the file is small, the call is rare, and it
    /// means an external edit lands on the next apply.
    func compiled(includingAdvancedConf: Bool = true) -> CompiledTerminalTheme {
        TerminalThemeCompiler.compile(
            spec: spec,
            advancedConfLines: includingAdvancedConf ? advancedConfLines() : [],
            cardOpacity: cardOpacity
        )
    }

    /// Card transparency, read at apply time rather than at tab
    /// construction — which is what makes the existing slider restyle
    /// terminals that are already open.
    private var cardOpacity: Double {
        defaults.object(forKey: AppearanceSettings.cardOpacityKey) as? Double ?? 1.0
    }

    // MARK: - Issues

    /// Record a ghostty rejection. `nil` is ignored: a healthy session
    /// must not erase a failing sibling's report inside the same cycle.
    func reportIssue(_ message: String?) {
        guard let message else { return }
        lastIssue = message
    }

    // MARK: - Advanced conf

    var advancedConfExists: Bool {
        FileManager.default.fileExists(atPath: advancedConfURL.path)
    }

    /// Re-read and re-apply. There is no FSEvents watcher — the file is
    /// re-read on every recompile anyway, and this button covers the
    /// "I just edited it, apply now" case.
    func reloadAdvancedConf() {
        requestReapply()
    }

    /// Write the commented template. Never overwrites an existing file.
    func createAdvancedConf() throws {
        guard !advancedConfExists else { return }
        try FileManager.default.createDirectory(
            at: advancedConfURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try Data(Self.advancedConfTemplate.utf8).write(to: advancedConfURL, options: .atomic)
    }

    /// Missing, unreadable, or non-UTF8 is an empty list, not an error —
    /// the file is optional by design.
    private func advancedConfLines() -> [String] {
        guard let text = try? String(contentsOf: advancedConfURL, encoding: .utf8)
        else { return [] }
        return text.components(separatedBy: .newlines)
    }

    /// Every example key here was verified to load with zero diagnostics
    /// on libghostty 1.3.2, though they ship commented out.
    static let advancedConfTemplate = """
    # Dreamux — advanced ghostty configuration
    #
    # Every line in this file is passed to ghostty verbatim, BELOW the
    # colors and font chosen in Settings > Appearance > Terminal. Settings
    # always wins for the keys it owns, so setting `background` here has
    # no effect.
    #
    # One `key = value` per line. Lines starting with `#` are ignored.
    # If ghostty rejects anything in this file, Dreamux drops the whole
    # file (keeping your theme) and shows the error in Settings.
    #
    # Examples — uncomment to use:
    #
    # minimum-contrast = 1.1
    # background-blur = 20
    # font-feature = -liga
    # window-padding-balance = true
    # mouse-hide-while-typing = true
    # scrollback-limit = 100000

    """
}

/// Lifetime-scoped `.terminalThemeDidChange` subscription.
///
/// Owning one as a `let` property removes the observer when the owner
/// deallocates. It exists as its own plain class because a `@MainActor`
/// type cannot touch a non-Sendable observer token from `deinit` under
/// Swift 6 — this box has no isolation, so its `deinit` can.
final class TerminalThemeObserver {
    private var token: (any NSObjectProtocol)?

    init(onChange: @escaping @Sendable @MainActor () -> Void) {
        token = NotificationCenter.default.addObserver(
            forName: .terminalThemeDidChange, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in onChange() }
        }
    }

    deinit {
        if let token { NotificationCenter.default.removeObserver(token) }
    }
}
