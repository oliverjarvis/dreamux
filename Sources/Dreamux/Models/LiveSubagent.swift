import Foundation

/// A subagent currently working on a run, projected from a FlowStore
/// `.agent` node for the workspace Overview's "Working now" strip.
struct LiveSubagent: Identifiable, Equatable {
    let id: String          // the FlowNode id, e.g. "agent-abc123"
    let name: String        // node.label (agent type)
    let activity: String?   // node.lastActivity ("what it's on"), may be nil
    let status: FlowStatus  // .running or .waiting only
    let taskLine: Int?      // best-effort pin to a PlanTask.line, else nil
}
