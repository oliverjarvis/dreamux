import XCTest
@testable import Dreamux

/// Intake enactment wired to the DocStore refresh: a plan carrying
/// `**Runs:** after <blocker>` auto-enqueues behind its blocker on the
/// next scan. These are integration-style — real files, real
/// `DocStore.parse`/`refresh`, real `PlanQueueController` — with the
/// per-doc status injected so a "merged" blocker doesn't need a live
/// ledger + torn-down worktree to set up.
@MainActor
final class IntakeEnactmentTests: XCTestCase {
    private var sandbox: TestSandbox!
    private var project: Project!
    private var docStore: DocStore!
    private var queue: PlanQueueController!
    /// relativePath → status override; anything absent reads as `.ready`.
    private var statusOverrides: [String: PlanStatus] = [:]

    // The async setUp/tearDown variants carry the class's @MainActor
    // isolation (the stored stores and the enact call need it).
    override func setUp() async throws {
        sandbox = try TestSandbox()
        project = try sandbox.makeProject(named: "demo")
        docStore = DocStore(project: project)
        queue = PlanQueueController(project: project)
        // Mirror ProjectSession's wiring, but with an injectable status so
        // the blocker's lifecycle state is set without ledger gymnastics.
        docStore.onRefresh = { [weak docStore, weak queue, weak self] in
            guard let docStore, let queue, let self else { return }
            IntakeEnactment.enact(
                docs: docStore.docs,
                queue: queue,
                relativePath: { docStore.relativePath(of: $0) },
                resolveReference: { docStore.resolvedURL(forReference: $0) },
                status: { doc in
                    self.statusOverrides[docStore.relativePath(of: doc)] ?? .ready
                })
        }
    }

    override func tearDown() async throws { sandbox?.destroy(); sandbox = nil }

    private func write(_ relativePath: String, _ contents: String) throws {
        let url = project.rootPath.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    private func plan(title: String, runsAfter: String? = nil) -> String {
        var lines = ["# \(title) Implementation Plan", ""]
        if let runsAfter { lines.append("**Runs:** after \(runsAfter)"); lines.append("") }
        lines += ["### Task 1: work", "- [ ] **Step 1: do it**"]
        return lines.joined(separator: "\n")
    }

    func testWaitingPlanEnqueuesBehindKnownBlockerOnRefresh() throws {
        try write("docs/plans/2026-07-04-blocker.md", plan(title: "Blocker"))
        try write("docs/plans/2026-07-04-waiter.md",
                  plan(title: "Waiter", runsAfter: "docs/plans/2026-07-04-blocker.md"))

        docStore.refresh()

        XCTAssertEqual(queue.entries, ["docs/plans/2026-07-04-waiter.md"],
                       "the waiting plan self-enqueues on the watcher tick")
    }

    func testMergedBlockerEnactsNothing() throws {
        try write("docs/plans/2026-07-04-blocker.md", plan(title: "Blocker"))
        try write("docs/plans/2026-07-04-waiter.md",
                  plan(title: "Waiter", runsAfter: "docs/plans/2026-07-04-blocker.md"))
        statusOverrides["docs/plans/2026-07-04-blocker.md"] = .merged

        docStore.refresh()

        XCTAssertTrue(queue.entries.isEmpty,
                      "a runsAfter pointing at a merged plan enacts nothing")
    }

    func testUnknownBlockerEnactsNothing() throws {
        try write("docs/plans/2026-07-04-waiter.md",
                  plan(title: "Waiter", runsAfter: "docs/plans/2026-07-04-ghost.md"))

        docStore.refresh()

        XCTAssertTrue(queue.entries.isEmpty,
                      "a runsAfter pointing at nothing enacts nothing")
    }

    func testSpecKindWithRunsHeaderIsIgnored() throws {
        try write("docs/plans/2026-07-04-blocker.md", plan(title: "Blocker"))
        // A spec (by `-design` suffix) that carries a Runs header parses a
        // `runsAfter`, but only PLAN-kind docs enact — the kind gate.
        try write("docs/specs/2026-07-04-thing-design.md", """
        # Thing Design

        **Runs:** after docs/plans/2026-07-04-blocker.md

        Prose only, no tasks.
        """)

        docStore.refresh()

        XCTAssertTrue(queue.entries.isEmpty,
                      "runsAfter on a spec-kind doc must not enact (kind gate)")
    }

    func testAlreadyRunWaiterIsNotEnqueued() throws {
        try write("docs/plans/2026-07-04-blocker.md", plan(title: "Blocker"))
        try write("docs/plans/2026-07-04-waiter.md",
                  plan(title: "Waiter", runsAfter: "docs/plans/2026-07-04-blocker.md"))
        // The waiter is already running — it has been enacted; don't
        // re-enqueue it behind its blocker.
        statusOverrides["docs/plans/2026-07-04-waiter.md"] = .running

        docStore.refresh()

        XCTAssertTrue(queue.entries.isEmpty,
                      "a waiter that has already run is left alone")
    }

    func testRemovedWaiterStaysOutAcrossRefresh() throws {
        try write("docs/plans/2026-07-04-blocker.md", plan(title: "Blocker"))
        try write("docs/plans/2026-07-04-waiter.md",
                  plan(title: "Waiter", runsAfter: "docs/plans/2026-07-04-blocker.md"))

        docStore.refresh()
        XCTAssertEqual(queue.entries, ["docs/plans/2026-07-04-waiter.md"])

        // The user pulls the auto-enqueued waiter back out. Enactment is
        // edge-triggered, so a later scan (the 3s tick) must NOT re-add it.
        queue.remove("docs/plans/2026-07-04-waiter.md")
        docStore.refresh()

        XCTAssertTrue(queue.entries.isEmpty, "removal sticks; the pair enacts once")
    }

    func testChangedBlockerReEnacts() throws {
        try write("docs/plans/2026-07-04-blocker-a.md", plan(title: "Blocker A"))
        try write("docs/plans/2026-07-04-blocker-b.md", plan(title: "Blocker B"))
        try write("docs/plans/2026-07-04-waiter.md",
                  plan(title: "Waiter", runsAfter: "docs/plans/2026-07-04-blocker-a.md"))

        docStore.refresh()
        XCTAssertEqual(queue.entries, ["docs/plans/2026-07-04-waiter.md"])
        queue.remove("docs/plans/2026-07-04-waiter.md")

        // Rewriting the `**Runs:**` header to a different blocker is a fresh
        // edge — the waiter enacts again despite the earlier removal.
        try write("docs/plans/2026-07-04-waiter.md",
                  plan(title: "Waiter", runsAfter: "docs/plans/2026-07-04-blocker-b.md"))
        docStore.refresh()

        XCTAssertEqual(queue.entries, ["docs/plans/2026-07-04-waiter.md"],
                       "a changed blocker re-enacts")
    }

    func testDottedBlockerPathResolvesToSameDoc() throws {
        try write("docs/plans/2026-07-04-blocker.md", plan(title: "Blocker"))
        // A non-canonical `./docs/…` blocker path must resolve to the same
        // doc as its canonical form (the **Spec:** resolution discipline),
        // not fail a raw string match.
        try write("docs/plans/2026-07-04-waiter.md",
                  plan(title: "Waiter", runsAfter: "./docs/plans/2026-07-04-blocker.md"))

        docStore.refresh()

        XCTAssertEqual(queue.entries, ["docs/plans/2026-07-04-waiter.md"],
                       "a dotted blocker path resolves symmetrically")
    }
}
