import XCTest
@testable import Dreamux

/// Grouping is exercised through `DocStore.refresh()` with real files on
/// disk (mirroring `DocStoreTests`) so the family-key helper, backlink
/// binding, slug union, ordering, and supporting-doc absorption are all
/// covered end to end. The pure `familyKey` helper is table-tested
/// directly for the adversarial slug cases.
@MainActor
final class InitiativeGroupingTests: XCTestCase {
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

    private func makeStore() -> DocStore {
        let store = DocStore(project: project)
        store.refresh()
        return store
    }

    // MARK: - Family key (pure, table-tested)

    func testFamilyKeyStripsDatePhaseAndDesignSuffix() {
        XCTAssertEqual(PlanDoc.familyKey(forFileName: "2026-07-02-gameboy-phase-1.md"), "gameboy")
        XCTAssertEqual(PlanDoc.familyKey(forFileName: "2026-07-02-gameboy-design.md"), "gameboy")
        XCTAssertEqual(PlanDoc.familyKey(forFileName: "2026-07-02-gameboy-roadmap.md"), "gameboy")
        XCTAssertEqual(PlanDoc.familyKey(forFileName: "x-phase-1.md"), "x")
        XCTAssertEqual(PlanDoc.familyKey(forFileName: "x-part-2.md"), "x")
        XCTAssertEqual(PlanDoc.familyKey(forFileName: "x-design.md"), "x")
        XCTAssertEqual(PlanDoc.familyKey(forFileName: "plain.md"), "plain")
    }

    /// The adversarial case: a trailing `-N` that is not a `phase-N` /
    /// `part-N` marker must not collapse into the shorter family stem.
    func testFamilyKeyDoesNotCollapseNonPhaseSuffix() {
        XCTAssertEqual(PlanDoc.familyKey(forFileName: "x-design-2.md"), "x-design-2")
        XCTAssertNotEqual(PlanDoc.familyKey(forFileName: "x-design-2.md"), "x")
    }

    // MARK: - Grouping

    func testLoneSpecBecomesNeedsPlanInitiative() throws {
        try write("docs/specs/lonely-design.md", "# Lonely\n\ndesign only")
        let store = makeStore()

        XCTAssertEqual(store.initiatives.count, 1)
        let it = store.initiatives[0]
        XCTAssertTrue(it.needsPlan)
        XCTAssertTrue(it.plans.isEmpty)
        XCTAssertEqual(it.spec?.title, "Lonely")
        XCTAssertEqual(it.title, "Lonely")
        XCTAssertTrue(store.looseDocs.isEmpty)
    }

    func testLonePlanBecomesSinglePlanInitiative() throws {
        try write("docs/plans/y.md", """
        # Y Implementation Plan
        ### Task 1: a
        - [x] **Step 1: t**
        """)
        let store = makeStore()

        XCTAssertEqual(store.initiatives.count, 1)
        let it = store.initiatives[0]
        XCTAssertTrue(it.isSinglePlan)
        XCTAssertFalse(it.needsPlan)
        XCTAssertNil(it.spec)
        XCTAssertEqual(it.plans.map(\.title), ["Y Implementation Plan"])
    }

    func testSpecAndPlanPairViaBacklink() throws {
        try write("docs/x-spec.md", "# X spec\n\nprose")
        try write("docs/x-plan.md", """
        # X Implementation Plan
        **Spec:** docs/x-spec.md
        ### Task 1: a
        - [ ] **Step 1: t**
        """)
        let store = makeStore()

        XCTAssertEqual(store.initiatives.count, 1)
        let it = store.initiatives[0]
        XCTAssertTrue(it.isSinglePlan)
        XCTAssertEqual(it.spec?.title, "X spec")
        // Backlink binds despite the mismatched slug (`x` vs `x-spec`).
        XCTAssertEqual(it.plans.map { $0.fileURL.lastPathComponent }, ["x-plan.md"])
        XCTAssertTrue(store.looseDocs.isEmpty)
    }

