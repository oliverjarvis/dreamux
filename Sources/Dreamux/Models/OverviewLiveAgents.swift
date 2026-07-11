import Foundation

/// Projects a workspace's live subagents out of its FlowStore lanes for the
/// Overview's "Working now" strip. Pure over its inputs (no store, no IO).
/// Excludes the main "session" node and the fan-out collapse node; keeps
/// only running/waiting; best-effort pins each to a plan task.
enum OverviewLiveAgents {
    static func subagents(
        in flows: [Flow],
        workspaceID: UUID,
        tasks: [PlanTask]
    ) -> [LiveSubagent] {
        let nodes = flows
            .filter { $0.workspaceID == workspaceID }
            .flatMap(\.nodes)
            .filter { node in
                node.kind == .agent
                    && node.id != "session"
                    && node.id != FlowStore.collapsedAgentNodeID
                    && (node.status == .running || node.status == .waiting)
            }
            .sorted { a, b in
                let ad = a.startedAt ?? .distantFuture   // nil sorts last
                let bd = b.startedAt ?? .distantFuture
                if ad != bd { return ad < bd }
                return a.id < b.id
            }
        return nodes.map { node in
            let text = node.label + " " + (node.lastActivity ?? "")
            return LiveSubagent(
                id: node.id,
                name: node.label,
                activity: node.lastActivity,
                status: node.status,
                taskLine: SubagentTaskPin.line(forAgentText: text, tasks: tasks))
        }
    }
}
