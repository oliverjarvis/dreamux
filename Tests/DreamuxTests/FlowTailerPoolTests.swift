import XCTest
@testable import Dreamux

@MainActor
final class FlowTailerPoolTests: XCTestCase {
    var sandbox: TestSandbox!
    var home: URL { sandbox.root.appendingPathComponent("claude-home", isDirectory: true) }

    override func setUpWithError() throws { sandbox = try TestSandbox() }
    override func tearDown() { sandbox.destroy(); sandbox = nil }

    // MARK: - Helpers

    private func entry(session: String = "s1", cwd: String, status: String = "busy") -> ClaudeSessionEntry {
        let json = """
        {"pid":1,"sessionId":"\(session)","cwd":"\(cwd)","status":"\(status)","kind":"interactive"}
        """
        return try! JSONDecoder().decode(ClaudeSessionEntry.self, from: Data(json.utf8))
    }

    @discardableResult
    private func writeTranscript(_ lines: [String], cwd: String, sessionID: String) throws -> URL {
        let url = ClaudeHome.transcriptURL(home: home, cwd: cwd, sessionID: sessionID)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let content = lines.map { $0 + "\n" }.joined()
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func append(_ s: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        handle.write(s.data(using: .utf8)!)
    }

    private func makePool(
        onTranscriptLines: @escaping (String, [String]) -> Void = { _, _ in },
        onAgentLines: @escaping (String, String, [String]) -> Void = { _, _, _ in },
        onMeta: @escaping (String, SubagentMeta) -> Void = { _, _ in }
    ) -> FlowTailerPool {
        FlowTailerPool(
            home: home, onTranscriptLines: onTranscriptLines, onAgentLines: onAgentLines, onMeta: onMeta)
    }

    // MARK: - Hot-set reconcile

    func testReconcileStartsHotSessionAndDeliversTranscriptLinesOnMain() throws {
        let cwd = "/Users/x/proj"
        let sessionID = "s1"
        let url = try writeTranscript([], cwd: cwd, sessionID: sessionID)

        var receivedLines: [String] = []
        var deliveredOnMain = false
        let exp = expectation(description: "appended line arrives")
        let pool = makePool(onTranscriptLines: { sid, lines in
            deliveredOnMain = Thread.isMainThread
            guard sid == sessionID else { return }
            receivedLines.append(contentsOf: lines)
            exp.fulfill()
        })

        pool.reconcile(hot: [entry(session: sessionID, cwd: cwd)])
        XCTAssertTrue(pool.activeSessionIDs.contains(sessionID))

        // `reconcile` calls `start(replayExisting: false)` synchronously
        // (see FlowTailerPool's decision 1), so the EOF baseline is
        // already established by the time `reconcile` returns —
        // appending immediately afterward is not racy.
        try append("hello\n", to: url)

        wait(for: [exp], timeout: 3)
        XCTAssertTrue(deliveredOnMain)
        XCTAssertEqual(receivedLines, ["hello"])
    }

    func testReconcileWithEmptyHotSetClearsActiveSessionIDs() throws {
        let cwd = "/Users/x/proj"
        let sessionID = "s1"
        try writeTranscript([], cwd: cwd, sessionID: sessionID)

        let pool = makePool()
        pool.reconcile(hot: [entry(session: sessionID, cwd: cwd)])
        XCTAssertTrue(pool.activeSessionIDs.contains(sessionID))

        pool.reconcile(hot: [])
        XCTAssertTrue(pool.activeSessionIDs.isEmpty)
    }

    func testAppendAfterHotSetDepartureDeliversNothing() throws {
        let cwd = "/Users/x/proj"
        let sessionID = "s1"
        let url = try writeTranscript([], cwd: cwd, sessionID: sessionID)

        var deliveries = 0
        let noDelivery = expectation(description: "nothing delivered after stop")
        noDelivery.isInverted = true
        let pool = makePool(onTranscriptLines: { _, _ in
            deliveries += 1
            noDelivery.fulfill()
        })

        pool.reconcile(hot: [entry(session: sessionID, cwd: cwd)])
        pool.reconcile(hot: []) // stop() runs synchronously — no race with the append below

        try append("late\n", to: url)
        wait(for: [noDelivery], timeout: 0.5)
        XCTAssertEqual(deliveries, 0)
    }

    func testSteadyStateReconcileDoesNotRestartAlreadyHotSession() throws {
        // A restart would re-establish a fresh EOF baseline and could
        // reset the tailer's incremental offset — reconcile must leave
        // an already-hot session alone on every subsequent poll.
        let cwd = "/Users/x/proj"
        let sessionID = "s1"
        let url = try writeTranscript([], cwd: cwd, sessionID: sessionID)

        var receivedLines: [String] = []
        let exp = expectation(description: "line arrives exactly once")
        let pool = makePool(onTranscriptLines: { _, lines in
            receivedLines.append(contentsOf: lines)
            exp.fulfill()
        })

        pool.reconcile(hot: [entry(session: sessionID, cwd: cwd)])
        pool.reconcile(hot: [entry(session: sessionID, cwd: cwd)]) // steady-state poll, same entry

        try append("once\n", to: url)
        wait(for: [exp], timeout: 3)
        XCTAssertEqual(receivedLines, ["once"])
    }

    // MARK: - Dormant tailer revival

    /// A session can appear in the registry (and so enter the hot set)
    /// before claude has flushed its transcript file to disk — the
    /// tailer's first `start()` finds nothing to open, exhausts its one
    /// reopen retry, and goes dormant (`ClaudeTranscriptTailer.isDormant`).
    /// Without `reconcile` reviving it, that session's activity would
    /// never be tailed for the rest of its life even once the file
    /// shows up. This is a steady-state poll (same entry, already hot)
    /// — not a fresh activation — so it exercises the exact case
    /// `testSteadyStateReconcileDoesNotRestartAlreadyHotSession` must
    /// keep passing unmodified: only a dormant tailer gets kicked, a
    /// healthy one is left alone.
    func testDormantTailerRevivesOnNextReconcileOnceFileExists() throws {
        let cwd = "/Users/x/proj"
        let sessionID = "s1"
        // No transcript file yet — `sessionState(for:cwd:)` still builds
        // a tailer against the path it WOULD live at.

        var receivedLines: [String] = []
        let exp = expectation(description: "line arrives once the file exists and reconcile revives the tailer")
        let pool = makePool(onTranscriptLines: { sid, lines in
            guard sid == sessionID else { return }
            receivedLines.append(contentsOf: lines)
            exp.fulfill()
        })

        pool.reconcile(hot: [entry(session: sessionID, cwd: cwd)])
        XCTAssertTrue(pool.activeSessionIDs.contains(sessionID))

        // The file appears only now — the real-world equivalent of
        // claude not having flushed it yet when the session first
        // showed up in the registry.
        try writeTranscript(["hello"], cwd: cwd, sessionID: sessionID)

        // Same hot set, same session — a steady-state poll, not a fresh
        // activation — must still revive the dormant tailer.
        pool.reconcile(hot: [entry(session: sessionID, cwd: cwd)])

        wait(for: [exp], timeout: 3)
        XCTAssertEqual(receivedLines, ["hello"])
    }

    // MARK: - Subagent metas + agent tailers

    func testMetaFileDroppedIntoSubagentsDirFiresOnMeta() throws {
        let cwd = "/Users/x/proj"
        let sessionID = "s1"
        try writeTranscript([], cwd: cwd, sessionID: sessionID)
        let subagentsDir = ClaudeHome.subagentsDirURL(home: home, cwd: cwd, sessionID: sessionID)
        try FileManager.default.createDirectory(at: subagentsDir, withIntermediateDirectories: true)

        var receivedMetas: [SubagentMeta] = []
        let exp = expectation(description: "meta arrives")
        let pool = makePool(onMeta: { sid, meta in
            guard sid == sessionID else { return }
            receivedMetas.append(meta)
            exp.fulfill()
        })

        pool.reconcile(hot: [entry(session: sessionID, cwd: cwd)])

        let metaURL = subagentsDir.appendingPathComponent("agent-a1.meta.json")
        try #"{"agentType":"Explore","description":"map repo","toolUseId":"tu1","spawnDepth":1}"#
            .write(to: metaURL, atomically: true, encoding: .utf8)

        wait(for: [exp], timeout: 3)
        XCTAssertEqual(receivedMetas.first?.agentID, "a1")
        XCTAssertEqual(receivedMetas.first?.agentType, "Explore")
        XCTAssertEqual(receivedMetas.first?.toolUseID, "tu1")
    }

    func testExistingAgentJSONLIsTailedAndActivityArrivesOnMain() throws {
        let cwd = "/Users/x/proj"
        let sessionID = "s1"
        try writeTranscript([], cwd: cwd, sessionID: sessionID)
        let subagentsDir = ClaudeHome.subagentsDirURL(home: home, cwd: cwd, sessionID: sessionID)
        try FileManager.default.createDirectory(at: subagentsDir, withIntermediateDirectories: true)
        let agentURL = subagentsDir.appendingPathComponent("agent-a1.jsonl")
        FileManager.default.createFile(atPath: agentURL.path, contents: nil)

        var receivedOnMain = false
        var receivedLines: [String] = []
        let exp = expectation(description: "agent line arrives")
        let pool = makePool(onAgentLines: { sid, agentID, lines in
            receivedOnMain = Thread.isMainThread
            guard sid == sessionID, agentID == "a1" else { return }
            receivedLines.append(contentsOf: lines)
            exp.fulfill()
        })

        pool.reconcile(hot: [entry(session: sessionID, cwd: cwd)])
        // The initial scan (triggered right after `reconcile` sets up
        // the watcher) discovers `agent-a1.jsonl` and starts tailing it
        // from EOF (hot, not lazy) — give it a moment to spawn, then
        // append.
        let spawned = expectation(description: "agent tailer spawned")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { spawned.fulfill() }
        wait(for: [spawned], timeout: 1)

        try append("agent-line\n", to: agentURL)
        wait(for: [exp], timeout: 3)
        XCTAssertTrue(receivedOnMain)
        XCTAssertEqual(receivedLines, ["agent-line"])
    }

    // MARK: - Lazy (zoom) tail

    func testEnsureLazyTailOnColdSessionReplaysExistingLinesFromZero() throws {
        let cwd = "/Users/x/proj"
        let sessionID = "s1"
        try writeTranscript(["one", "two", "three"], cwd: cwd, sessionID: sessionID)

        var receivedLines: [String] = []
        let exp = expectation(description: "all 3 pre-existing lines replayed")
        let pool = makePool(onTranscriptLines: { sid, lines in
            guard sid == sessionID else { return }
            receivedLines.append(contentsOf: lines)
            if receivedLines.count >= 3 { exp.fulfill() }
        })

        // Never reconciled hot — this session is cold.
        pool.ensureLazyTail(sessionID: sessionID, cwd: cwd)
        XCTAssertTrue(pool.activeSessionIDs.contains(sessionID))

        wait(for: [exp], timeout: 3)
        XCTAssertEqual(receivedLines, ["one", "two", "three"])
    }

    func testReleaseLazyTailOnColdSessionStopsDelivery() throws {
        let cwd = "/Users/x/proj"
        let sessionID = "s1"
        let url = try writeTranscript(["one"], cwd: cwd, sessionID: sessionID)

        var deliveries = 0
        var noMore: XCTestExpectation?
        let gotInitial = expectation(description: "initial replay arrives")
        let pool = makePool(onTranscriptLines: { _, _ in
            deliveries += 1
            gotInitial.fulfill()
            noMore?.fulfill()
        })

        pool.ensureLazyTail(sessionID: sessionID, cwd: cwd)
        wait(for: [gotInitial], timeout: 3)
        let before = deliveries

        // `releaseLazyTail` on a purely-lazy (never hot) session calls
        // `stopSession` directly and synchronously (see FlowTailerPool's
        // decision 1) — no settling wait needed before the append below.
        pool.releaseLazyTail(sessionID: sessionID)
        XCTAssertTrue(pool.activeSessionIDs.isEmpty)

        let noMoreExp = expectation(description: "nothing more delivered")
        noMoreExp.isInverted = true
        noMore = noMoreExp
        try append("two\n", to: url)
        wait(for: [noMoreExp], timeout: 0.5)
        XCTAssertEqual(deliveries, before)
    }

    func testLazyTailOnHotSessionSurvivesReleaseWhileStillHot() throws {
        let cwd = "/Users/x/proj"
        let sessionID = "s1"
        let url = try writeTranscript([], cwd: cwd, sessionID: sessionID)

        var receivedLines: [String] = []
        let exp = expectation(description: "post-release line still arrives (still hot)")
        let pool = makePool(onTranscriptLines: { sid, lines in
            guard sid == sessionID else { return }
            receivedLines.append(contentsOf: lines)
            if receivedLines.contains("still-hot") { exp.fulfill() }
        })

        pool.reconcile(hot: [entry(session: sessionID, cwd: cwd)])
        pool.ensureLazyTail(sessionID: sessionID, cwd: cwd)
        pool.releaseLazyTail(sessionID: sessionID) // still hot — must not stop tailing

        XCTAssertTrue(pool.activeSessionIDs.contains(sessionID))
        try append("still-hot\n", to: url)

        wait(for: [exp], timeout: 3)
    }
}
