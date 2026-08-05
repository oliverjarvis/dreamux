import Foundation
import Observation

/// The app's one copy of the Claude quota reading: whatever the most
/// recent statusline tap reported, persisted so a cold start shows the
/// last-known figure instead of an empty gauge, and re-published on a
/// 60 s tick so the reset rule fires and the age text advances without
/// waiting for a new reading.
///
/// Both surfaces — the sidebar footer and the menu bar item — observe
/// this store; neither owns state.
@MainActor
@Observable
final class UsageStore {
    static let shared = UsageStore()

    /// The latest reading, or nil when one has never arrived. Nil is a
    /// real state with a real rendering: no footer, no menu bar item.
    private(set) var snapshot: ClaudeUsageSnapshot?

    /// The moment the surfaces render as "now". A stored property, not
    /// a call to `Date()`, precisely so advancing it re-renders every
    /// observer — that is what makes the reset rule fire on its own.
    private(set) var now: Date

    /// Whether the menu bar item is installed. Persisted (default
    /// shown), and settable from both surfaces — hidden from the menu,
    /// restored from the sidebar footer's popover — so it can never be
    /// turned off with no way back.
    var menuBarVisible: Bool {
        didSet {
            guard menuBarVisible != oldValue else { return }
            defaults.set(menuBarVisible, forKey: Self.menuBarDefaultsKey)
        }
    }

    static let menuBarDefaultsKey = "UsageMenuBarVisible"

    @ObservationIgnored private let fileURL: URL?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var ticker: Timer?

    /// Production wiring, used only by `shared`.
    private convenience init() {
        self.init(fileURL: Self.defaultFileURL(), defaults: .standard,
                  now: Date(), startTicking: true)
    }

    /// Test seam: a sandboxed file (or nil for memory-only), a private
    /// defaults suite, a fixed starting moment, and no timer.
    init(fileURL: URL?, defaults: UserDefaults, now: Date, startTicking: Bool) {
        self.fileURL = fileURL
        self.defaults = defaults
        self.now = now
        self.menuBarVisible = defaults.object(forKey: Self.menuBarDefaultsKey) as? Bool ?? true
        self.snapshot = Self.load(from: fileURL)
        if startTicking { startTicker() }
    }

    /// `<App Support>/<bundle id>/usage.json` — beside `signals.db`,
    /// resolved by the same `BundleIdentity` rule, so a tagged debug
    /// build forks its reading automatically. nil when App Support is
    /// unreachable; the store then runs memory-only.
    static func defaultFileURL() -> URL? {
        let fm = FileManager.default
        guard let base = try? fm.url(for: .applicationSupportDirectory,
                                     in: .userDomainMask,
                                     appropriateFor: nil, create: true)
        else { return nil }
        let dir = BundleIdentity.appSupportBundleDir(base: base)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("usage.json")
    }

    /// Last-writer-wins by `observedAt`. Several sessions reporting
    /// concurrently is normal — they all see the same account-wide
    /// figures — so a reading that arrives late but was observed earlier
    /// is dropped rather than overwriting a newer one.
    func ingest(_ incoming: ClaudeUsageSnapshot) {
        if let current = snapshot, incoming.observedAt < current.observedAt { return }
        snapshot = incoming
        save()
    }

    /// Advance the rendered moment. Driven by the tick timer; tests call
    /// it directly.
    func tick(to date: Date) { now = date }

    /// One timer for the whole app. Generous tolerance — nothing here is
    /// time-critical, and a 60 s tick should never pull the CPU out of
    /// an idle state on its own account.
    private func startTicker() {
        let timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick(to: Date()) }
        }
        timer.tolerance = 10
        ticker = timer
    }

    private static func load(from url: URL?) -> ClaudeUsageSnapshot? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ClaudeUsageSnapshot.self, from: data)
    }

    private func save() {
        guard let fileURL, let snapshot,
              let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
