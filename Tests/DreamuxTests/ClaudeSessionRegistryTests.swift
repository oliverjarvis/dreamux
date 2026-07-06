import XCTest
@testable import Dreamux

final class ClaudeSessionRegistryTests: XCTestCase {
    var sandbox: TestSandbox!

    override func setUpWithError() throws { sandbox = try TestSandbox() }
    override func tearDown() { sandbox.destroy(); sandbox = nil }

    private func writeSession(_ name: String, _ json: String) throws {
        let dir = sandbox.root.appendingPathComponent("claude-home/sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try json.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    private var home: URL { sandbox.root.appendingPathComponent("claude-home", isDirectory: true) }

    func testClaudeHomeDefaultsAndOverride() {
        let def = ClaudeHome.root(environment: [:])
        XCTAssertEqual(def.path, NSString(string: "~/.claude").expandingTildeInPath)
        let overridden = ClaudeHome.root(environment: ["DREAMUX_CLAUDE_HOME": "/tmp/fake-claude"])
        XCTAssertEqual(overridden.path, "/tmp/fake-claude")
    }

    func testReadsWellFormedEntries() throws {
        try writeSession("101.json", #"""
        {"pid":101,"sessionId":"aaa-bbb","cwd":"/Users/x/proj/features/auth","startedAt":"x",
         "version":"2.1.201","kind":"interactive","name":"clayspace-ba","status":"busy","updatedAt":123}
        """#)
        try writeSession("102.json", #"""
        {"pid":102,"sessionId":"ccc-ddd","cwd":"/Users/x/other","kind":"bg","status":"idle"}
        """#)
        let reader = ClaudeSessionRegistryReader(home: home, isAlive: { _ in true })
        let entries = reader.entries().sorted { $0.pid < $1.pid }
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].sessionId, "aaa-bbb")
        XCTAssertEqual(entries[0].flowStatus, .running)
        XCTAssertEqual(entries[0].name, "clayspace-ba")
        XCTAssertFalse(entries[0].isBackground)
        XCTAssertTrue(entries[1].isBackground)
        XCTAssertEqual(entries[1].flowStatus, .done) // idle → done ("nothing in flight")
        XCTAssertNil(entries[1].name)
    }

    func testStatusMapping() throws {
        try writeSession("7.json", #"{"pid":7,"sessionId":"s","cwd":"/x","kind":"interactive","status":"waiting"}"#)
        let reader = ClaudeSessionRegistryReader(home: home, isAlive: { _ in true })
        XCTAssertEqual(reader.entries().first?.flowStatus, .waiting)
    }

    func testSkipsMalformedAndDeadEntries() throws {
        try writeSession("1.json", #"{"pid":1,"sessionId":"live","cwd":"/x","kind":"interactive","status":"busy"}"#)
        try writeSession("2.json", #"{"pid":2,"sessionId":"dead","cwd":"/x","kind":"interactive","status":"busy"}"#)
        try writeSession("3.json", "not json at all {")
        try writeSession("4.json", #"{"sessionId":"missing-pid"}"#)
        let reader = ClaudeSessionRegistryReader(home: home, isAlive: { pid in pid == 1 })
        let entries = reader.entries()
        XCTAssertEqual(entries.map(\.sessionId), ["live"])
    }

    func testMissingSessionsDirYieldsEmpty() {
        let reader = ClaudeSessionRegistryReader(home: home, isAlive: { _ in true })
        XCTAssertEqual(reader.entries(), [])
    }

    func testProjectSlugReplacesEveryNonAlphanumericCharacter() {
        XCTAssertEqual(ClaudeHome.projectSlug(forCwd: "/Users/x/dev.app/y"), "-Users-x-dev-app-y")
    }

    func testTranscriptURLComposesHomeSlugAndSession() {
        let fakeHome = URL(fileURLWithPath: "/fake/home", isDirectory: true)
        let url = ClaudeHome.transcriptURL(home: fakeHome, cwd: "/Users/x/proj", sessionID: "sess-1")
        XCTAssertEqual(url.path, "/fake/home/projects/-Users-x-proj/sess-1.jsonl")
    }

    func testSubagentsDirURLComposesHomeSlugAndSession() {
        let fakeHome = URL(fileURLWithPath: "/fake/home", isDirectory: true)
        let url = ClaudeHome.subagentsDirURL(home: fakeHome, cwd: "/Users/x/proj", sessionID: "sess-1")
        XCTAssertEqual(url.path, "/fake/home/projects/-Users-x-proj/sess-1/subagents")
    }
}
