import Foundation

/// Grafts live subagents onto a task-DAG plan lane: each subagent becomes an
/// `.agent` node with a `.spawn` edge from its pinned task node
/// ("plan-task-<line>"), or from the current task when unpinned. Skips a
/// subagent whose target task isn't in the lane, or a duplicate id. Pure.
enum RunLaneGraft {
    static func graft(_ lane: Flow, subagents: [LiveSubagent], currentTaskLine: Int?) -> Flow {
        var lane = lane
        for sub in subagents {
            guard let targetLine = sub.taskLine ?? currentTaskLine else { continue }
            let target = "plan-task-\(targetLine)"
            guard lane.nodes.contains(where: { $0.id == target }) else { continue }
            guard !lane.nodes.contains(where: { $0.id == sub.id }) else { continue }
            lane.nodes.append(FlowNode(id: sub.id, kind: .agent, label: sub.name, status: sub.status))
            lane.edges.append(FlowEdge(from: target, to: sub.id, kind: .spawn))
        }
        return lane
    }
}
