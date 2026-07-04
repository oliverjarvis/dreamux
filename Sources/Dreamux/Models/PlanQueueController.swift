import Foundation
import Observation

enum PlanQueueState: String, Codable, Sendable {
    case idle, running, atGate, attention
}

/// Sequential plan-queue orchestration. Owns the ordered entries and a
/// small state machine; every external effect is an injected closure so
/// transitions are unit-testable. Persisted to
/// `<project>/.dreamux/plan-queue.json` so a relaunch resumes where it
/// left off (in `atGate`/`attention` the user decides; a `running`
/// state reloads as `running` and the next tick re-derives reality).
@MainActor
@Observable
final class PlanQueueController {
    // MARK: - Injected effects (wired in ContentView; fakes in tests)

    @ObservationIgnored var statusForPlan: (String) -> PlanStatus? = { _ in nil }
    @ObservationIgnored var runPlan: (String) async throws -> Void = { _ in }
    @ObservationIgnored var isFeatureQuiescent: (String) -> Bool = { _ in false }
    @ObservationIgnored var featureNameForPlan: (String) -> String? = { _ in nil }
    @ObservationIgnored var requestMerge: (String) -> Void = { _ in }
    @ObservationIgnored var now: () -> Date = Date.init

    // MARK: - State

    private(set) var entries: [String]
    private(set) var state: PlanQueueState
    private(set) var currentPlanPath: String?
    private(set) var lastError: String?

    /// Plans this controller has already auto-enqueued behind a blocker,
    /// keyed planPath → blockerPath. Intake enactment is edge-triggered off
    /// this map (not the live `entries`): a given (plan, blocker) pair
    /// enacts exactly once, so a waiter the user later removes is NOT
    /// re-added on the next watcher tick, while a plan whose `**Runs:**`
    /// header changes to a *different* blocker is a fresh edge and enacts
    /// again. Persisted next to `entries` in the same save file.
    @ObservationIgnored private(set) var enactedBlockers: [String: String] = [:]

    /// Plans already auto-run under the parallel toggle, by relative path.
    /// Intake auto-run is edge-triggered off this set the way enqueue is off
    /// `enactedBlockers`: a plan fires at most once, and — because the record
    /// is what triggers, not the plan's live status — a plan that was auto-run
    /// then reset to `.ready` (its feature closed, its ledger record pruned)
    /// is never relaunched, even across a relaunch of the app. Persisted next
    /// to `enactedBlockers` in the same save file; NEVER pruned (a brand-new
    /// plan file that reuses a retired path stays suppressed — the same
    /// accepted trade-off `enactedBlockers` makes).
    @ObservationIgnored private(set) var autoRanPlans: Set<String> = []

    /// How long an unchanged, quiescent session may sit before the
    /// queue asks for attention.
    static let stallThreshold: TimeInterval = 120

    @ObservationIgnored private var quiescentSince: Date?
    @ObservationIgnored private var launchInFlight = false
    @ObservationIgnored private var poller: Task<Void, Never>?
    @ObservationIgnored private let fileURL: URL

    init(project: Project) {
        fileURL = project.rootPath
            .appendingPathComponent(".dreamux", isDirectory: true)
            .appendingPathComponent("plan-queue.json")
        let loaded = Self.load(from: fileURL)
        entries = loaded?.entries ?? []
        state = loaded?.state ?? .idle
        currentPlanPath = loaded?.currentPlanPath
        enactedBlockers = loaded?.enactedBlockers ?? [:]
        autoRanPlans = Set(loaded?.autoRanPlans ?? [])
    }

    // MARK: - Mutations

    func enqueue(_ path: String) {
        guard !path.isEmpty else { return }
        guard !entries.contains(path) else { return }
        entries.append(path)
        save()
    }

    /// Intake enactment (spec: "Enactment (app side)"): place `path` in the
    /// queue *behind* its blocker without ever enqueuing the blocker itself.
    ///
    /// Edge-triggered: the (`path`, `blockerPath`) pair enacts once. A repeat
    /// call with the same pair is a no-op even if the user has since removed
    /// `path` from the queue — the record in `enactedBlockers`, not the live
    /// `entries`, is the trigger, so a manual remove sticks across watcher
    /// ticks. A call naming a *different* blocker for `path` is a fresh edge
    /// and re-enacts. The pair is recorded whether or not it is actually
    /// inserted, so enacting a plan the user had already queued still makes a
    /// later removal stick.
    ///
    /// Placement (when this edge does insert): no-op when `path` is already
    /// queued or is the running plan; otherwise the blocker holding a queue
    /// slot puts `path` immediately after it (a running blocker — still in
    /// `entries` — gets its waiter right behind it); a blocker running but no
    /// longer in `entries` puts `path` at the front; and a blocker neither
    /// queued nor running appends `path`, the row caption carrying the "after"
    /// relationship. Several plans naming the same blocker each insert right
    /// after it, so they land in reverse discovery order (the last enacted
    /// sits closest to the blocker) — deterministic and accepted.
    ///
    /// Additive: persists like `enqueue`; the state machine and gates are
    /// untouched, and the save format only grows the `enactedBlockers` map.
    func ensureQueued(_ path: String, after blockerPath: String) {
        guard !path.isEmpty else { return }
        guard enactedBlockers[path] != blockerPath else { return }
        enactedBlockers[path] = blockerPath
        if !entries.contains(path), currentPlanPath != path {
            if let index = entries.firstIndex(of: blockerPath) {
                entries.insert(path, at: index + 1)
            } else if currentPlanPath == blockerPath {
                entries.insert(path, at: 0)
            } else {
                entries.append(path)
            }
        }
        save()
    }

