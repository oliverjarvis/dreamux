import Foundation
import Observation

/// One "this plan was executed as this feature" link.
struct PlanRunRecord: Codable, Equatable {
    /// Plan file path relative to the project root.
    var planPath: String
    var featureName: String
    var startedAt: Date
}

/// Plan↔feature links, persisted to `<project>/.dreamux/plan-runs.json`
/// (same JSON-atomic-write pattern as `SidebarLayoutStore`) so plan
/// status survives relaunch. The ledger is the authority on "this plan
/// has been run"; checkbox progress and feature existence supply the
/// rest of the status derivation.
@MainActor
@Observable
final class PlanRunLedger {
    private(set) var records: [PlanRunRecord]
    @ObservationIgnored private let fileURL: URL

    init(project: Project) {
        fileURL = project.rootPath
            .appendingPathComponent(".dreamux", isDirectory: true)
            .appendingPathComponent("plan-runs.json")
        records = Self.load(from: fileURL)
    }

    func record(planPath: String, featureName: String) {
        records.removeAll { $0.planPath == planPath }
        records.append(PlanRunRecord(
            planPath: planPath, featureName: featureName, startedAt: Date()))
        save()
    }

    func recordForPlan(_ relativePath: String) -> PlanRunRecord? {
        records.first { $0.planPath == relativePath }
    }

    /// Drop records whose feature was closed WITHOUT completing the plan
    /// (the plan goes back to `ready`). Records for completed plans are
    /// kept even after the feature is torn down — that's what makes the
    /// plan read `merged`.
    func reconcile(
        existingFeatureNames: Set<String>,
        isPlanComplete: (String) -> Bool
    ) {
        let before = records
        records.removeAll { record in
            !existingFeatureNames.contains(record.featureName)
                && !isPlanComplete(record.planPath)
        }
        if records != before { save() }
    }

    // MARK: - Persistence

    private static func load(from url: URL) -> [PlanRunRecord] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([PlanRunRecord].self, from: data)) ?? []
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(records) else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}
