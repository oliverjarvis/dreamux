import XCTest
@testable import Dreamux

/// The header popover's "logs" button focuses SignalsView on one
/// runner. Sources are `name` or `name:branch` depending on how many
/// branches ever emitted (RunnerManager.signalSource), so the match is
/// name-or-prefix — and must not swallow *other* runners that merely
/// share a name prefix.
@MainActor
final class SignalSourceFocusTests: XCTestCase {

    func testMatchesBareNameAndBranchVariants() {
        let sources = ["web", "web:feat", "web:main", "api"]
        XCTAssertEqual(
            SignalStore.sourcesMatching(focus: "web", in: sources),
            ["web", "web:feat", "web:main"])
    }

    func testPrefixWithoutColonIsNotAMatch() {
        XCTAssertEqual(
            SignalStore.sourcesMatching(focus: "web", in: ["webapp", "web:feat"]),
            ["web:feat"],
            "'webapp' shares a prefix but is a different runner")
    }

    /// Focusing before the runner ever logged: fall back to the bare
    /// name so the chip exists and lights up when lines arrive.
    func testNoKnownSourcesFallsBackToFocusName() {
        XCTAssertEqual(
            SignalStore.sourcesMatching(focus: "web", in: ["api"]),
            ["web"])
    }
}
