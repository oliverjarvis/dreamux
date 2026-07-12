import XCTest
@testable import Dreamux

@MainActor
final class PRStatusPollerTests: XCTestCase {
    private final class Recorder: @unchecked Sendable { var features: [String] = [] }

    func testPollOnceFetchesOnlyTrackedAndPublishes() async {
        let rec = Recorder()
        var published: [String: PRStatusStore.Entry] = [:]
        let poller = PRStatusPoller(
            tracked: { [(feature: "feat-a", worktreeURL: URL(fileURLWithPath: "/a"))] },
            fetch: { feature, _ in rec.features.append(feature); return .init(lifecycle: .approved, url: "u-\(feature)") },
            onSnapshot: { published = $0 })
        await poller.pollOnce()
        XCTAssertEqual(rec.features, ["feat-a"])
        XCTAssertEqual(published["feat-a"], .init(lifecycle: .approved, url: "u-feat-a"))
    }

    func testPollOnceWithNothingTrackedNeverFetches() async {
        let rec = Recorder()
        let poller = PRStatusPoller(
            tracked: { [] },
            fetch: { feature, _ in rec.features.append(feature); return nil },
            onSnapshot: { _ in })
        await poller.pollOnce()
        XCTAssertTrue(rec.features.isEmpty)   // non-spammy invariant
    }

    func testPollOnceSkipsFeaturesFetchReturnsNilFor() async {
        var published: [String: PRStatusStore.Entry] = [:]
        let poller = PRStatusPoller(
            tracked: { [(feature: "a", worktreeURL: URL(fileURLWithPath: "/a")),
                        (feature: "b", worktreeURL: URL(fileURLWithPath: "/b"))] },
            fetch: { feature, _ in feature == "a" ? .init(lifecycle: .open, url: "ua") : nil },
            onSnapshot: { published = $0 })
        await poller.pollOnce()
        XCTAssertEqual(Set(published.keys), ["a"])
    }
}
