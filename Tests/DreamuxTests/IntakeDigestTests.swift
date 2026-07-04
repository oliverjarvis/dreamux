import XCTest
@testable import Dreamux

/// The intake digest rides inside the New Plan kickoff prompt, so the
/// formatter is a pure, deterministic function and the async assembly
/// takes an injected diffstat closure — neither test ever shells out.
final class IntakeDigestTests: XCTestCase {

    // MARK: - Formatter (pure)

    func testPlanLineCarriesTitleStatusPathAndFeature() {
        let digest = IntakeDigest.render(
            plans: [(
                title: "Universal file viewers",
                path: "docs/plans/2026-07-02-viewers.md",
                status: .running,
                feature: "viewers",
                remainingTasks: ["Thumbnails", "Preview pane"]
            )],
            territories: ["docs/plans/2026-07-02-viewers.md": ["Sources", "Tests"]],
            queue: []
        )

        // One line names the plan with every field a disposition needs.
        guard let header = digest.split(separator: "\n").first(where: { $0.hasPrefix("- ") }) else {
            return XCTFail("digest has no plan header line")
        }
        let line = String(header)
        XCTAssertTrue(line.contains("Universal file viewers"))
        XCTAssertTrue(line.contains(PlanStatus.running.label))
        XCTAssertTrue(line.contains("docs/plans/2026-07-02-viewers.md"))
        XCTAssertTrue(line.contains("feature viewers"))
        // Remaining tasks and the running plan's territory both appear.
        XCTAssertTrue(digest.contains("Thumbnails"))
        XCTAssertTrue(digest.contains("Preview pane"))
        XCTAssertTrue(digest.contains("touches:"))
        XCTAssertTrue(digest.contains("Sources"))
    }

    func testFeatureOmittedWhenAbsent() {
        let digest = IntakeDigest.render(
            plans: [(
                title: "Fresh idea",
                path: "docs/plans/fresh.md",
                status: .ready,
                feature: nil,
                remainingTasks: []
            )],
            territories: [:],
            queue: []
        )
        XCTAssertTrue(digest.contains("Fresh idea"))
        XCTAssertFalse(digest.contains("feature"))
    }

    func testRemainingTasksCapAtSixWithOverflowMarker() {
        let tasks = (1...9).map { "Task \($0)" }
        let digest = IntakeDigest.render(
            plans: [(
                title: "Big plan",
                path: "docs/plans/big.md",
                status: .ready,
                feature: nil,
                remainingTasks: tasks
            )],
            territories: [:],
            queue: []
        )
        // First six listed; the rest collapse into a single overflow line.
        for shown in tasks.prefix(6) {
            XCTAssertTrue(digest.contains(shown), "expected \(shown) listed")
        }
        XCTAssertFalse(digest.contains("Task 7"), "seventh task must fold into the overflow")
        XCTAssertTrue(digest.contains("+3 more"))
    }

    func testEmptyInventoryIsClearlyEmpty() {
        let digest = IntakeDigest.render(plans: [], territories: [:], queue: [])
        XCTAssertFalse(digest.isEmpty)
        // A human/agent reading the prompt must see "there is nothing",
        // not an ambiguous blank.
        XCTAssertTrue(digest.lowercased().contains("no plans"))
        XCTAssertFalse(digest.contains("touches:"))
    }

    func testNoRunningPlansMeansNoTouchesLines() {
        let digest = IntakeDigest.render(
            plans: [
                (title: "A", path: "a.md", status: .ready, feature: nil, remainingTasks: ["x"]),
                (title: "B", path: "b.md", status: .inProgress, feature: "b", remainingTasks: ["y"]),
            ],
            territories: [:],
            queue: []
        )
        XCTAssertFalse(digest.contains("touches:"))
    }

    func testQueueOrderRenderedInInputOrder() {
        let digest = IntakeDigest.render(
            plans: [(title: "A", path: "a.md", status: .ready, feature: nil, remainingTasks: [])],
            territories: [:],
            queue: ["first.md", "second.md", "third.md"]
        )
        guard let queueSlice = digest.split(separator: "\n").first(where: { $0.contains("queue") }) else {
            return XCTFail("digest has no queue line")
        }
        let queueLine = String(queueSlice)
        // Order is preserved verbatim — the formatter never sorts.
        let firstIdx = queueLine.range(of: "first.md")!.lowerBound
        let secondIdx = queueLine.range(of: "second.md")!.lowerBound
        let thirdIdx = queueLine.range(of: "third.md")!.lowerBound
        XCTAssertTrue(firstIdx < secondIdx && secondIdx < thirdIdx)
    }