    /// Whether `path` has already been auto-run under the parallel toggle —
    /// the edge-trigger read for intake auto-run (survives relaunch).
    func hasAutoRun(_ path: String) -> Bool {
        autoRanPlans.contains(path)
    }

    /// Record that `path` was auto-run under the parallel toggle so it never
    /// fires again. Idempotent and persisted; call it before the launch so a
    /// failed launch can't re-fire on the next watcher tick.
    func markAutoRun(_ path: String) {
        guard !path.isEmpty, !autoRanPlans.contains(path) else { return }
        autoRanPlans.insert(path)
        save()
    }

    func remove(_ path: String) {
        entries.removeAll { $0 == path }
        if currentPlanPath == path { currentPlanPath = nil }
        save()
    }

    func move(fromOffsets: IndexSet, toOffset: Int) {
        entries.move(fromOffsets: fromOffsets, toOffset: toOffset)
        save()
    }

    func start() {
        guard state == .idle, let first = entries.first else { return }
        state = .running
        launch(first)
    }

    func stopQueue() {
        state = .idle
        currentPlanPath = nil
        quiescentSince = nil
        launchInFlight = false
        stopPolling()
        save()
    }

    /// Gate action: hand the current plan's feature to the merge flow.
    /// Advancing happens on a later tick, when the plan reads `merged`.
    func mergeAndContinue() {
        guard state == .atGate, let path = currentPlanPath,
              let feature = featureNameForPlan(path) else { return }
        requestMerge(feature)
    }

    func skipCurrent() {
        guard let path = currentPlanPath else { return }
        entries.removeAll { $0 == path }
        advance(after: path)
    }

    func resumeCurrent() {
        guard state == .attention, let path = currentPlanPath else { return }
        state = .running
        quiescentSince = nil
        launch(path)
    }

    // MARK: - Ticking

    func startPolling() {
        guard poller == nil else { return }
        poller = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard let self else { return }
                if self.state != .idle { self.tick() }
            }
        }
    }

    func stopPolling() {
        poller?.cancel()
        poller = nil
    }

    /// Derive transitions from the same derived statuses the sidebar
    /// shows. Pure function of injected probes — the tests drive this
    /// directly with fakes.
    func tick() {
        guard let path = currentPlanPath else { return }
        guard let status = statusForPlan(path) else {
            // Plan file vanished mid-queue: skip it.
            lastError = "Plan disappeared: \(path)"
            entries.removeAll { $0 == path }
            advance(after: path)
            return
        }

        switch (state, status) {
        case (.running, .awaitingReview):
            state = .atGate
            quiescentSince = nil
            save()
        case (.running, .merged), (.atGate, .merged):
            entries.removeAll { $0 == path }
            advance(after: path)
        case (.running, .inProgress):
            // The run's feature workspace is gone (app relaunch mid-run,
            // or the feature was closed under us) with steps unchecked —
            // surface it instead of silently waiting forever.
            state = .attention
            quiescentSince = nil
            save()
        case (.running, .ready):
            // While a launch is in flight the ledger record simply
            // hasn't been written yet — not a record loss.
            if launchInFlight { break }
            lastError = "Run record lost (feature closed?)"
            state = .attention
            quiescentSince = nil
            save()
        case (.running, .running):
            trackStall(for: path)
        case (.running, _), (.atGate, _), (.attention, _), (.idle, _):
            break
        }
    }

    private func trackStall(for path: String) {
        guard let feature = featureNameForPlan(path),
              isFeatureQuiescent(feature) else {
            quiescentSince = nil
            return
        }
        let since = quiescentSince ?? now()
        quiescentSince = since
        if now().timeIntervalSince(since) >= Self.stallThreshold {
            state = .attention
            save()
        }
    }

    private func advance(after path: String) {
        quiescentSince = nil
        if let next = entries.first {
            state = .running
            launch(next)
        } else {
            state = .idle
            currentPlanPath = nil
            save()
        }
    }

    private func launch(_ path: String) {
        currentPlanPath = path
        launchInFlight = true
        save()
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.runPlan(path)
                // A skip/stop/advance while runPlan was in flight makes
                // this completion stale — don't touch the queue's state.
                guard self.currentPlanPath == path else { return }
                self.launchInFlight = false
                self.startPolling()
            } catch {
                guard self.currentPlanPath == path else { return }
                self.launchInFlight = false
                self.lastError = error.localizedDescription
                self.state = .attention
                self.save()
            }
        }
    }

    // MARK: - Persistence

    private struct Payload: Codable {
        var entries: [String]
        var state: PlanQueueState
        var currentPlanPath: String?
        // Optional so save files written before edge-triggered enactment
        // still decode (missing → no pairs enacted yet), never resetting a
        // resumed queue on upgrade.
        var enactedBlockers: [String: String]?
        // Same backward-compat discipline: absent in pre-auto-run files
        // (missing → nothing auto-run yet). Sorted array for a stable file.
        var autoRanPlans: [String]?
    }

    private static func load(from url: URL) -> Payload? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Payload.self, from: data)
    }

    private func save() {
        let payload = Payload(entries: entries, state: state, currentPlanPath: currentPlanPath,
                              enactedBlockers: enactedBlockers, autoRanPlans: autoRanPlans.sorted())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(payload) else { return }
        DreamuxStateDir.ensure(containing: fileURL)
        try? data.write(to: fileURL, options: .atomic)
    }
}
