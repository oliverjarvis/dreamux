import XCTest
@testable import Dreamux

@MainActor
final class TerminalThemeStoreTests: XCTestCase {
    private var sandbox: TestSandbox!
    private var suiteName: String!

    /// Notification counter. Only ever touched on the main queue, which
    /// is what makes the unchecked conformance sound.
    private final class Counter: @unchecked Sendable {
        var value = 0
    }

    override func setUpWithError() throws {
        sandbox = try TestSandbox()
        suiteName = "TerminalThemeStoreTests-\(UUID().uuidString)"
    }

    override func tearDown() {
        if let suiteName {
            UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        }
        sandbox.destroy()
        sandbox = nil
        super.tearDown()
    }

    private func makeStore() throws -> TerminalThemeStore {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return TerminalThemeStore(
            defaults: defaults,
            advancedConfURL: sandbox.root.appendingPathComponent("ghostty.conf")
        )
    }

    /// Let the ~60ms debounce settle.
    private func settleDebounce() {
        let done = expectation(description: "debounce settled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { done.fulfill() }
        wait(for: [done], timeout: 1.0)
    }

    // MARK: - persistence

    func testAbsentKeyGivesTheSeed() throws {
        let store = try makeStore()
        XCTAssertEqual(store.spec, .seed)
    }

    func testUpdatePersistsAndReloadsAcrossInstances() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let confURL = sandbox.root.appendingPathComponent("ghostty.conf")

        let first = TerminalThemeStore(defaults: defaults, advancedConfURL: confURL)
        var spec = TerminalThemeSpec.seed
        spec.dark.background = "#101010"
        first.update(spec)

        let second = TerminalThemeStore(defaults: defaults, advancedConfURL: confURL)
        XCTAssertEqual(second.spec.dark.background, "#101010")
    }

    func testGarbageInDefaultsFallsBackToTheSeed() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(Data("not json".utf8), forKey: AppearanceSettings.terminalThemeKey)
        let store = TerminalThemeStore(
            defaults: defaults,
            advancedConfURL: sandbox.root.appendingPathComponent("ghostty.conf"))
        XCTAssertEqual(store.spec, .seed)
    }

    func testUpdateSanitizesBeforeStoring() throws {
        let store = try makeStore()
        var spec = TerminalThemeSpec.seed
        spec.dark.background = "101010"
        spec.fontSize = 900
        store.update(spec)
        XCTAssertEqual(store.spec.dark.background, "#101010")
        XCTAssertEqual(store.spec.fontSize, 32)
    }

    // MARK: - notification + debounce

    func testUpdatePostsTheChangeNotification() throws {
        let store = try makeStore()
        let posted = expectation(forNotification: .terminalThemeDidChange, object: nil)
        var spec = TerminalThemeSpec.seed
        spec.fontSize = 16
        store.update(spec)
        wait(for: [posted], timeout: 1.0)
    }

    func testRapidUpdatesCoalesceIntoOnePost() throws {
        let store = try makeStore()
        let counter = Counter()
        let token = NotificationCenter.default.addObserver(
            forName: .terminalThemeDidChange, object: nil, queue: .main
        ) { _ in MainActor.assumeIsolated { counter.value += 1 } }
        defer { NotificationCenter.default.removeObserver(token) }

        for size in stride(from: 10.0, through: 20.0, by: 1.0) {
            var spec = TerminalThemeSpec.seed
            spec.fontSize = size
            store.update(spec)
        }
        settleDebounce()
        XCTAssertEqual(counter.value, 1, "a ColorPicker drag must not fan out per frame")
        XCTAssertEqual(store.spec.fontSize, 20, "the value itself is never debounced")
    }

    // MARK: - issues

    func testReportIssueSurfacesTheMessageAndNilNeverClearsIt() throws {
        let store = try makeStore()
        store.reportIssue("ghostty config diagnostics: bold-color: unknown field")
        XCTAssertEqual(
            store.lastIssue, "ghostty config diagnostics: bold-color: unknown field")
        store.reportIssue(nil)
        XCTAssertNotNil(store.lastIssue, "a healthy session must not erase another's report")
    }

    func testANewApplyCycleClearsTheLastIssue() throws {
        let store = try makeStore()
        store.reportIssue("stale")
        store.requestReapply()
        settleDebounce()
        XCTAssertNil(store.lastIssue)
    }

    // MARK: - advanced conf

    func testCompiledIgnoresAMissingConfFile() throws {
        let store = try makeStore()
        XCTAssertFalse(store.advancedConfExists)
        let compiled = store.compiled()
        XCTAssertTrue(compiled.configuration.rendered.contains("window-padding-x = 8"))
        XCTAssertFalse(compiled.configuration.rendered.contains("minimum-contrast"))
    }

    func testCompiledPicksUpConfEditsWithoutARestart() throws {
        let store = try makeStore()
        try "minimum-contrast = 1.1\n".write(
            to: store.advancedConfURL, atomically: true, encoding: .utf8)
        XCTAssertTrue(store.compiled().configuration.rendered.contains("minimum-contrast = 1.1"))

        try "scrollback-limit = 100000\n".write(
            to: store.advancedConfURL, atomically: true, encoding: .utf8)
        let rendered = store.compiled().configuration.rendered
        XCTAssertTrue(rendered.contains("scrollback-limit = 100000"))
        XCTAssertFalse(rendered.contains("minimum-contrast"))
    }

    func testCompiledCanExcludeTheConfForTheDegradePath() throws {
        let store = try makeStore()
        try "minimum-contrast = 1.1\n".write(
            to: store.advancedConfURL, atomically: true, encoding: .utf8)
        let degraded = store.compiled(includingAdvancedConf: false)
        XCTAssertFalse(degraded.configuration.rendered.contains("minimum-contrast"))
        XCTAssertTrue(degraded.configuration.rendered.contains("keybind = super+t=unbind"))
    }

    func testCreateAdvancedConfWritesTheTemplateOnceAndNeverOverwrites() throws {
        let store = try makeStore()
        try store.createAdvancedConf()
        XCTAssertTrue(store.advancedConfExists)
        let written = try String(contentsOf: store.advancedConfURL, encoding: .utf8)
        XCTAssertEqual(written, TerminalThemeStore.advancedConfTemplate)

        try "minimum-contrast = 1.1\n".write(
            to: store.advancedConfURL, atomically: true, encoding: .utf8)
        try store.createAdvancedConf()
        XCTAssertEqual(
            try String(contentsOf: store.advancedConfURL, encoding: .utf8),
            "minimum-contrast = 1.1\n",
            "Create must never clobber a file the user has edited"
        )
    }

    func testCardOpacityFromDefaultsReachesTheThemeLayer() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(0.6, forKey: AppearanceSettings.cardOpacityKey)
        let store = TerminalThemeStore(
            defaults: defaults,
            advancedConfURL: sandbox.root.appendingPathComponent("ghostty.conf"))
        XCTAssertTrue(store.compiled().theme.dark.rendered.contains("background-opacity = 0.60"))
    }
}
