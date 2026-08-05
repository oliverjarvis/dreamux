import XCTest
@testable import Dreamux

/// `TabSession()` constructs headless — no PTY started, no view hosted —
/// which is established practice (see `ChatInputGatingTests`). These
/// tests assert on the config the controller actually accepted.
@MainActor
final class TabSessionThemeTests: XCTestCase {
    private var sandbox: TestSandbox!
    private var suiteName: String!
    private var savedStore: TerminalThemeStore!

    // Reaching these @MainActor stored properties (and
    // TerminalThemeStore.shared) from XCTest's nonisolated
    // setUp/tearDown overrides warns under Swift 6. Wrapping the bodies
    // in MainActor.assumeIsolated does NOT help — it sends `self` across
    // the boundary, which is a hard error. Every @MainActor XCTestCase in
    // this target carries the same warnings (see
    // PlanQueueControllerTests); the app target itself builds clean.
    override func setUpWithError() throws {
        sandbox = try TestSandbox()
        suiteName = "TabSessionThemeTests-\(UUID().uuidString)"
        savedStore = TerminalThemeStore.shared
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        TerminalThemeStore.shared = TerminalThemeStore(
            defaults: defaults,
            advancedConfURL: sandbox.root.appendingPathComponent("ghostty.conf")
        )
    }

    override func tearDown() {
        TerminalThemeStore.shared = savedStore
        if let suiteName {
            UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        }
        sandbox.destroy()
        sandbox = nil
        super.tearDown()
    }

    private func writeAdvancedConf(_ text: String) throws {
        try text.write(
            to: TerminalThemeStore.shared.advancedConfURL,
            atomically: true, encoding: .utf8)
    }

    func testFreshSessionAppliesTheStoreThemeCleanly() {
        let tab = TabSession()
        XCTAssertNil(tab.viewState.controller.lastConfigurationIssue)
        let rendered = tab.viewState.renderedConfig
        XCTAssertTrue(rendered.contains("background = #282C34"))
        XCTAssertTrue(rendered.contains("palette = 0=#1D1F21"))
        XCTAssertTrue(rendered.contains("keybind = super+t=unbind"))
        XCTAssertTrue(rendered.contains("window-padding-x = 8"))
        XCTAssertNil(TerminalThemeStore.shared.lastIssue)
    }

    func testEditedSpecReachesAnAlreadyOpenSession() {
        let tab = TabSession()
        var spec = TerminalThemeSpec.seed
        spec.dark.background = "#101010"
        spec.light.background = "#101010"
        TerminalThemeStore.shared.update(spec)
        // Apply directly rather than waiting on the debounced post — the
        // notification path is covered by TerminalThemeStoreTests.
        tab.applyThemeFromStore()
        XCTAssertNil(tab.viewState.controller.lastConfigurationIssue)
        XCTAssertTrue(tab.viewState.renderedConfig.contains("background = #101010"))
    }

    func testAValidAdvancedConfIsAppliedBelowTheTheme() throws {
        try writeAdvancedConf("minimum-contrast = 1.1\n")
        let tab = TabSession()
        XCTAssertNil(tab.viewState.controller.lastConfigurationIssue)
        XCTAssertTrue(tab.viewState.renderedConfig.contains("minimum-contrast = 1.1"))
    }

    func testABadAdvancedConfDegradesToTheThemeWithoutLosingIt() throws {
        try writeAdvancedConf("not-a-real-key = 1\n")
        let tab = TabSession()
        // Step 1 of the ladder: the user's file is dropped…
        XCTAssertNil(tab.viewState.controller.lastConfigurationIssue)
        let rendered = tab.viewState.renderedConfig
        XCTAssertFalse(rendered.contains("not-a-real-key"))
        // …and everything that matters survives.
        XCTAssertTrue(rendered.contains("background = #282C34"))
        XCTAssertTrue(rendered.contains("palette = 0=#1D1F21"))
        XCTAssertTrue(rendered.contains("keybind = super+t=unbind"),
                      "dropping the whole configuration layer would break Cmd+T")
        // The user is told which file cost them the escape hatch.
        let issue = TerminalThemeStore.shared.lastIssue
        XCTAssertNotNil(issue)
        XCTAssertTrue(issue?.contains("not-a-real-key") == true)
    }

    func testABadAdvancedConfEditIsSurvivedByALiveSessionToo() throws {
        let tab = TabSession()
        try writeAdvancedConf("background = notacolor\n")
        tab.applyThemeFromStore()
        // NOT asserted here: `controller.lastConfigurationIssue == nil`.
        // `applyResolvedConfig` skips its `applyState()` when ghostty
        // rejects a config, so the controller keeps the good
        // configuration it already had — which means step 1 of the ladder
        // (drop the conf) is byte-identical to what is already installed
        // and there is nothing left to push. The flag ghostty set on the
        // failed attempt is `internal(set)`, so no app code can clear it.
        // The session is healthy regardless, and that is what these three
        // assertions check. A fresh session degrading at construction
        // DOES clear it — `TerminalController.init` assigns its state
        // fields before validating, so its step 1 really does differ; see
        // testABadAdvancedConfDegradesToTheThemeWithoutLosingIt.
        let rendered = tab.viewState.renderedConfig
        XCTAssertFalse(rendered.contains("notacolor"), "the bad conf line is dropped")
        // The whole theme survives — a typo'd ghostty.conf costs the
        // escape hatch, never the palette, font or cursor.
        XCTAssertTrue(rendered.contains("background = #282C34"))
        XCTAssertTrue(rendered.contains("palette = 0=#1D1F21"))
        XCTAssertTrue(rendered.contains("keybind = super+t=unbind"))
        // …and the user is told which file cost them the escape hatch.
        XCTAssertNotNil(TerminalThemeStore.shared.lastIssue)
        XCTAssertTrue(
            TerminalThemeStore.shared.lastIssue?.contains("notacolor") == true)
    }

    func testReapplyingAnUnchangedThemeIsANoOpAndReportsNothing() {
        let tab = TabSession()
        tab.applyThemeFromStore()
        tab.applyThemeFromStore()
        XCTAssertNil(tab.viewState.controller.lastConfigurationIssue)
        XCTAssertNil(TerminalThemeStore.shared.lastIssue)
    }
}
