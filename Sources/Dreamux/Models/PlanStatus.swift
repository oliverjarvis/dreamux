import Foundation

/// Where a plan sits in its lifecycle. Entirely DERIVED — from checkbox
/// progress in the plan file, the run ledger, and whether the linked
/// feature workspace currently exists. No status is ever written into
/// the doc.
enum PlanStatus: String, Sendable {
    case specOnly        // spec with no paired plan — "needs plan"
    case ready           // plan never run
    case inProgress      // run recorded, feature gone, boxes unchecked
    case running         // run recorded, feature alive
    case awaitingReview  // all boxes checked, feature still open
    case merged          // all boxes checked, feature closed (merge flow tears the worktree down)

    var glyph: String {
        switch self {
        case .specOnly: return "doc.badge.ellipsis"
        case .ready: return "circle.dotted"
        case .inProgress: return "circle.lefthalf.filled"
        case .running: return "bolt.fill"
        case .awaitingReview: return "checkmark.circle.badge.questionmark"
        case .merged: return "checkmark.seal.fill"
        }
    }

    var label: String {
        switch self {
        case .specOnly: return "needs plan"
        case .ready: return "ready"
        case .inProgress: return "in progress"
        case .running: return "running"
        case .awaitingReview: return "awaiting review"
        case .merged: return "merged"
        }
    }
}

extension PlanStatus {
    /// The shared status vocabulary this plan maps to (glyph/color via
    /// `FlowStatusGlyph`).
    var flowStatus: FlowStatus {
        switch self {
        case .running: return .running
        case .awaitingReview: return .waiting
        case .merged: return .done
        case .inProgress, .ready, .specOnly: return .queued
        }
    }
}

enum PlanStatusResolver {
    /// Status for a PLAN doc. `hasRun` = a ledger record links this plan
    /// to a feature; `featureExists` = that feature is currently in the
    /// sidebar (worktrees on disk).
    static func status(
        checked: Int,
        total: Int,
        hasRun: Bool,
        featureExists: Bool
    ) -> PlanStatus {
        guard hasRun else { return .ready }
        let complete = total > 0 && checked == total
        if complete {
            return featureExists ? .awaitingReview : .merged
        }
        return featureExists ? .running : .inProgress
    }
}
