import XCTest
@testable import Dreamux

/// The `initiatives` array of the e2e `state` dump is pure over
/// `[Initiative]` + two project lookups, so it is table-tested directly
/// (mirroring `InitiativeProgressTests`) rather than through the socket
/// server. Cases cover the three shapes the dump distinguishes: a
/// multi-plan family with a spec and an absorbed roadmap, a needs-plan
/// initiative (spec, no plans), and a lone plan (no spec).
final class E2EStateDumpTests: XCTestCase {
    /// Project-relative path used by every case: the fixtures live under
    /// `/proj`, and the live command's `relativePath` strips the project
    /// root the same way.
    private let relativePath: (PlanDoc) -> String = {
        $0.fileURL.path.replacingOccurrences(of: "/proj/", with: "")
    }

    func testFullInitiativeCarriesSpecDocsOrdinalsAndTaskRollups() throws {
        let plan1 = PlanDoc.parse(
            fileURL: URL(fileURLWithPath: "/proj/docs/plans/2026-07-03-widget-phase-1.md"),
            contents: """
            # Widget Implementation Plan

            **Spec:** docs/specs/2026-07-03-widget-design.md

            ### Task 1: Model
            - [x] **Step 1: A.** first
            - [ ] **Step 2: B.** second

            ### Task 2: Wire it up
            - [ ] only step
            """)
        let plan2 = PlanDoc.parse(
            fileURL: URL(fileURLWithPath: "/proj/docs/plans/2026-07-03-widget-phase-2.md"),
            contents: """
            # Widget Phase 2 Implementation Plan

            ### Task 1: Cleanup
            - [x] done one
            - [x] done two
            """)
        let spec = PlanDoc.parse(
            fileURL: URL(fileURLWithPath: "/proj/docs/specs/2026-07-03-widget-design.md"),
            contents: "# Widget — Design\n\nDesign body.")
        let roadmap = PlanDoc.parse(
            fileURL: URL(fileURLWithPath: "/proj/docs/2026-07-03-widget-roadmap.md"),
            contents: "# Widget Roadmap\n\nReferences 2026-07-03-widget-phase-1.md.")

        let initiative = Initiative(
            id: "widget", title: "Widget", spec: spec,
            plans: [plan1, plan2], supportingDocs: [roadmap])

        // First plan in flight, second already merged — proves the status
        // lookup is applied per plan, not once for the group.
        let status: (PlanDoc) -> PlanStatus = {
            $0.fileURL.lastPathComponent == "2026-07-03-widget-phase-1.md" ? .running : .merged
        }
        let entry = try onlyEntry(
            E2EStateDump.initiativesPayload([initiative], relativePath: relativePath, status: status))

        XCTAssertEqual(Set(entry.keys), ["title", "id", "specPath", "docPaths", "plans"])
        XCTAssertEqual(entry["title"] as? String, "Widget")
        XCTAssertEqual(entry["id"] as? String, "widget")
        XCTAssertEqual(entry["specPath"] as? String, "docs/specs/2026-07-03-widget-design.md")
        XCTAssertEqual(entry["docPaths"] as? [String], ["docs/2026-07-03-widget-roadmap.md"])

        let plans = try XCTUnwrap(entry["plans"] as? [[String: Any]])
        XCTAssertEqual(plans.count, 2)

        XCTAssertEqual(plans[0]["path"] as? String, "docs/plans/2026-07-03-widget-phase-1.md")
        XCTAssertEqual(plans[0]["ordinal"] as? Int, 1)
        XCTAssertEqual(plans[0]["status"] as? String, "running")
        let tasks0 = try XCTUnwrap(plans[0]["tasks"] as? [[String: Any]])
        XCTAssertEqual(tasks0.count, 2)
        XCTAssertEqual(tasks0[0]["title"] as? String, "Task 1: Model")
        XCTAssertEqual(tasks0[0]["checked"] as? Int, 1)
        XCTAssertEqual(tasks0[0]["total"] as? Int, 2)
        XCTAssertEqual(tasks0[1]["title"] as? String, "Task 2: Wire it up")
        XCTAssertEqual(tasks0[1]["checked"] as? Int, 0)
        XCTAssertEqual(tasks0[1]["total"] as? Int, 1)

        XCTAssertEqual(plans[1]["path"] as? String, "docs/plans/2026-07-03-widget-phase-2.md")
        XCTAssertEqual(plans[1]["ordinal"] as? Int, 2)
        XCTAssertEqual(plans[1]["status"] as? String, "merged")
        let tasks1 = try XCTUnwrap(plans[1]["tasks"] as? [[String: Any]])
        XCTAssertEqual(tasks1.count, 1)
        XCTAssertEqual(tasks1[0]["title"] as? String, "Task 1: Cleanup")
        XCTAssertEqual(tasks1[0]["checked"] as? Int, 2)
        XCTAssertEqual(tasks1[0]["total"] as? Int, 2)
    }

    func testNeedsPlanInitiativeHasSpecButEmptyPlans() throws {
        let spec = PlanDoc.parse(
            fileURL: URL(fileURLWithPath: "/proj/docs/specs/2026-07-05-gizmo-design.md"),
            contents: "# Gizmo — Design\n\nBody.")
        let initiative = Initiative(
            id: "gizmo", title: "Gizmo", spec: spec, plans: [], supportingDocs: [])

        let entry = try onlyEntry(E2EStateDump.initiativesPayload(
            [initiative], relativePath: relativePath, status: { _ in .specOnly }))

        XCTAssertEqual(Set(entry.keys), ["title", "id", "specPath", "docPaths", "plans"])
        XCTAssertEqual(entry["specPath"] as? String, "docs/specs/2026-07-05-gizmo-design.md")
        XCTAssertEqual((entry["plans"] as? [[String: Any]])?.isEmpty, true)
        XCTAssertEqual((entry["docPaths"] as? [String])?.isEmpty, true)
    }

    func testLonePlanInitiativeOmitsSpecPath() throws {
        let plan = PlanDoc.parse(
            fileURL: URL(fileURLWithPath: "/proj/docs/plans/2026-07-06-widget.md"),
            contents: """
            # Widget Implementation Plan

            ### Task 1: Only
            - [ ] a
            """)
        let initiative = Initiative(
            id: "widget", title: "Widget", spec: nil, plans: [plan], supportingDocs: [])

        let entry = try onlyEntry(E2EStateDump.initiativesPayload(
            [initiative], relativePath: relativePath, status: { _ in .ready }))

        XCTAssertEqual(Set(entry.keys), ["title", "id", "docPaths", "plans"])
        XCTAssertFalse(entry.keys.contains("specPath"))
        let plans = try XCTUnwrap(entry["plans"] as? [[String: Any]])
        XCTAssertEqual(plans.count, 1)
        XCTAssertEqual(plans[0]["path"] as? String, "docs/plans/2026-07-06-widget.md")
        XCTAssertEqual(plans[0]["ordinal"] as? Int, 1)
        XCTAssertEqual(plans[0]["status"] as? String, "ready")
    }

    private func onlyEntry(_ payload: [[String: Any]]) throws -> [String: Any] {
        XCTAssertEqual(payload.count, 1)
        return try XCTUnwrap(payload.first)
    }
}
