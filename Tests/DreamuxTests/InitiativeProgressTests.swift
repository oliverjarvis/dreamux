import XCTest
@testable import Dreamux

/// The resolver is pure, so it is table-tested directly (mirroring
/// `PlanStatusTests`) rather than through `DocStore`. Cases cover the
/// derivation corners the plan calls out: none started, mid-family,
/// all merged, checkbox-less plans, and the empty initiative.
final class InitiativeProgressTests: XCTestCase {
    func testNoneStartedPointsAtFirstPlan() {
        let (current, label, fraction) = InitiativeProgress.resolve(
            statuses: [.ready, .ready, .ready], checked: 0, total: 30)
        XCTAssertEqual(current, 0)
        XCTAssertEqual(label, "plan 1/3")
        XCTAssertEqual(try XCTUnwrap(fraction), 0, accuracy: 0.0001)
    }

    func testMidFamilyPointsPastMergedPlans() {
        // Plans run in order: first two merged, the third is in flight.
        let (current, label, fraction) = InitiativeProgress.resolve(
            statuses: [.merged, .merged, .running], checked: 41, total: 100)
        XCTAssertEqual(current, 2)
        XCTAssertEqual(label, "plan 3/3")
        XCTAssertEqual(try XCTUnwrap(fraction), 0.41, accuracy: 0.0001)
    }

    /// Defensive: `current` is the *first* non-merged plan even when a
    /// later plan is already merged out of order.
    func testCurrentIsFirstNonMergedEvenAfterAGap() {
        let (current, label, _) = InitiativeProgress.resolve(
            statuses: [.merged, .inProgress, .merged], checked: 5, total: 10)
        XCTAssertEqual(current, 1)
        XCTAssertEqual(label, "plan 2/3")
    }

    func testAllMergedIsDone() {
        let (current, label, fraction) = InitiativeProgress.resolve(
            statuses: [.merged, .merged], checked: 60, total: 60)
        XCTAssertNil(current)
        XCTAssertEqual(label, "done")
        XCTAssertEqual(try XCTUnwrap(fraction), 1, accuracy: 0.0001)
    }

    /// A single-plan initiative resolves to `plan 1/1`; the caller elides
    /// the label but the resolver must still be correct.
    func testSinglePlanResolvesToOneOfOne() {
        let (current, label, _) = InitiativeProgress.resolve(
            statuses: [.running], checked: 3, total: 10)
        XCTAssertEqual(current, 0)
        XCTAssertEqual(label, "plan 1/1")
    }

    func testEmptyStepPlansHaveNoFraction() {
        // Plans without checkboxes have no meaningful percentage.
        let (current, label, fraction) = InitiativeProgress.resolve(
            statuses: [.running, .ready], checked: 0, total: 0)
        XCTAssertEqual(current, 0)
        XCTAssertEqual(label, "plan 1/2")
        XCTAssertNil(fraction)
    }

    /// An empty initiative has no plan in flight; the vacuous all-merged
    /// case reads `done`, same as a fully merged family.
    func testEmptyInitiativeIsVacuouslyDone() {
        let (current, label, fraction) = InitiativeProgress.resolve(
            statuses: [], checked: 0, total: 0)
        XCTAssertNil(current)
        XCTAssertEqual(label, "done")
        XCTAssertNil(fraction)
    }
}
