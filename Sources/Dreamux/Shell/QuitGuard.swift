import Foundation

/// What a registrant would lose if the app quit right now.
struct BusyWork: Equatable {
    var runs = 0
    var busyTerminals = 0

    var isEmpty: Bool { runs == 0 && busyTerminals == 0 }
}

/// Anything owning killable work: RunnerManager (runs), PTYShellSession
/// (foreground jobs). Queried only at quit time — no polling.
@MainActor
protocol QuitGuardSource: AnyObject {
    var busyWork: BusyWork { get }
}

/// Weak registry the app delegate consults from `applicationShouldTerminate`.
/// Registrants never unregister; the hash table drops them on dealloc, so a
/// forgotten cleanup path can neither pin an object nor phantom-block quit.
@MainActor
final class QuitGuard {
    static let shared = QuitGuard()

    private let sources = NSHashTable<AnyObject>.weakObjects()

    func register(_ source: QuitGuardSource) {
        sources.add(source)
    }

    /// `nil` when quitting loses nothing; otherwise the sentence the
    /// confirmation alert shows beneath "Quit Dreamux?".
    func busySummary() -> String? {
        var total = BusyWork()
        for case let source as QuitGuardSource in sources.allObjects {
            let work = source.busyWork
            total.runs += work.runs
            total.busyTerminals += work.busyTerminals
        }
        return Self.summaryText(for: total)
    }

    static func summaryText(for work: BusyWork) -> String? {
        guard !work.isEmpty else { return nil }
        var parts: [String] = []
        if work.runs > 0 {
            parts.append("\(work.runs) run\(work.runs == 1 ? "" : "s")")
        }
        if work.busyTerminals > 0 {
            parts.append("\(work.busyTerminals) busy terminal\(work.busyTerminals == 1 ? "" : "s")")
        }
        return parts.joined(separator: " and ") + " will be terminated."
    }
}
