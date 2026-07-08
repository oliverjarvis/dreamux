import XCTest
@testable import Dreamux

final class WorkspacePlanResolverTests: XCTestCase {
    private func doc(_ name: String, _ contents: String) -> PlanDoc {
        PlanDoc.parse(fileURL: URL(fileURLWithPath: "/p/docs/\(name)"), contents: contents)
    }

    func testResolvePlanByFeatureName() {
        let planA = doc("2026-07-05-a.md", """
        # Plan A
        ### Task 1: a
        - [ ] **Step 1: test**
        """)

        let planB = doc("2026-07-05-b.md", """
        # Plan B
        ### Task 1: b
        - [ ] **Step 1: test**
        """)

        let plans = [planA, planB]
        let featureName: (PlanDoc) -> String? = { plan in
            if plan == planA {
                return "feat-a"
            } else if plan == planB {
                return "feat-b"
            }
            return nil
        }

        // Resolve planB by name
        let resolvedB = WorkspacePlanResolver.plan(
            forWorkspaceNamed: "feat-b",
            plans: plans,
            featureName: featureName
        )
        XCTAssertEqual(resolvedB, planB)

        // Resolve planA by name
        let resolvedA = WorkspacePlanResolver.plan(
            forWorkspaceNamed: "feat-a",
            plans: plans,
            featureName: featureName
        )
        XCTAssertEqual(resolvedA, planA)

        // Non-matching name returns nil
        let resolvedMain = WorkspacePlanResolver.plan(
            forWorkspaceNamed: "main",
            plans: plans,
            featureName: featureName
        )
        XCTAssertNil(resolvedMain)
    }

    func testResolvePlanWithEmptyPlansReturnsNil() {
        let featureName: (PlanDoc) -> String? = { _ in nil }

        let resolved = WorkspacePlanResolver.plan(
            forWorkspaceNamed: "feat-a",
            plans: [],
            featureName: featureName
        )
        XCTAssertNil(resolved)
    }
}