    func testThreePhaseFamilyAbsorbsRoadmapViaBodyLink() throws {
        try write("docs/specs/2026-07-02-gameboy-design.md",
                  "# Game Boy Emulator with 3D Diorama — Design\n\nthe design")
        try write("docs/plans/2026-07-02-gameboy-phase-1.md", """
        # Phase 1: Core Implementation Plan
        **Spec:** docs/specs/2026-07-02-gameboy-design.md
        ### Task 1: a
        - [x] **Step 1: t**
        """)
        try write("docs/plans/2026-07-02-gameboy-phase-2.md", """
        # Phase 2: PPU & Rendering Implementation Plan
        **Spec:** docs/specs/2026-07-02-gameboy-design.md
        ### Task 1: a
        - [ ] **Step 1: t**
        """)
        try write("docs/plans/2026-07-02-gameboy-phase-3.md", """
        # Phase 3: 3D Diorama Implementation Plan
        **Spec:** docs/specs/2026-07-02-gameboy-design.md
        ### Task 1: a
        - [ ] **Step 1: t**
        """)
        try write("docs/2026-07-02-gameboy-roadmap.md", """
        # Game Boy Roadmap

        Ships in three phases:
        - [Phase 1](docs/plans/2026-07-02-gameboy-phase-1.md)
        - [Phase 2](docs/plans/2026-07-02-gameboy-phase-2.md)
        - [Phase 3](docs/plans/2026-07-02-gameboy-phase-3.md)
        """)
        let store = makeStore()

        XCTAssertEqual(store.initiatives.count, 1)
        let it = store.initiatives[0]
        XCTAssertFalse(it.isSinglePlan)
        XCTAssertEqual(it.id, "gameboy")
        XCTAssertEqual(it.title, "Game Boy Emulator with 3D Diorama")
        XCTAssertEqual(it.plans.map { $0.fileURL.lastPathComponent }, [
            "2026-07-02-gameboy-phase-1.md",
            "2026-07-02-gameboy-phase-2.md",
            "2026-07-02-gameboy-phase-3.md",
        ])
        XCTAssertEqual(it.supportingDocs.map { $0.fileURL.lastPathComponent },
                       ["2026-07-02-gameboy-roadmap.md"])
        XCTAssertTrue(store.looseDocs.isEmpty)
    }

    /// Explicit `Phase N` in the title orders the plans even when their
    /// filename dates run the other way.
    func testExplicitPhaseOrderingBeatsDateOrder() throws {
        try write("docs/plans/2026-07-09-thing-phase-1.md", """
        # Phase 1: First Implementation Plan
        ### Task 1: a
        - [ ] **Step 1: t**
        """)
        try write("docs/plans/2026-07-02-thing-phase-2.md", """
        # Phase 2: Second Implementation Plan
        ### Task 1: a
        - [ ] **Step 1: t**
        """)
        let store = makeStore()

        XCTAssertEqual(store.initiatives.count, 1)
        let it = store.initiatives[0]
        // Phase 1 (dated 07-09) precedes Phase 2 (dated 07-02): N beats date.
        XCTAssertEqual(it.plans.map { $0.fileURL.lastPathComponent }, [
            "2026-07-09-thing-phase-1.md",
            "2026-07-02-thing-phase-2.md",
        ])
    }

    func testUnrelatedNoteStaysLoose() throws {
        try write("docs/plans/y.md", """
        # Y Implementation Plan
        ### Task 1: a
        - [x] **Step 1: t**
        """)
        try write("docs/notes.md", "# Notes\n\nnothing to do with any plan")
        let store = makeStore()

        XCTAssertEqual(store.initiatives.count, 1)
        XCTAssertEqual(store.looseDocs.map(\.title), ["Notes"])
    }