    func testTruncationHonoursHardByteCap() {
        // Enough plans, each with prose, to blow well past the 2 KB cap.
        let plans = (0..<200).map { i in
            (title: "Plan number \(i) with a deliberately long descriptive title",
             path: "docs/plans/2026-07-04-plan-\(i)-with-a-long-file-name.md",
             status: PlanStatus.ready,
             feature: String?.none,
             remainingTasks: ["First remaining task", "Second remaining task"])
        }
        let digest = IntakeDigest.render(plans: plans, territories: [:], queue: [])

        XCTAssertLessThanOrEqual(digest.utf8.count, IntakeDigest.maxBytes)
        XCTAssertTrue(digest.lowercased().contains("truncated"),
                      "an over-cap digest must carry an explicit truncation marker")
    }

    // MARK: - Assembly (async, injected diffstat)

    @MainActor
    func testBuildGathersRunningTerritoryFromInjectedDiffstat() async throws {
        let sandbox = try TestSandbox()
        defer { sandbox.destroy() }
        let project = try sandbox.makeProject(named: "demo")

        try writeDoc(in: project, "docs/plans/2026-07-04-widget.md", """
        # Widget Implementation Plan
        ### Task 1: Model
        - [x] **Step 1: schema**
        ### Task 2: View
        - [ ] **Step 1: layout**
        """)

        let store = DocStore(project: project)
        store.refresh()
        // Make the plan read `running`: a ledger link plus a live feature.
        store.ledger.record(planPath: "docs/plans/2026-07-04-widget.md", featureName: "widget")

        let repoRoot = project.rootPath.appendingPathComponent("repos/app", isDirectory: true)
        let digest = await IntakeDigest.build(
            docStore: store,
            repoRoots: [repoRoot],
            queue: ["docs/plans/2026-07-04-widget.md"],
            featureExists: { $0 == "widget" },
            diffstat: { url in
                // Proves build derives `<repoRoot>/<feature>` as the worktree.
                url.lastPathComponent == "widget" ? ["Sources", "Tests"] : []
            }
        )

        XCTAssertTrue(digest.contains("Widget Implementation Plan"))
        XCTAssertTrue(digest.contains(PlanStatus.running.label))
        XCTAssertTrue(digest.contains("feature widget"))
        // Only the still-open task surfaces as remaining work.
        XCTAssertTrue(digest.contains("Task 2: View"))
        XCTAssertFalse(digest.contains("Task 1: Model"))
        // The injected diffstat's paths land on a touches line.
        XCTAssertTrue(digest.contains("touches:"))
        XCTAssertTrue(digest.contains("Sources"))
        XCTAssertTrue(digest.contains("Tests"))
        // Queue order carried through.
        XCTAssertTrue(digest.contains("2026-07-04-widget.md"))
    }

    @MainActor
    func testBuildExcludesMergedPlansAndOmitsTouchesForNonRunning() async throws {
        let sandbox = try TestSandbox()
        defer { sandbox.destroy() }
        let project = try sandbox.makeProject(named: "demo")

        try writeDoc(in: project, "docs/plans/done.md", """
        # Done Implementation Plan
        ### Task 1: only
        - [x] **Step 1: a**
        """)
        try writeDoc(in: project, "docs/plans/open.md", """
        # Open Implementation Plan
        ### Task 1: only
        - [ ] **Step 1: a**
        """)

        let store = DocStore(project: project)
        store.refresh()
        // `done` ran and its feature is gone → merged (excluded from intake).
        store.ledger.record(planPath: "docs/plans/done.md", featureName: "done")

        let digest = await IntakeDigest.build(
            docStore: store,
            repoRoots: [],
            queue: [],
            featureExists: { _ in false },
            diffstat: { _ in ["should-not-appear"] }
        )

        XCTAssertFalse(digest.contains("Done Implementation Plan"),
                       "merged plans are noise for intake")
        XCTAssertTrue(digest.contains("Open Implementation Plan"))
        XCTAssertFalse(digest.contains("touches:"),
                       "no running plans → no territory lines")
        XCTAssertFalse(digest.contains("should-not-appear"))
    }

    @MainActor
    func testBuildEmptyInventoryIsClearlyEmpty() async throws {
        let sandbox = try TestSandbox()
        defer { sandbox.destroy() }
        let project = try sandbox.makeProject(named: "demo")
        let store = DocStore(project: project)
        store.refresh()

        let digest = await IntakeDigest.build(
            docStore: store,
            repoRoots: [],
            queue: [],
            featureExists: { _ in false }
        )
        XCTAssertTrue(digest.lowercased().contains("no plans"))
    }

    // MARK: - Helpers

    private func writeDoc(in project: Project, _ relative: String, _ contents: String) throws {
        let url = project.rootPath.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }
}
