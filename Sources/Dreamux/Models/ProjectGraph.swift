import Foundation

/// The project's plan-dependency graph: a node per shown plan, a
/// `.dependency` edge per `Runs: after`. Pure; laid out by FlowLayoutEngine
/// and rendered by ProjectGraphView (full on Flows, compact in the rail).
struct ProjectGraph: Equatable {
    let nodes: [FlowNode]   // id "plan-<path>", kind .plan
    let edges: [FlowEdge]   // kind .dependency, blocker → waiter

    /// Node ids waiting on a not-yet-done blocker (an incoming `.dependency`
    /// whose source isn't `.done`). Derived, so the renderer can dash them.
    var blockedIDs: Set<String> {
        let byID = Dictionary(nodes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return Set(edges.compactMap { byID[$0.from]?.status != .done ? $0.to : nil })
    }
}

enum ProjectGraphBuilder {
    static func build(
        plans: [PlanDoc],
        relativePath: (PlanDoc) -> String,
        resolveBlocker: (String) -> PlanDoc?,
        statusOf: (PlanDoc) -> PlanStatus
    ) -> ProjectGraph {
        let statusByURL = Dictionary(plans.map { ($0.fileURL, statusOf($0)) },
                                     uniquingKeysWith: { a, _ in a })
        func st(_ p: PlanDoc) -> PlanStatus { statusByURL[p.fileURL] ?? .ready }

        let nonMerged = plans.filter { st($0) != .merged }
        // (blocker, waiter) for non-merged waiters with a resolvable, non-self blocker.
        var pairs: [(blocker: PlanDoc, waiter: PlanDoc)] = []
        for waiter in nonMerged {
            guard let ref = waiter.runsAfter, let blocker = resolveBlocker(ref),
                  blocker.fileURL != waiter.fileURL else { continue }
            pairs.append((blocker, waiter))
        }
        // Included = non-merged, plus any MERGED blocker of a pair.
        var includedURLs = Set(nonMerged.map { $0.fileURL })
        for pair in pairs where st(pair.blocker) == .merged {
            includedURLs.insert(pair.blocker.fileURL)
        }
        // Stable order by relative path (PlanDoc carries no startedAt).
        let included = plans
            .filter { includedURLs.contains($0.fileURL) }
            .sorted { relativePath($0) < relativePath($1) }

        let nodes = included.map { plan in
            FlowNode(id: "plan-\(relativePath(plan))", kind: .plan,
                     label: plan.title, status: st(plan).flowStatus)
        }
        let edges = pairs
            .filter { includedURLs.contains($0.blocker.fileURL) && includedURLs.contains($0.waiter.fileURL) }
            .map { FlowEdge(from: "plan-\(relativePath($0.blocker))",
                            to: "plan-\(relativePath($0.waiter))", kind: .dependency) }
            // Sort so the graph is order-independent: `ProjectGraph` is
            // Equatable and dagre's layout is edge-insertion-order sensitive,
            // so the same dependencies must always yield the same graph.
            .sorted { ($0.from, $0.to) < ($1.from, $1.to) }
        return ProjectGraph(nodes: nodes, edges: edges)
    }
}
