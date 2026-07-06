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

    /// Waits until `pool.pendingScanCount` reads 0 — a dir-event-driven
    /// scan is asynchronous (see `FlowTailerPool.scanSubagentsDir`) with
    /// no other signal a test can observe, so anything that checks state
    /// a scan would affect (`liveAgentTailerIDs`, `metaParseCount`, …)
    /// must wait for this first, or it's reading stale state from before
    /// the scan landed. Polls via `wait(for:)` — XCTest's own
    /// run-loop-pumping primitive, used everywhere else in this file.
    ///
    /// The first tick always runs before ever consulting
    /// `pendingScanCount`: a just-created file's dir-level kqueue event
    /// hasn't necessarily been delivered yet (delivery itself requires
    /// the run loop to turn), so the counter can still read 0 even
    /// though a scan is about to be dispatched — checking it before any
    /// pumping at all would exit immediately and drain nothing.
    private func waitUntilScansSettle(_ pool: FlowTailerPool, timeout: TimeInterval = 5) {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            let tick = expectation(description: "scan settle poll tick")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { tick.fulfill() }
            wait(for: [tick], timeout: 1)
        } while pool.pendingScanCount > 0 && Date() < deadline
        XCTAssertEqual(pool.pendingScanCount, 0, "scans did not settle within \(timeout)s")
    }

    private func makePool(
        onTranscriptLines: @escaping (String, [String]) -> Void = { _, _ in },
        onAgentLines: @escaping (String, String, [String]) -> Void = { _, _, _ in },
        onMeta: @escaping (String, SubagentMeta) -> Void = { _, _ in },
        onDroppedBytes: ((String) -> Void)? = nil
    ) -> FlowTailerPool {
        FlowTailerPool(
            home: home, onTranscriptLines: onTranscriptLines, onAgentLines: onAgentLines, onMeta: onMeta,
            onDroppedBytes: onDroppedBytes)
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

    /// The pool's own `onDroppedBytes(sessionID:)` — plumbed from
    /// `ClaudeTranscriptTailer.onDroppedBytes` via
    /// `droppedBytesCallback`/`handleDroppedBytes` — must fire with the
    /// session's ID once its transcript tailer hits the partial-buffer
    /// cap. This is the right test depth for the callback BOUNDARY: the
    /// further one-line hop from here into `FlowStore.noteSkippedLines`
    /// lives in `ProjectSession.swift`'s pool construction, which is
    /// simple enough (and awkward to unit-test in isolation, given
    /// `ProjectSession`'s own construction cost) to trust by inspection
    /// rather than duplicate here.
    func testTailerCapOverflowFiresPoolOnDroppedBytesWithSessionID() throws {
        let cwd = "/Users/x/proj"
        let sessionID = "s1"
        let url = try writeTranscript([], cwd: cwd, sessionID: sessionID)

        var receivedLines: [String] = []
        var droppedSessionIDs: [String] = []
        let exp = expectation(description: "normal line after the overflow arrives")
        let pool = makePool(
            onTranscriptLines: { sid, lines in
                guard sid == sessionID else { return }
                receivedLines.append(contentsOf: lines)
                if receivedLines.contains("normal1") { exp.fulfill() }
            },
            onDroppedBytes: { sid in
                droppedSessionIDs.append(sid)
            }
        )

        pool.reconcile(hot: [entry(session: sessionID, cwd: cwd)])
        XCTAssertTrue(pool.activeSessionIDs.contains(sessionID))

        // Same shape as `ClaudeTranscriptTailerTests
        // .testCapOverflowDropsRemainderNotCompleteLines` — a run of
        // non-newline bytes over the 1 MB cap, followed by its own
        // terminator and a normal line, all written before the
        // tailer's wake fires.
        let giantUnterminatedLine = String(repeating: "x", count: 1_200_000)
        try append(giantUnterminatedLine + "\nnormal1\n", to: url)

        wait(for: [exp], timeout: 3)
        XCTAssertEqual(droppedSessionIDs, [sessionID])
        XCTAssertEqual(receivedLines, ["normal1"])
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

    // MARK: - Agent tailer fd cap

    /// A real-world session directory has been observed with 219
    /// subagent files — tailing all of them would exhaust the process'
    /// fd budget (see `FlowTailerPool.maxAgentTailersPerSession`'s doc).
    /// Stages `cap + 4` agent files with deterministic, strictly
    /// increasing mtimes, ALL present before the first scan, and
    /// confirms: (1) live tailers are capped at 24, (2) the live set is
    /// exactly the 24 newest-by-mtime files, (3) meta parsing/emission
    /// — NOT subject to the cap — still covers every file, and (4) a
    /// file that ranks below the cap on that first scan is never
    /// delivered from.
    ///
    /// Because every file arrives together in a single scan,
    /// `liveAgentTailerIDs` starts empty and `enforceAgentTailerCap`'s
    /// demote branch (which calls `stop()` on a tailer dropping OUT of
    /// an already-live set) never actually runs here — the
    /// bottom-ranked files are simply never promoted to live in the
    /// first place, so (4) confirms they were never started, not that
    /// a running tailer got `stop()`ped mid-life.
    /// `testTwoScanRescanDemotesGenuinelyRunningAgentTailer` below is
    /// what exercises the demote-and-`stop()` path proper, with a
    /// tailer genuinely live before a later rescan drops it.
    func testAgentTailerLiveCountIsCappedToNewestByMTimeWhileMetaCoversAll() throws {
        let cwd = "/Users/x/proj"
        let sessionID = "s1"
        try writeTranscript([], cwd: cwd, sessionID: sessionID)
        let subagentsDir = ClaudeHome.subagentsDirURL(home: home, cwd: cwd, sessionID: sessionID)
        try FileManager.default.createDirectory(at: subagentsDir, withIntermediateDirectories: true)

        let cap = 24
        let totalAgents = cap + 4
        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)
        var expectedLiveIDs = Set<String>()
        var jsonlURLsByID: [String: URL] = [:]
        for i in 0..<totalAgents {
            let agentID = "a\(i)"
            let jsonlURL = subagentsDir.appendingPathComponent("agent-\(agentID).jsonl")
            FileManager.default.createFile(atPath: jsonlURL.path, contents: nil)
            // Explicit, strictly increasing mtimes — real filesystem
            // mtimes from rapid-fire creation could collide or not
            // reflect intended ordering; this makes the ranking
            // deterministic regardless of clock/filesystem resolution.
            try FileManager.default.setAttributes(
                [.modificationDate: baseDate.addingTimeInterval(TimeInterval(i))],
                ofItemAtPath: jsonlURL.path)
            jsonlURLsByID[agentID] = jsonlURL

            let metaURL = subagentsDir.appendingPathComponent("agent-\(agentID).meta.json")
            try #"{"agentType":"Explore","description":"d","toolUseId":"tu-\#(i)","spawnDepth":1}"#
                .write(to: metaURL, atomically: true, encoding: .utf8)

            if i >= totalAgents - cap { expectedLiveIDs.insert(agentID) }
        }

        var receivedMetaIDs: Set<String> = []
        var receivedAgentLineIDs: Set<String> = []
        let allMetasArrived = expectation(description: "meta emitted for every file, uncapped")
        allMetasArrived.assertForOverFulfill = false
        let pool = makePool(
            onAgentLines: { sid, agentID, _ in
                guard sid == sessionID else { return }
                receivedAgentLineIDs.insert(agentID)
            },
            onMeta: { sid, meta in
                guard sid == sessionID else { return }
                receivedMetaIDs.insert(meta.agentID)
                if receivedMetaIDs.count == totalAgents { allMetasArrived.fulfill() }
            })

        // The initial subagents-dir scan now runs off-main (Group 4) —
        // wait for every meta to arrive, which only happens once that
        // scan's single `Task { @MainActor in }` hop has fully applied,
        // by which point `enforceAgentTailerCap` has already run too
        // (same synchronous batch — see `FlowTailerPool.applyScanResults`).
        pool.reconcile(hot: [entry(session: sessionID, cwd: cwd)])
        wait(for: [allMetasArrived], timeout: 3)

        XCTAssertEqual(receivedMetaIDs.count, totalAgents, "meta must be emitted for every file, uncapped")

        let liveIDs = pool.liveAgentTailerIDs(sessionID: sessionID)
        XCTAssertEqual(liveIDs.count, cap)
        XCTAssertEqual(liveIDs, expectedLiveIDs, "must keep exactly the cap-count newest-by-mtime files live")

        // "a0" is the oldest file, never promoted by the cap. Append to
        // it and confirm nothing arrives — if `enforceAgentTailerCap`
        // only updated `liveAgentTailerIDs` without actually leaving it
        // un-started, this delivery would still fire.
        try append("late\n", to: jsonlURLsByID["a0"]!)

        let settled = expectation(description: "settle window elapsed")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { settled.fulfill() }
        wait(for: [settled], timeout: 1)

        XCTAssertFalse(receivedAgentLineIDs.contains("a0"),
            "capped-out file must never be started, not merely excluded from bookkeeping")
        waitUntilScansSettle(pool)
    }

    /// Group 4 item 4(a): with dynamic mtime ranking now live, a tailer
    /// the cap started on scan 1 can be genuinely RUNNING — not merely
    /// registered — and still get demoted by a later rescan once newer
    /// files push it out of the top `cap` by mtime. Proves the demoted
    /// tailer actually stops delivering (an append afterward reaches
    /// nothing), not just that it's absent from `liveAgentTailerIDs`.
    func testTwoScanRescanDemotesGenuinelyRunningAgentTailer() throws {
        let cwd = "/Users/x/proj"
        let sessionID = "s1"
        try writeTranscript([], cwd: cwd, sessionID: sessionID)
        let subagentsDir = ClaudeHome.subagentsDirURL(home: home, cwd: cwd, sessionID: sessionID)
        try FileManager.default.createDirectory(at: subagentsDir, withIntermediateDirectories: true)

        let cap = 24
        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)
        var jsonlURLsByID: [String: URL] = [:]
        func stageFile(_ agentID: String, mtimeOffset: TimeInterval) throws {
            let jsonlURL = subagentsDir.appendingPathComponent("agent-\(agentID).jsonl")
            FileManager.default.createFile(atPath: jsonlURL.path, contents: nil)
            try FileManager.default.setAttributes(
                [.modificationDate: baseDate.addingTimeInterval(mtimeOffset)], ofItemAtPath: jsonlURL.path)
            jsonlURLsByID[agentID] = jsonlURL
        }
        for i in 0..<cap {
            try stageFile("a\(i)", mtimeOffset: TimeInterval(i))
        }

        var targetAgentID: String?
        var currentExpectation: XCTestExpectation?
        let pool = makePool(onAgentLines: { sid, agentID, _ in
            guard sid == sessionID, agentID == targetAgentID else { return }
            currentExpectation?.fulfill()
        })

        pool.reconcile(hot: [entry(session: sessionID, cwd: cwd)])
        waitUntilScansSettle(pool)
        XCTAssertEqual(pool.liveAgentTailerIDs(sessionID: sessionID), Set(jsonlURLsByID.keys),
            "all 24 files fit exactly at the cap on the first scan")

        // "a0" is the oldest of the initial 24 — first to drop when
        // newer files arrive. Prove it's genuinely running (not merely
        // registered) before demoting it.
        targetAgentID = "a0"
        let beforeDemotion = expectation(description: "a0 delivers before demotion")
        // `onAgentLines` can legitimately fire more than once for a
        // single logical append (the underlying dispatch-source event
        // can fire redundantly), and `currentExpectation` stays bound to
        // this object while later code (staging more files,
        // `waitUntilScansSettle`) keeps the run loop turning — without
        // this, a redundant delivery risks a "multiple fulfill" API
        // violation, which was observed, during this work, to crash the
        // whole process rather than fail cleanly.
        beforeDemotion.assertForOverFulfill = false
        currentExpectation = beforeDemotion
        try append("running-before-demotion\n", to: jsonlURLsByID["a0"]!)
        wait(for: [beforeDemotion], timeout: 3)
        // The append above bumps a0's real mtime to "now" (2026), which
        // would make it look NEWER than every baseDate-seeded (2023)
        // file below — restore its synthetic mtime so the ranking
        // below still reflects the intended oldest-of-24 ordering.
        try FileManager.default.setAttributes(
            [.modificationDate: baseDate.addingTimeInterval(0)], ofItemAtPath: jsonlURLsByID["a0"]!.path)

        // 4 newer files arrive — a rescan must now rank a0..a3 out of
        // the top 24 and demote them, a0 included.
        for i in 0..<4 {
            try stageFile("newer\(i)", mtimeOffset: TimeInterval(cap + i))
        }
        waitUntilScansSettle(pool)

        XCTAssertFalse(pool.liveAgentTailerIDs(sessionID: sessionID).contains("a0"), "a0 must be demoted")

        let noDelivery = expectation(description: "no delivery after demotion")
        noDelivery.isInverted = true
        noDelivery.assertForOverFulfill = false
        currentExpectation = noDelivery
        try append("after-demotion\n", to: jsonlURLsByID["a0"]!)
        wait(for: [noDelivery], timeout: 0.5)
        waitUntilScansSettle(pool)
    }

    /// Group 4 item 4(b): a demoted tailer whose file grows again (new
    /// appends written WHILE demoted) must, once re-promoted by a
    /// rescan, deliver that gap content — proving `enforceAgentTailerCap`
    /// calls `resume()` (continue from the stored offset) for a
    /// re-promotion, not `start(replayExisting: false)` (a fresh
    /// EOF-seek, which would silently skip everything written during
    /// the demotion gap).
    func testDemotedAgentTailerIsRePromotedAndResumesFromStoredOffset() throws {
        let cwd = "/Users/x/proj"
        let sessionID = "s1"
        try writeTranscript([], cwd: cwd, sessionID: sessionID)
        let subagentsDir = ClaudeHome.subagentsDirURL(home: home, cwd: cwd, sessionID: sessionID)
        try FileManager.default.createDirectory(at: subagentsDir, withIntermediateDirectories: true)

        let cap = 24
        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)
        var jsonlURLsByID: [String: URL] = [:]
        func stageFile(_ agentID: String, mtimeOffset: TimeInterval) throws {
            let jsonlURL = subagentsDir.appendingPathComponent("agent-\(agentID).jsonl")
            FileManager.default.createFile(atPath: jsonlURL.path, contents: nil)
            try FileManager.default.setAttributes(
                [.modificationDate: baseDate.addingTimeInterval(mtimeOffset)], ofItemAtPath: jsonlURL.path)
            jsonlURLsByID[agentID] = jsonlURL
        }
        for i in 0..<cap {
            try stageFile("a\(i)", mtimeOffset: TimeInterval(i))
        }

        var deliveredLines: [String: [String]] = [:]
        var targetAgentID: String?
        var currentExpectation: XCTestExpectation?
        let pool = makePool(onAgentLines: { sid, agentID, lines in
            guard sid == sessionID else { return }
            deliveredLines[agentID, default: []].append(contentsOf: lines)
            if agentID == targetAgentID { currentExpectation?.fulfill() }
        })

        pool.reconcile(hot: [entry(session: sessionID, cwd: cwd)])
        waitUntilScansSettle(pool)
        XCTAssertEqual(pool.liveAgentTailerIDs(sessionID: sessionID), Set(jsonlURLsByID.keys))

        // Establish a nonzero, genuine offset for "a0" before demoting
        // it — not strictly required for the resume-vs-EOF-seek
        // discrimination below, but matches how a real running tailer
        // would behave (content both before and during the gap).
        targetAgentID = "a0"
        let beforeDemotion = expectation(description: "a0 delivers before demotion")
        // See the equivalent comment in
        // `testTwoScanRescanDemotesGenuinelyRunningAgentTailer` — a
        // redundant `onAgentLines` delivery for this same append is
        // possible while `currentExpectation` is still bound here.
        beforeDemotion.assertForOverFulfill = false
        currentExpectation = beforeDemotion
        try append("running-before-demotion\n", to: jsonlURLsByID["a0"]!)
        wait(for: [beforeDemotion], timeout: 3)
        // The append above bumps a0's real mtime to "now" (2026), which
        // would make it look NEWER than every baseDate-seeded (2023)
        // file below — restore its synthetic mtime so the ranking
        // below still reflects the intended oldest-of-24 ordering.
        try FileManager.default.setAttributes(
            [.modificationDate: baseDate.addingTimeInterval(0)], ofItemAtPath: jsonlURLsByID["a0"]!.path)

        // 4 newer files demote a0..a3.
        for i in 0..<4 {
            try stageFile("newer\(i)", mtimeOffset: TimeInterval(cap + i))
        }
        waitUntilScansSettle(pool)
        XCTAssertFalse(pool.liveAgentTailerIDs(sessionID: sessionID).contains("a0"), "a0 must be demoted")

        // Gap content, written while a0 is demoted (no live fd) — must
        // not be lost once a0 is re-promoted.
        try append("gap-content\n", to: jsonlURLsByID["a0"]!)

        // The append above naturally bumps a0's mtime to "now" — far
        // newer than every baseDate-seeded file — so a0 will re-enter
        // the top `cap` on the next rescan. Trigger that rescan the
        // same way any dir-level change would in production: one more
        // file arriving (a content-only write to an existing file
        // doesn't touch the watched directory's own entries, so this is
        // needed to wake the watcher).
        try stageFile("trigger", mtimeOffset: TimeInterval(cap + 4))

        let gapArrives = expectation(description: "gap content delivered from stored offset")
        gapArrives.assertForOverFulfill = false
        currentExpectation = gapArrives
        wait(for: [gapArrives], timeout: 3)

        XCTAssertTrue(pool.liveAgentTailerIDs(sessionID: sessionID).contains("a0"), "a0 must be re-promoted")
        XCTAssertEqual(deliveredLines["a0"], ["running-before-demotion", "gap-content"],
            "resume() must continue from the offset preserved across the demotion gap, not re-seek to a fresh EOF")
        waitUntilScansSettle(pool)
    }

    /// Group 4 item 4(c): confirms the mtime gate — an unchanged meta
    /// file is not re-parsed on a rescan it's swept up in — while the
    /// unconditional re-emission design (`onMeta` fires for every
    /// cached entry on every scan) is preserved regardless.
    func testUnchangedMetaFileIsNotReparsedButIsReemittedOnRescan() throws {
        let cwd = "/Users/x/proj"
        let sessionID = "s1"
        try writeTranscript([], cwd: cwd, sessionID: sessionID)
        let subagentsDir = ClaudeHome.subagentsDirURL(home: home, cwd: cwd, sessionID: sessionID)
        try FileManager.default.createDirectory(at: subagentsDir, withIntermediateDirectories: true)

        let metaURL = subagentsDir.appendingPathComponent("agent-a1.meta.json")
        try #"{"agentType":"Explore","description":"d","toolUseId":"tu1","spawnDepth":1}"#
            .write(to: metaURL, atomically: true, encoding: .utf8)

        var emissionCount = 0
        var currentExpectation: XCTestExpectation?
        let pool = makePool(onMeta: { sid, meta in
            guard sid == sessionID, meta.agentID == "a1" else { return }
            emissionCount += 1
            currentExpectation?.fulfill()
        })

        // The FIRST scan is triggered synchronously and directly (see
        // `ensureSubagentsWatcher`'s "catch anything already there"
        // call), not via a dispatch-source event, so it can't double-fire
        // — asserting exactly 1 here is safe.
        let firstScan = expectation(description: "first scan emits a1")
        currentExpectation = firstScan
        pool.reconcile(hot: [entry(session: sessionID, cwd: cwd)])
        wait(for: [firstScan], timeout: 3)

        XCTAssertEqual(emissionCount, 1)
        XCTAssertEqual(pool.metaParseCount, 1, "first scan must parse the new meta file")

        // Trigger a second scan with NO changes to the meta file — a
        // new, unrelated jsonl file arriving is enough to wake the dir
        // watcher and force a rescan.
        let dummyURL = subagentsDir.appendingPathComponent("agent-dummy.jsonl")
        FileManager.default.createFile(atPath: dummyURL.path, contents: nil)

        // Unlike the first scan, this one is driven by a real
        // dispatch-source dir event, which can legitimately fire more
        // than once for what looks like a single filesystem operation
        // (observed directly during this work) — hence
        // `assertForOverFulfill` here, and `assertGreaterThan` below
        // instead of an exact count.
        let secondScan = expectation(description: "second scan re-emits a1 without reparsing")
        secondScan.assertForOverFulfill = false
        currentExpectation = secondScan
        wait(for: [secondScan], timeout: 3)

        XCTAssertGreaterThan(emissionCount, 1, "onMeta must fire again even though the file didn't change (re-emission design)")
        XCTAssertEqual(pool.metaParseCount, 1, "an unchanged meta file must not be re-parsed on rescan (mtime gate)")
        waitUntilScansSettle(pool)
    }

    // MARK: - Post-stop watcher resurrection guard

    /// A transcript delivery that lands on `deliveryQueue` (and then
    /// hops to the main actor via `Task`) before `stop()` runs is an
    /// accepted race (see `ClaudeTranscriptTailer`'s trailing comment)
    /// — the transcript line itself still gets forwarded once after
    /// the logical stop point. But `handleTranscriptLines` must NOT let
    /// that stray delivery call `ensureSubagentsWatcher` and resurrect
    /// a stopped session's dir watcher.
    ///
    /// Forces the race deterministically: this test method itself runs
    /// on the main thread, and a `Task { @MainActor in ... }` can't
    /// execute until that thread yields (e.g. via `wait(for:)`).
    /// `Thread.sleep` blocks the main thread (without pumping the run
    /// loop) long enough for the tailer's background delivery chain to
    /// reach the point of enqueueing its main-actor continuation — so
    /// the synchronous `reconcile(hot: [])` call right after is
    /// guaranteed to stop the session before that continuation gets a
    /// chance to run.
    func testLateTranscriptDeliveryAfterStopDoesNotResurrectSubagentsWatcher() throws {
        let cwd = "/Users/x/proj"
        let sessionID = "s1"
        let transcriptURL = try writeTranscript([], cwd: cwd, sessionID: sessionID)
        let subagentsDir = ClaudeHome.subagentsDirURL(home: home, cwd: cwd, sessionID: sessionID)
        try FileManager.default.createDirectory(at: subagentsDir, withIntermediateDirectories: true)

        let noResurrection = expectation(description: "no onMeta for a file dropped in post-stop")
        noResurrection.isInverted = true
        let pool = makePool(onMeta: { sid, meta in
            guard sid == sessionID, meta.agentID == "late" else { return }
            noResurrection.fulfill()
        })

        pool.reconcile(hot: [entry(session: sessionID, cwd: cwd)])
        XCTAssertTrue(pool.activeSessionIDs.contains(sessionID))

        try append("late\n", to: transcriptURL)
        Thread.sleep(forTimeInterval: 0.2)

        pool.reconcile(hot: []) // synchronous stop (decision 1) — the race is now in flight
        XCTAssertTrue(pool.activeSessionIDs.isEmpty)

        // Dropped in post-stop: if the in-flight late delivery were
        // allowed to call `ensureSubagentsWatcher` (the pre-fix bug),
        // its "catch anything already there" scan would pick this file
        // up and fire `onMeta` for it once the run loop below is pumped.
        let metaURL = subagentsDir.appendingPathComponent("agent-late.meta.json")
        try #"{"agentType":"Explore","description":"d","toolUseId":"tu-late","spawnDepth":1}"#
            .write(to: metaURL, atomically: true, encoding: .utf8)

        wait(for: [noResurrection], timeout: 0.6)
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