    /// A core doc whose family key is `x-design-2` must not be swept into
    /// family `x` by slug union.
    func testAdversarialSlugDoesNotJoinFamily() throws {
        try write("docs/specs/x-design.md", "# X\n\ndesign")
        try write("docs/plans/x.md", """
        # X Implementation Plan
        **Spec:** docs/specs/x-design.md
        ### Task 1: a
        - [x] **Step 1: t**
        """)
        try write("docs/plans/x-design-2.md", """
        # X Design Two Implementation Plan
        ### Task 1: a
        - [ ] **Step 1: t**
        """)
        let store = makeStore()

        let x = try XCTUnwrap(store.initiatives.first { $0.id == "x" })
        XCTAssertEqual(x.plans.map { $0.fileURL.lastPathComponent }, ["x.md"])
        XCTAssertEqual(x.spec?.title, "X")
        // The `-2` doc is its own initiative, not a member of family `x`.
        XCTAssertTrue(store.initiatives.contains { $0.id == "x-design-2" })
        XCTAssertEqual(store.initiatives.count, 2)
    }

    /// Spec-less multi-plan family: the title is the plans' common prefix.
    /// A divergence at a word boundary keeps the whole trailing word.
    func testCommonPrefixTitleKeepsWholeWordAtCleanBoundary() throws {
        try write("docs/plans/viewers-phase-1.md",
                  "# Universal File Viewers Core Implementation Plan\n")
        try write("docs/plans/viewers-phase-2.md",
                  "# Universal File Viewers Media Implementation Plan\n")
        let store = makeStore()

        XCTAssertEqual(store.initiatives.count, 1)
        let it = store.initiatives[0]
        XCTAssertNil(it.spec)
        XCTAssertEqual(it.plans.count, 2)
        XCTAssertEqual(it.title, "Universal File Viewers")
    }

    /// A genuine mid-word divergence drops the partial last word.
    func testCommonPrefixTitleDropsPartialWordAtMidWordBoundary() throws {
        try write("docs/plans/game-phase-1.md", "# Gameboy Corex Implementation Plan\n")
        try write("docs/plans/game-phase-2.md", "# Gameboy Corey Implementation Plan\n")
        let store = makeStore()

        XCTAssertEqual(store.initiatives.count, 1)
        let it = store.initiatives[0]
        XCTAssertNil(it.spec)
        XCTAssertEqual(it.title, "Gameboy")
    }

    /// The initiative sort keys off member (spec/plan) dates only, so a
    /// supporting doc dated earlier than the plans can't hoist its
    /// initiative up the list.
    func testSupportingDocDateDoesNotShiftInitiativeOrder() throws {
        // Family `aaa`: plan dated 07-05 + a roadmap dated 06-01 linking to it.
        try write("docs/plans/2026-07-05-aaa.md", "# Aaa Implementation Plan\n")
        try write("docs/2026-06-01-aaa-roadmap.md", "Ships via docs/plans/2026-07-05-aaa.md\n")
        // Family `bbb`: plan dated 07-01.
        try write("docs/plans/2026-07-01-bbb.md", "# Bbb Implementation Plan\n")
        let store = makeStore()

        let aaa = try XCTUnwrap(store.initiatives.first { $0.id == "aaa" })
        XCTAssertEqual(aaa.supportingDocs.map { $0.fileURL.lastPathComponent },
                       ["2026-06-01-aaa-roadmap.md"])
        // `aaa` (07-05) sorts before `bbb` (07-01) on plan date — the
        // 06-01 roadmap does not count toward the key.
        XCTAssertEqual(store.initiatives.map(\.id), ["aaa", "bbb"])
    }

    func testTwoFamiliesSharingADateDoNotMerge() throws {
        try write("docs/plans/2026-07-02-alpha.md", """
        # Alpha Implementation Plan
        ### Task 1: a
        - [x] **Step 1: t**
        """)
        try write("docs/plans/2026-07-02-beta.md", """
        # Beta Implementation Plan
        ### Task 1: a
        - [ ] **Step 1: t**
        """)
        let store = makeStore()

        XCTAssertEqual(store.initiatives.count, 2)
        XCTAssertEqual(Set(store.initiatives.map(\.id)), ["alpha", "beta"])
        XCTAssertTrue(store.initiatives.allSatisfy(\.isSinglePlan))
    }
}
