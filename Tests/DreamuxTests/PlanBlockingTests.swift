// Tests/DreamuxTests/PlanBlockingTests.swift
import XCTest
@testable import Dreamux

final class PlanBlockingTests: XCTestCase {
    private func plan(_ name: String, runsAfter: String? = nil) -> PlanDoc {
        PlanDoc(fileURL: URL(fileURLWithPath: "/p/\(name).md"), kind: .plan,
                title: name, date: nil, goal: nil, specReference: nil,
                runsAfter: runsAfter, declaresParallel: false,
                checkedSteps: 0, totalSteps: 1, tasks: [])
    }

    func testWaitingReturnsBlocker() {
        let blocker = plan("a")
        let waiter = plan("b", runsAfter: "docs/plans/a.md")
        let result = PlanBlocking.blocker(
            for: waiter, status: .ready,
            resolveBlocker: { _ in blocker }, statusOf: { _ in .running })
        XCTAssertEqual(result, PlanBlocking.Blocker(title: "a", fileURL: blocker.fileURL))
    }
    func testMergedBlockerIsNil() {
        let blocker = plan("a"); let waiter = plan("b", runsAfter: "docs/plans/a.md")
        XCTAssertNil(PlanBlocking.blocker(for: waiter, status: .ready,
            resolveBlocker: { _ in blocker }, statusOf: { _ in .merged }))
    }
    func testWaiterNotReadyIsNil() {
        let blocker = plan("a"); let waiter = plan("b", runsAfter: "docs/plans/a.md")
        for s in [PlanStatus.running, .inProgress, .awaitingReview, .merged, .specOnly] {
            XCTAssertNil(PlanBlocking.blocker(for: waiter, status: s,
                resolveBlocker: { _ in blocker }, statusOf: { _ in .running }))
        }
    }
    func testNoRunsAfterIsNil() {
        let waiter = plan("b")
        XCTAssertNil(PlanBlocking.blocker(for: waiter, status: .ready,
            resolveBlocker: { _ in nil }, statusOf: { _ in .running }))
    }
    func testUnresolvableBlockerIsNil() {
        let waiter = plan("b", runsAfter: "docs/plans/missing.md")
        XCTAssertNil(PlanBlocking.blocker(for: waiter, status: .ready,
            resolveBlocker: { _ in nil }, statusOf: { _ in .running }))
    }
    func testSelfReferenceIsNil() {
        let waiter = plan("b", runsAfter: "docs/plans/b.md")
        XCTAssertNil(PlanBlocking.blocker(for: waiter, status: .ready,
            resolveBlocker: { _ in waiter }, statusOf: { _ in .running }))
    }
}
