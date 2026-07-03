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

    /// How long an unchanged, quiescent session may sit before the
    /// queue asks for attention.
    static let stallThreshold: TimeInterval = 120

    @ObservationIgnored private var quiescentSince: Date?
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
    }

    // MARK: - Mutations

    func enqueue(_ path: String) {
        guard !entries.contains(path) else { return }
        entries.append(path)
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
        save()
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.runPlan(path)
                // A skip/stop/advance while runPlan was in flight makes
                // this completion stale — don't touch the queue's state.
                guard self.currentPlanPath == path else { return }
                self.startPolling()
            } catch {
                guard self.currentPlanPath == path else { return }
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
    }

    private static func load(from url: URL) -> Payload? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Payload.self, from: data)
    }

    private func save() {
        let payload = Payload(entries: entries, state: state, currentPlanPath: currentPlanPath)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(payload) else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}
