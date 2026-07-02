import XCTest
@testable import Dreamux

@MainActor
final class DocStoreTests: XCTestCase {
    private var sandbox: TestSandbox!
    private var project: Project!

    override func setUpWithError() throws {
        sandbox = try TestSandbox()
        project = try sandbox.makeProject(named: "demo")
    }
    override func tearDown() { sandbox?.destroy(); sandbox = nil }

    private func write(_ relative: String, _ contents: String) throws {
        let url = project.rootPath.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    func testEnsureDocsHomeCreatesDefaultLayout() {
        DocStore.ensureDocsHome(at: project.rootPath)
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: project.rootPath.appendingPathComponent("docs/specs").path,
            isDirectory: &isDir) && isDir.boolValue)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: project.rootPath.appendingPathComponent("docs/plans").path,
            isDirectory: &isDir) && isDir.boolValue)
    }

    func testScanClassifiesAndPairs() throws {
        try write("docs/specs/2026-07-02-x-design.md", "# X\n\ndesign")
        try write("docs/plans/2026-07-02-x.md", """
        # X Implementation Plan
        **Spec:** docs/specs/2026-07-02-x-design.md — read it.
        ### Task 1: a
        - [x] **Step 1: t**
        - [ ] **Step 2: u**
        """)
        try write("docs/notes.md", "# Notes\nplain")
        try write("docs/.hidden.md", "# skip me")

        let store = DocStore(project: project)
        store.refresh()

        XCTAssertEqual(store.plans.count, 1)
        XCTAssertEqual(store.unpairedSpecs.count, 0, "x-design is paired via **Spec:**")
        XCTAssertEqual(store.otherDocs.map(\.title), ["Notes"])

        let plan = store.plans[0]
        XCTAssertEqual(store.pairedSpec(for: plan)?.title, "X")
        XCTAssertEqual(store.relativePath(of: plan), "docs/plans/2026-07-02-x.md")
        XCTAssertEqual(plan.checkedSteps, 1)
        XCTAssertEqual(plan.totalSteps, 2)
    }

    func testSpecReferencedByPlanIsSpecEvenWithoutSuffix() throws {
        try write("docs/x-spec.md", "# X spec\nprose")
        try write("docs/x-plan.md", """
        # X Implementation Plan
        **Spec:** docs/x-spec.md
        """)
        let store = DocStore(project: project)
        store.refresh()
        XCTAssertEqual(store.plans.count, 1)
        XCTAssertEqual(store.pairedSpec(for: store.plans[0])?.title, "X spec")
        XCTAssertTrue(store.otherDocs.isEmpty)
    }

    func testUnpairedSpecSurfacesAsSpecOnly() throws {
        try write("docs/specs/lonely-design.md", "# Lonely\n")
        let store = DocStore(project: project)
        store.refresh()
        XCTAssertEqual(store.unpairedSpecs.map(\.title), ["Lonely"])
        XCTAssertEqual(store.status(for: store.unpairedSpecs[0], featureExists: { _ in false }),
                       .specOnly)
    }

    func testStatusUsesLedgerAndFeatureExistence() throws {
        try write("docs/plans/y.md", """
        # Y Implementation Plan
        ### Task 1: a
        - [x] **Step 1: t**
        """)
        let store = DocStore(project: project)
        store.refresh()
        let plan = store.plans[0]

        XCTAssertEqual(store.status(for: plan, featureExists: { _ in false }), .ready)
        store.ledger.record(planPath: "docs/plans/y.md", featureName: "y")
        XCTAssertEqual(store.status(for: plan, featureExists: { $0 == "y" }), .awaitingReview)
        XCTAssertEqual(store.status(for: plan, featureExists: { _ in false }), .merged)
    }

    func testMissingDocsDirYieldsEmpty() {
        let store = DocStore(project: project)
        store.refresh()
        XCTAssertTrue(store.docs.isEmpty)
    }
}
