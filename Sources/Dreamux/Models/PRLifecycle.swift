import Foundation

/// GitHub pull-request lifecycle — a SIBLING to `FlowStatus`, deliberately
/// kept out of it: `FlowStatus` is contractually CLI-agnostic
/// (FlowGraph.swift), so GitHub concepts live here. Ordered draft→terminal
/// for display grouping only; precedence lives in PRDetailPayload.lifecycle.
enum PRLifecycle: String, Codable, Hashable, Sendable, CaseIterable {
    case draft, open, checksRunning, checksFailed, changesRequested, approved, merged, closed
}

/// PR state carried on a `FlowsBoard.Lane` — a sibling axis to
/// `effectiveStatus`, never folded into the CLI-agnostic Flow model.
struct PRLaneState: Equatable, Sendable {
    let lifecycle: PRLifecycle
    let url: String
    init(lifecycle: PRLifecycle, url: String) { self.lifecycle = lifecycle; self.url = url }
}
