import XCTest
@testable import Dreamux

@MainActor
final class PRStatusStoreTests: XCTestCase {
    func testTrackRegistersFeatureForPolling() {
        let store = PRStatusStore()
        store.track(feature: "feat-a", worktreeURL: URL(fileURLWithPath: "/wt/a"))
        XCTAssertEqual(store.trackedFeatures.map(\.feature), ["feat-a"])
        XCTAssertNil(store.state(for: "feat-a"))   // tracked but not yet polled
    }
    func testApplyPublishesStateKeyedByFeature() {
        let store = PRStatusStore()
        store.apply(["feat-a": .init(lifecycle: .approved, url: "u-a")])
        XCTAssertEqual(store.state(for: "feat-a"), .init(lifecycle: .approved, url: "u-a"))
    }
    func testApplyMergesWithoutClobberingAbsentFeatures() {
        let store = PRStatusStore()
        store.apply(["a": .init(lifecycle: .open, url: "ua")])
        store.apply(["b": .init(lifecycle: .merged, url: "ub")])   // a not in this snapshot
        XCTAssertEqual(store.state(for: "a")?.lifecycle, .open)     // preserved
        XCTAssertEqual(store.state(for: "b")?.lifecycle, .merged)
    }
    func testUntrackDropsTrackingAndState() {
        let store = PRStatusStore()
        store.track(feature: "a", worktreeURL: URL(fileURLWithPath: "/wt/a"))
        store.apply(["a": .init(lifecycle: .open, url: "u")])
        store.untrack(feature: "a")
        XCTAssertTrue(store.trackedFeatures.isEmpty)
        XCTAssertNil(store.state(for: "a"))
    }
}
