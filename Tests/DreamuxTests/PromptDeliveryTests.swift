import XCTest
@testable import Dreamux

/// The whole decision table. `send` writes a `claude …` SHELL COMMAND — a
/// live agent would receive it as chat. `type` writes a bare REPL line — a
/// bare shell would EXECUTE it. Each is only ever safe in one state.
final class PromptDeliveryTests: XCTestCase {
    func testLaunchClaudeNeedsAnUnboundTab() {
        XCTAssertEqual(
            PromptDelivery.mode(intent: .launchClaude, bound: false), .launch)
    }

    func testLaunchClaudeRefusesABoundTab() {
        XCTAssertEqual(
            PromptDelivery.mode(intent: .launchClaude, bound: true), .refuse)
    }

    func testTypeIntoAgentNeedsABoundTab() {
        XCTAssertEqual(
            PromptDelivery.mode(intent: .typeIntoAgent, bound: true), .type)
    }

    func testTypeIntoAgentRefusesAnUnboundTab() {
        XCTAssertEqual(
            PromptDelivery.mode(intent: .typeIntoAgent, bound: false), .refuse)
    }

    /// A fresh tab has never bound, so a launch is allowed and a bare REPL
    /// line is refused — the end-to-end shape the callers rely on.
    @MainActor
    func testFreshTabAcceptsLaunchAndRefusesType() {
        let tab = TabSession(cwd: nil)
        XCTAssertFalse(tab.binding.isBound)
        XCTAssertFalse(ClaudePromptDriver.type("hello", into: tab),
                       "a bare REPL line into an unbound tab would be EXECUTED")
        XCTAssertTrue(ClaudePromptDriver.send("hello", into: tab))
    }
}
