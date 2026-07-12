import XCTest
@testable import Dreamux

final class ProjectGraphBuilderTests: XCTestCase {
    private func plan(_ name: String, runsAfter: String? = nil) -> PlanDoc {
        PlanDoc(fileURL: URL(fileURLWithPath: "/p/\(name).md"), kind: .plan,
                title: name, date: nil, goal: nil, specReference: nil,
                runsAfter: runsAfter, declaresParallel: false,
                checkedSteps: 0, totalSteps: 1, tasks: [])
    }
    // resolveBlocker matches by the "<name>" token in a "after <name>" ref.
    private func build(_ plans: [PlanDoc], status: [String: PlanStatus]) -> ProjectGraph {
        ProjectGraphBuilder.build(
            plans: plans,
            relativePath: { $0.fileURL.deletingPathExtension().lastPathComponent },
            resolveBlocker: { ref in plans.first { $0.fileURL.deletingPathExtension().lastPathComponent == ref } },
            statusOf: { status[$0.title] ?? .ready })
    }

    func testNonMergedBecomeNodesWithPlanIds() {
        let g = build([plan("a"), plan("b")], status: ["a": .running, "b": .ready])
        XCTAssertEqual(Set(g.nodes.map(\.id)), ["plan-a", "plan-b"])
        XCTAssertTrue(g.nodes.allSatisfy { $0.kind == .plan })
        XCTAssertEqual(g.nodes.first { $0.id == "plan-a" }?.status, .running)
    }
    func testRunsAfterMakesDependencyEdge() {
        let g = build([plan("a"), plan("b", runsAfter: "a")], status: ["a": .running, "b": .ready])
        XCTAssertEqual(g.edges, [FlowEdge(from: "plan-a", to: "plan-b", kind: .dependency)])
        XCTAssertTrue(g.blockedIDs.contains("plan-b"))   // behind a non-done blocker
    }
    func testMergedBlockerIncludedAsDoneAndWaiterNotBlocked() {
        let g = build([plan("a"), plan("b", runsAfter: "a")], status: ["a": .merged, "b": .ready])
        XCTAssertTrue(g.nodes.contains { $0.id == "plan-a" && $0.status == .done })
        XCTAssertFalse(g.blockedIDs.contains("plan-b"))  // blocker done → not blocked
    }
    func testMergedPlanBlockingNothingIsExcluded() {
        let g = build([plan("a"), plan("b")], status: ["a": .merged, "b": .ready])
        XCTAssertEqual(g.nodes.map(\.id), ["plan-b"])
    }
    func testUnresolvableAndSelfRefMakeNoEdge() {
        let g1 = build([plan("b", runsAfter: "missing")], status: ["b": .ready])
        XCTAssertTrue(g1.edges.isEmpty)
        let g2 = build([plan("b", runsAfter: "b")], status: ["b": .ready])
        XCTAssertTrue(g2.edges.isEmpty)
    }
    func testDeterministicOrder() {
        let a = build([plan("b"), plan("a")], status: [:]).nodes.map(\.id)
        let b = build([plan("a"), plan("b")], status: [:]).nodes.map(\.id)
        XCTAssertEqual(a, b)
    }
    func testWholeGraphEqualAcrossPermutations() {
        // Two independent chains; permuting the input must yield an EQUAL
        // graph (nodes AND edges), since ProjectGraph is Equatable and dagre
        // layout is edge-order sensitive.
        let g1 = build([plan("b", runsAfter: "a"), plan("a"), plan("d", runsAfter: "c"), plan("c")],
                       status: ["a": .running, "c": .running])
        let g2 = build([plan("c"), plan("d", runsAfter: "c"), plan("a"), plan("b", runsAfter: "a")],
                       status: ["a": .running, "c": .running])
        XCTAssertEqual(g1, g2)
    }
}
