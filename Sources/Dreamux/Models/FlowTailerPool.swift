import Foundation
import Darwin

/// Owns one `ClaudeTranscriptTailer` per hot-or-zoomed session (plus one
/// per discovered subagent), reconciling against registry snapshots
/// (`reconcile`) and zoom requests (`ensureLazyTail`/`releaseLazyTail`).
/// `@MainActor`: these entry points are cheap bookkeeping; the three
/// callbacks always land on the main actor too (tailers deliver on a
/// shared utility queue — every `onLines` closure hops back via
/// `Task { @MainActor in ... }` before touching pool state or calling
/// out, mirroring `SignalKind.isFlowSignal`'s isolation-laundering
/// idiom).
///
/// Two implementation decisions worth recording here (full reasoning
/// in task-10-report.md):
///
/// 1. Hot-set `start`/`resume`/`stop` calls run SYNCHRONOUSLY, directly
///    on the main actor — not hopped off-main. `ClaudeTranscriptTailer`'s
///    EOF-seek path does no meaningful disk read (one `fstat` + one
///    empty read), so the bounded hitch is negligible, and per-poll
///    cost is proportional to hot-set CHURN (rare — a session entering
///    or leaving busy/waiting), not hot-set size (steady sessions are
///    left untouched by `reconcile`). Staying synchronous also
///    preserves the "offset established before the caller can race it"
///    guarantee `ClaudeTranscriptTailer.start`/`stop` were deliberately
///    built to provide (see their design notes) — hopping these off
///    main would silently reintroduce that exact race in this pool's
///    own tests.
/// 2. `ensureLazyTail`'s full replay (`start(replayExisting: true)`)
///    CAN do a real disk read (up to 2,000 lines of a potentially
///    multi-MB transcript) and is triggered by a user zoom click, so
///    it's dispatched off-main via `Task.detached`. A `releaseLazyTail`
///    can run to completion synchronously while that replay is still
///    in flight; `reconcileAfterLazyStart` self-heals that race by
///    re-checking the session's wanted state once the replay call
///    returns and stopping it again if it's no longer wanted — same
///    self-heal shape as `FlowStore.apply(registry:)`'s stale-stop
///    handling.
/// 3. `scanSubagentsDir` never lets the LIVE agent-tailer count for a
///    session exceed `maxAgentTailersPerSession`. `ClaudeTranscriptTailer
///    .init` opens no fds (only `start()`/`resume()` do — see its type
///    doc), so a newly-discovered agent file is always registered in
///    `SessionState.agentTailers` but only actually started if it
///    ranks among the most-recently-modified `maxAgentTailersPerSession`
///    files once `enforceAgentTailerCap` ranks everything this session
///    has ever discovered. That ranking is LIVE, not frozen at
///    discovery: every scan refreshes `agentFileModDates` from a fresh
///    `stat` of every agent file it finds (see `scanDirectoryOffMain`),
///    so a file that keeps growing rises in rank and one that goes
///    quiet falls — and so re-promotion is a real, reachable path, not
///    just a bookkeeping possibility. That refresh, though, only runs
///    when a scan does — gated on a DIRECTORY-level watch event (a
///    file appearing, disappearing, or being renamed), not on
///    content-only growth of an already-known file — so a demoted
///    tailer whose file grows in isolation re-promotes only once some
///    other directory event next triggers a scan (bounded: offset
///    preservation means nothing already written is lost, just
///    delayed). Anything that drops out of that
///    ranking gets `stop()`ed (fds released) but keeps its
///    `agentTailers` entry; if it's later re-promoted,
///    `enforceAgentTailerCap` resumes it from the offset that entry
///    preserved rather than re-seeking to a fresh EOF (which would
///    silently drop everything written during the demotion gap) — see
///    `everStartedAgentTailerIDs`. Because nothing is started until
///    it's already ranked, an outlier session directory with far more
///    subagents than the cap never transiently exceeds it mid-scan —
///    see `maxAgentTailersPerSession`'s doc for the concrete fd math.
/// 4. `scanSubagentsDir`'s directory listing, per-file `stat`, and
///    conditional meta JSON parse all run off the main actor, on
///    `deliveryQueue` (mirroring how `ClaudeTranscriptTailer` already
///    does its own off-main work before handing back to
///    `transcriptCallback`/`agentCallback`'s `Task { @MainActor in }`
///    hop — this uses the same hop) — a real session directory has been
///    observed with 219 meta files, and parsing all of them inline on
///    main per dir event would be an O(N^2) hitch across a burst of
///    events. Only a new-or-changed meta file is actually re-parsed
///    (`SessionState.metaCache`, gated by mtime); `onMeta` still fires
///    for every cached entry on every scan regardless (the
///    join-resweep design predates this change — see
///    `scanDirectoryOffMain`'s comment). A single `Task { @MainActor
///    in }` hop delivers the whole scan's results — cache update,
///    `onMeta` batch, `agentFileModDates` refresh, new-tailer
///    registration, and `enforceAgentTailerCap` — as one atomic unit
///    (`applyScanResults`), re-validating `isHot || isLazy` first (same
///    guard shape as `handleTranscriptLines`'s) since the session may
///    have been stopped while this scan was in flight off-main.
/// `@unchecked Sendable`: every stored property is only ever touched
/// from the main actor (this class's own isolation). The `[weak pool]`
/// captures in `transcriptCallback`/`agentCallback`/`replayFullHistory`
/// only ever dereference `pool` inside a `Task { @MainActor in }` hop —
/// never off-actor — so handing a weak reference across the
/// nonisolated boundary those closures are built from can't race
/// anything; this conformance just satisfies the compiler's send-safety
/// check for capturing that reference at all.
@MainActor
final class FlowTailerPool: @unchecked Sendable {
    private let home: URL
    private let onTranscriptLines: (String, [String]) -> Void
    private let onAgentLines: (String, String, [String]) -> Void
    private let onMeta: (String, SubagentMeta) -> Void
    /// Fires once per tailer-cap overflow (see `ClaudeTranscriptTailer
    /// .onDroppedBytes`) for a session's TRANSCRIPT tailer — the byte
    /// count itself is discarded, only "at least one drop happened for
    /// this session" survives (the coarse mapping the brief calls for).
    /// `nil` by default; `ProjectSession` wires it to
    /// `FlowStore.noteSkippedLines`. Not wired for agent tailers
    /// (`applyScanResults`, below) — no caller tracks per-agent drops
    /// today.
    private let onDroppedBytes: ((String) -> Void)?

    /// Delivery channel for every tailer this pool owns (session +
    /// per-agent) — NOT main. The three callbacks above only ever run
    /// on main via the `Task { @MainActor in }` trampoline built in
    /// `transcriptCallback`/`agentCallback`.
    private let deliveryQueue = DispatchQueue(label: "com.dreamux.claude.flow-tailer-pool", qos: .utility)

    /// Cap on LIVE agent tailers per session (see decision 3 in this
    /// type's doc comment). Each actively-watching
    /// `ClaudeTranscriptTailer` holds 2 fds — a read `FileHandle` plus
    /// an `O_EVTONLY` kqueue fd (see its type doc) — and the process'
    /// soft fd limit is 256. A real-world session directory has been
    /// observed with 219 subagent `.jsonl` files; tailing all of them
    /// (438 fds) on top of the ~64 fds already open elsewhere in the
    /// app would blow past that limit and EMFILE the whole app. 24
    /// live tailers (48 fds) leaves comfortable headroom. Meta
    /// parsing/emission in `scanSubagentsDir` costs no fds and is NOT
    /// subject to this cap — only tailers are.
    private static let maxAgentTailersPerSession = 24

    /// Test seam (Group 4 item 4c): incremented once per meta file
    /// `scanDirectoryOffMain` actually re-parses — mtime changed, or no
    /// cache entry yet — NOT once per scan and NOT once per `onMeta`
    /// emission (every cached entry is still re-emitted on every scan;
    /// see `ScanResult.metaEmissionOrder`'s doc). Lets a test confirm
    /// the mtime gate is working: rescanning an unchanged directory
    /// must grow `onMeta` emission count without growing this.
    private(set) var metaParseCount = 0

    /// Test seam: how many scans dispatched by `scanSubagentsDir` (see
    /// decision 4 in the type doc comment) have not yet been applied
    /// back on main via `applyScanResults`. A dir-event-triggered scan
    /// is asynchronous with no other completion signal a test can
    /// observe directly, so a test that triggers one (directly, or via
    /// a real dir event like creating a file) needs to poll this down
    /// to 0 before trusting any state the scan would affect —
    /// otherwise it's checking state from before the scan landed.
    private(set) var pendingScanCount = 0

    private var sessions: [String: SessionState] = [:]

    init(
        home: URL,
        onTranscriptLines: @escaping (_ sessionID: String, _ lines: [String]) -> Void,
        onAgentLines: @escaping (_ sessionID: String, _ agentID: String, _ lines: [String]) -> Void,
        onMeta: @escaping (_ sessionID: String, _ meta: SubagentMeta) -> Void,
        onDroppedBytes: ((_ sessionID: String) -> Void)? = nil
    ) {
        self.home = home
        self.onTranscriptLines = onTranscriptLines
        self.onAgentLines = onAgentLines
        self.onMeta = onMeta
        self.onDroppedBytes = onDroppedBytes
    }

    /// Test seam: sessions this pool is currently tailing for either
    /// reason (hot or zoomed) — NOT sessions merely remembered for
    /// their offset after both flags dropped.
    var activeSessionIDs: Set<String> {
        Set(sessions.values.filter { $0.isHot || $0.isLazy }.map(\.sessionID))
    }

    /// Test seam: agent IDs this pool currently holds a LIVE tailer for
    /// within the given session — `SessionState.liveAgentTailerIDs`,
    /// bounded by `maxAgentTailersPerSession`. Mirrors `activeSessionIDs`.
    func liveAgentTailerIDs(sessionID: String) -> Set<String> {
        sessions[sessionID]?.liveAgentTailerIDs ?? []
    }

    // MARK: - Hot set

    /// Start tailing every entry not already hot; stop tailing (but
    /// keep, for their offsets) every session that dropped out; revive
    /// any already-hot session's tailer that went dormant (see
    /// `reviveDormantTailers`).
    func reconcile(hot: [ClaudeSessionEntry]) {
        var hotByID: [String: ClaudeSessionEntry] = [:]
        for entry in hot { hotByID[entry.sessionId] = entry }

        for (sessionID, entry) in hotByID where sessions[sessionID]?.isHot != true {
            activateHot(sessionID: sessionID, cwd: entry.cwd)
        }
        for (sessionID, state) in sessions where state.isHot && hotByID[sessionID] == nil {
            deactivateHot(state)
        }
        // Includes sessions just activated above too — nothing excludes
        // them, and there's no need to: `reviveDormantTailers` only
        // acts on a tailer that IS dormant, so for a freshly-activated
        // session whose `start()`/`resume()` just succeeded this is a
        // harmless, redundant no-op check. For the rarer case where
        // that same-poll `start()` already exhausted its reopen retry
        // and went dormant, this pass revives it a poll earlier than
        // waiting for the next `reconcile` would — pure upside.
        for (_, state) in sessions where state.isHot && hotByID[state.sessionID] != nil {
            reviveDormantTailers(state)
        }
    }

    /// A session that's been in the hot set since a PRIOR poll (not
    /// freshly activated this one) whose transcript — or an agent's —
    /// tailer never got a live fd: most commonly, its transcript file
    /// didn't exist yet when the session first went hot, so
    /// `activateHot`'s `start(replayExisting: false)` exhausted
    /// `ClaudeTranscriptTailer`'s one reopen retry and went dormant (see
    /// its `isDormant` doc comment) — nothing would otherwise ever
    /// re-open that file. `resume()` is safe to call even on a tailer
    /// that's merely mid-retry, not fully dormant yet (it always tears
    /// down and retries immediately), so this doesn't need to
    /// distinguish the two.
    ///
    /// Agent tailers are far less likely to hit this (`scanSubagentsDir`
    /// only ever constructs one after listing the file from disk, so its
    /// first `start()` almost always succeeds), but a `.delete`/
    /// `.rename` mid-tail (log rotation) can dormant one the same way —
    /// so they get the same revival pass here, at the cost of one cheap
    /// in-memory read per agent tailer per poll.
    private func reviveDormantTailers(_ state: SessionState) {
        if state.hasStartedTranscript, state.transcriptTailer.isDormant {
            state.transcriptTailer.resume()
        }
        // Scoped to `liveAgentTailerIDs`, not all of `agentTailers` —
        // a tailer the cap has stopped isn't dormant-in-the-retry
        // sense (see `enforceAgentTailerCap`) and must stay stopped.
        for agentID in state.liveAgentTailerIDs {
            guard let agentTailer = state.agentTailers[agentID], agentTailer.isDormant else { continue }
            agentTailer.resume()
        }
    }

    private func activateHot(sessionID: String, cwd: String) {
        let state = sessionState(for: sessionID, cwd: cwd)
        state.isHot = true
        // EOF-seek only (or a resume from a previously-stopped offset)
        // — no meaningful disk read either way, safe to call
        // synchronously; see decision 1 in the type doc comment.
        if state.hasStartedTranscript {
            state.transcriptTailer.resume()
        } else {
            state.hasStartedTranscript = true
            state.transcriptTailer.start(replayExisting: false)
        }
        // Scoped to `liveAgentTailerIDs` — see `enforceAgentTailerCap`;
        // a capped-out tailer must not be resumed just because the
        // session went hot again.
        for agentID in state.liveAgentTailerIDs {
            state.agentTailers[agentID]?.resume()
        }
        ensureSubagentsWatcher(sessionID: sessionID)
    }

    private func deactivateHot(_ state: SessionState) {
        state.isHot = false
        guard !state.isLazy else { return }  // still zoomed: keep tailing
        stopSession(state)
    }

    // MARK: - Lazy (zoom) tail

    /// Zoom into a session's full history regardless of hot status. If
    /// already lazily tailing, this is a no-op (re-zooming the same
    /// lane shouldn't restart the replay).
    func ensureLazyTail(sessionID: String, cwd: String) {
        let state = sessionState(for: sessionID, cwd: cwd)
        guard !state.isLazy else { return }
        state.isLazy = true
        state.hasStartedTranscript = true
        Self.replayFullHistory(pool: self, sessionID: sessionID, tailer: state.transcriptTailer)
        // Scoped to `liveAgentTailerIDs`, not every agent tailer this
        // session has ever discovered — replaying a capped-out tailer
        // would reopen its fds and silently blow past the cap (see
        // `enforceAgentTailerCap`).
        for agentID in state.liveAgentTailerIDs {
            guard let agentTailer = state.agentTailers[agentID] else { continue }
            Self.replayFullHistory(pool: self, sessionID: sessionID, tailer: agentTailer)
        }
        ensureSubagentsWatcher(sessionID: sessionID)
    }

    /// Release this pool's zoom interest. A session that's still hot
    /// keeps tailing regardless — only a session that's neither hot
    /// nor lazy actually stops.
    func releaseLazyTail(sessionID: String) {
        guard let state = sessions[sessionID] else { return }
        state.isLazy = false
        guard !state.isHot else { return }
        stopSession(state)
    }

    /// Off-main: a lazy zoom's full replay can do a real, non-trivial
    /// disk read (see decision 2 in the type doc comment) — dispatched
    /// so it never blocks the main actor. Built from a `nonisolated`
    /// context for the same isolation-laundering reason as
    /// `transcriptCallback`/`agentCallback` below.
    nonisolated private static func replayFullHistory(
        pool: FlowTailerPool, sessionID: String, tailer: ClaudeTranscriptTailer
    ) {
        Task.detached(priority: .utility) { [weak pool] in
            tailer.start(replayExisting: true)
            guard let pool else { return }
            await MainActor.run { pool.reconcileAfterLazyStart(sessionID: sessionID) }
        }
    }

    /// Self-heals the race where `releaseLazyTail` (and possibly a
    /// hot-set departure too) completes synchronously while a
    /// `replayFullHistory` for the same session is still in flight on
    /// its detached task: by the time that task's `start()` call
    /// returns, the session may no longer be wanted at all. Stop it
    /// again rather than leaving a stray tailer running.
    private func reconcileAfterLazyStart(sessionID: String) {
        guard let state = sessions[sessionID] else { return }
        if !state.isHot && !state.isLazy { stopSession(state) }
    }

    private func stopSession(_ state: SessionState) {
        state.transcriptTailer.stop()
        for agentTailer in state.agentTailers.values { agentTailer.stop() }
        state.subagentsWatcher?.cancel()
        state.subagentsWatcher = nil
    }

    // MARK: - Session bookkeeping

    private func sessionState(for sessionID: String, cwd: String) -> SessionState {
        if let existing = sessions[sessionID] {
            existing.cwd = cwd
            return existing
        }
        let url = ClaudeHome.transcriptURL(home: home, cwd: cwd, sessionID: sessionID)
        let tailer = ClaudeTranscriptTailer(
            url: url, deliveryQueue: deliveryQueue,
            onLines: Self.transcriptCallback(pool: self, sessionID: sessionID),
            onDroppedBytes: Self.droppedBytesCallback(pool: self, sessionID: sessionID)
        )
        let state = SessionState(sessionID: sessionID, cwd: cwd, transcriptTailer: tailer)
        sessions[sessionID] = state
        return state
    }

    private func handleTranscriptLines(sessionID: String, lines: [String]) {
        guard let state = sessions[sessionID] else { return }
        onTranscriptLines(sessionID, lines)
        // The subagents dir may not exist yet — claude creates it
        // lazily, only once the session's first subagent spawns.
        // Rather than watching a path that doesn't exist, retry the
        // listing on every transcript wake, which happens whenever the
        // session does anything at all (see `ensureSubagentsWatcher`).
        //
        // Guarded on hot/lazy: a delivery can still land here after
        // this pool has already `stopSession`ed it — `onLines` firing
        // once more post-stop is an accepted race (see
        // `ClaudeTranscriptTailer`'s trailing comment); forwarding it
        // to `onTranscriptLines` above is harmless for the same
        // reason. But calling `ensureSubagentsWatcher` is NOT harmless
        // — it would resurrect the dir watcher (and everything
        // downstream: meta re-emission, new agent-tailer spawns) for a
        // session this pool has deliberately torn down.
        guard state.isHot || state.isLazy else { return }
        ensureSubagentsWatcher(sessionID: sessionID)
    }

    /// Mirrors `handleTranscriptLines`'s/`handleAgentLines`'s "forward
    /// unconditionally, but only if the session is still known" shape —
    /// a stray drop notification landing after `stopSession` (same
    /// accepted race as a stray transcript line, see
    /// `ClaudeTranscriptTailer`'s trailing comment) is harmless to
    /// forward, since `onDroppedBytes` triggers no fd-touching side
    /// effect the way `ensureSubagentsWatcher` would.
    private func handleDroppedBytes(sessionID: String) {
        guard sessions[sessionID] != nil else { return }
        onDroppedBytes?(sessionID)
    }

    private func handleAgentLines(sessionID: String, agentID: String, lines: [String]) {
        guard sessions[sessionID] != nil else { return }
        onAgentLines(sessionID, agentID, lines)
    }

    /// A closure literal formed inside a `@MainActor` method (like this
    /// class's other instance methods) is itself MainActor-isolated
    /// under Swift 6, even when its body only ever forms a `Task` — the
    /// same isolation-inference hazard `SignalKind.isFlowSignal`
    /// documents (and that trapped once already in this codebase).
    /// `ClaudeTranscriptTailer` invokes `onLines` on ITS OWN utility
    /// `deliveryQueue`, not main, so this callback must be built from a
    /// `nonisolated` context — a `static func` on a `@MainActor` class
    /// is nonisolated by default — to avoid a runtime isolation trap.
    nonisolated private static func transcriptCallback(
        pool: FlowTailerPool, sessionID: String
    ) -> ([String]) -> Void {
        // Weak in the OUTER closure (the one `ClaudeTranscriptTailer`
        // stores forever, so it must never retain `pool` — pool owns
        // the tailer that owns this closure); re-strengthened into a
        // per-invocation local before entering the `Task`, so the task
        // captures a plain (transiently strong) value instead of
        // reaching back through the weak reference a second time —
        // avoids both the retain cycle and a Swift 6 region-isolation
        // false positive on capturing the same weak optional twice.
        { [weak pool] lines in
            guard let pool else { return }
            Task { @MainActor in pool.handleTranscriptLines(sessionID: sessionID, lines: lines) }
        }
    }

    nonisolated private static func agentCallback(
        pool: FlowTailerPool, sessionID: String, agentID: String
    ) -> ([String]) -> Void {
        { [weak pool] lines in
            guard let pool else { return }
            Task { @MainActor in pool.handleAgentLines(sessionID: sessionID, agentID: agentID, lines: lines) }
        }
    }

    /// `ClaudeTranscriptTailer`'s cap-overflow signal (see its
    /// `onDroppedBytes` doc), forwarded to this pool's own `sessionID`-
    /// keyed `onDroppedBytes` (see its doc for why the byte count
    /// itself is discarded) via the same `Task { @MainActor in }` hop
    /// shape as `transcriptCallback`/`agentCallback` above.
    nonisolated private static func droppedBytesCallback(
        pool: FlowTailerPool, sessionID: String
    ) -> (Int) -> Void {
        { [weak pool] _ in
            guard let pool else { return }
            Task { @MainActor in pool.handleDroppedBytes(sessionID: sessionID) }
        }
    }

    // MARK: - Subagents dir

    /// DocStore's kqueue idiom (`open(path, O_EVTONLY)` +
    /// `makeFileSystemObjectSource` + cancel-closes-fd), on `.main` —
    /// unlike the transcript tailers, this watcher's event handler can
    /// stay an ordinary inline closure (no isolation-laundering
    /// needed) because `.main` guarantees it only ever fires on the
    /// main actor, exactly like `DocStore.rebuildWatchers`. The
    /// listing + meta parsing this triggers is small (a handful of
    /// files per session) — same bounded-cost reasoning as decision 1,
    /// not worth an off-main hop.
    private func ensureSubagentsWatcher(sessionID: String) {
        guard let state = sessions[sessionID], state.subagentsWatcher == nil else { return }
        let dirURL = ClaudeHome.subagentsDirURL(home: home, cwd: state.cwd, sessionID: sessionID)
        guard FileManager.default.fileExists(atPath: dirURL.path) else { return }  // retried on the next wake

        let fd = open(dirURL.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .extend, .rename, .delete], queue: .main)
        source.setEventHandler { [weak self] in self?.scanSubagentsDir(sessionID: sessionID) }
        source.setCancelHandler { close(fd) }
        state.subagentsWatcher = source
        source.resume()

        scanSubagentsDir(sessionID: sessionID)  // catch anything already there
    }

    /// Dir-event handler entry point — just snapshots what the off-main
    /// pass needs and schedules it; see decision 4 in the type doc
    /// comment for why the real work (listing, `stat`, conditional
    /// parse) doesn't happen here, on the main actor.
    private func scanSubagentsDir(sessionID: String) {
        guard let state = sessions[sessionID] else { return }
        let dirURL = ClaudeHome.subagentsDirURL(home: home, cwd: state.cwd, sessionID: sessionID)
        pendingScanCount += 1
        Self.dispatchScan(
            pool: self, sessionID: sessionID, dirURL: dirURL,
            priorMetaCache: state.metaCache, knownAgentIDs: Set(state.agentTailers.keys),
            queue: deliveryQueue)
    }

    /// Off-main: see decision 4 in the type doc comment. Plain GCD
    /// (`queue.async`) for the listing + `stat` + conditional parse,
    /// mirroring exactly how `ClaudeTranscriptTailer` already does its
    /// own off-main work before handing back to `transcriptCallback`/
    /// `agentCallback`'s `Task { @MainActor in }` hop — this uses that
    /// same hop shape for its own final delivery. Built from a
    /// `nonisolated` context for the same isolation-laundering reason as
    /// `transcriptCallback`/`agentCallback` above.
    nonisolated private static func dispatchScan(
        pool: FlowTailerPool, sessionID: String, dirURL: URL,
        priorMetaCache: [String: (mtime: Date, meta: SubagentMeta)], knownAgentIDs: Set<String>,
        queue: DispatchQueue
    ) {
        queue.async { [weak pool] in
            let result = scanDirectoryOffMain(
                dirURL: dirURL, priorMetaCache: priorMetaCache, knownAgentIDs: knownAgentIDs)
            // Re-strengthened into a per-invocation local before entering
            // the `Task` — same reasoning as `transcriptCallback`'s doc
            // comment (avoids reaching through the weak reference a
            // second time from within the closure).
            guard let pool else { return }
            Task { @MainActor in
                pool.applyScanResults(sessionID: sessionID, result: result)
                // Decremented last, in the same hop that applied the
                // result — see `pendingScanCount`'s doc for why a test
                // must drain this to zero before returning rather than
                // guessing with a fixed sleep.
                pool.pendingScanCount -= 1
            }
        }
    }

    /// The actual listing + `stat` + conditional parse, entirely off
    /// the main actor. `priorMetaCache`/`knownAgentIDs` are snapshots
    /// taken before this was scheduled — this only reads them and
    /// returns a `ScanResult`; nothing here touches pool or session
    /// state directly (that all happens back on main, in
    /// `applyScanResults`).
    nonisolated private static func scanDirectoryOffMain(
        dirURL: URL, priorMetaCache: [String: (mtime: Date, meta: SubagentMeta)], knownAgentIDs: Set<String>
    ) -> ScanResult {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dirURL, includingPropertiesForKeys: nil
        ) else {
            return ScanResult(metaCache: [:], metaEmissionOrder: [], agentModDates: [:], newAgentFiles: [], parsedCount: 0)
        }

        // ALWAYS re-emit every meta found here — never dedup `onMeta`
        // itself. `FlowStore` clears its toolUse↔agent joins whenever a
        // lane's session completes (including a stale replayed stop
        // that later self-heals), so a meta already delivered once may
        // need to reach the store again to re-establish that join;
        // `onMeta` is idempotent there (it re-sets the same fields), so
        // re-delivery on every scan costs nothing but a dictionary
        // write. Only the PARSE is gated by mtime (`metaCache`, below)
        // — dedup never applies to the `onMeta` call itself.
        var metaCache: [String: (mtime: Date, meta: SubagentMeta)] = [:]
        var metaEmissionOrder: [SubagentMeta] = []
        var parsedCount = 0
        for url in files where url.lastPathComponent.hasSuffix(".meta.json") {
            let name = url.lastPathComponent
            guard name.hasPrefix("agent-") else { continue }
            let agentID = String(name.dropFirst("agent-".count).dropLast(".meta.json".count))
            guard !agentID.isEmpty else { continue }

            let mtime = modificationDate(of: url)
            if let cached = priorMetaCache[agentID], cached.mtime == mtime {
                metaCache[agentID] = cached
                metaEmissionOrder.append(cached.meta)
            } else if let meta = SubagentMeta.parse(url: url) {
                parsedCount += 1
                metaCache[agentID] = (mtime, meta)
                metaEmissionOrder.append(meta)
            }
        }

        // Every agent file's mtime is refreshed here, live-agent or
        // not — this is what makes `enforceAgentTailerCap`'s ranking
        // real (see decision 3 in the type doc comment) rather than
        // frozen at discovery. The same stat call decides, via
        // `knownAgentIDs`, which files are new enough to register.
        var agentModDates: [String: Date] = [:]
        var newAgentFiles: [(agentID: String, url: URL)] = []
        for url in files where url.lastPathComponent.hasPrefix("agent-") && url.pathExtension == "jsonl" {
            let agentID = String(url.deletingPathExtension().lastPathComponent.dropFirst("agent-".count))
            guard !agentID.isEmpty else { continue }
            agentModDates[agentID] = modificationDate(of: url)
            if !knownAgentIDs.contains(agentID) {
                newAgentFiles.append((agentID: agentID, url: url))
            }
        }

        return ScanResult(
            metaCache: metaCache, metaEmissionOrder: metaEmissionOrder,
            agentModDates: agentModDates, newAgentFiles: newAgentFiles, parsedCount: parsedCount)
    }

    /// Back on main: applies one scan's results as a single atomic
    /// batch (see decision 4 in the type doc comment). Cache update +
    /// `onMeta` re-emission happen unconditionally (mirrors
    /// `handleTranscriptLines`/`handleAgentLines` forwarding a stray
    /// post-stop delivery) — but anything that would touch fds
    /// (registering a new tailer, `enforceAgentTailerCap` (re)starting
    /// one) is guarded on `isHot || isLazy`, since this session may
    /// have been stopped while the scan that produced `result` was
    /// still in flight off-main. Same guard shape as
    /// `handleTranscriptLines`'s.
    private func applyScanResults(sessionID: String, result: ScanResult) {
        metaParseCount += result.parsedCount
        guard let state = sessions[sessionID] else { return }
        state.metaCache = result.metaCache
        for meta in result.metaEmissionOrder { onMeta(sessionID, meta) }

        guard state.isHot || state.isLazy else { return }

        // Registered unconditionally — NOT started here. `init` opens no
        // fds, so it's safe to track every discovered file regardless of
        // the cap; `enforceAgentTailerCap` below decides which ones
        // actually get a live fd (see decision 3 in the type doc
        // comment). Re-checked against current state (not just the
        // pre-scan `knownAgentIDs` snapshot) in case a newer scan
        // already registered the same file first.
        for (agentID, url) in result.newAgentFiles where state.agentTailers[agentID] == nil {
            state.agentTailers[agentID] = ClaudeTranscriptTailer(
                url: url, deliveryQueue: deliveryQueue,
                onLines: Self.agentCallback(pool: self, sessionID: sessionID, agentID: agentID)
            )
        }
        for (agentID, mtime) in result.agentModDates {
            state.agentFileModDates[agentID] = mtime
        }
        enforceAgentTailerCap(state)
    }

    /// Everything one off-main scan produces, carried back across the
    /// `queue.async` -> `Task { @MainActor in }` hop as a single value
    /// so `applyScanResults` delivers it as one atomic, in-order batch.
    private struct ScanResult {
        /// Replaces `SessionState.metaCache` wholesale — a file no
        /// longer present in this scan's directory listing simply isn't
        /// carried forward (matching the pre-Group-4 behavior of only
        /// ever emitting for what's currently on disk).
        let metaCache: [String: (mtime: Date, meta: SubagentMeta)]
        /// Every meta this scan found, cached-or-freshly-parsed, in
        /// listing order — `applyScanResults` calls `onMeta` for each
        /// of these unconditionally.
        let metaEmissionOrder: [SubagentMeta]
        /// Freshly-`stat`'d mtime for every agent `.jsonl` file this
        /// scan found — feeds `enforceAgentTailerCap`'s dynamic ranking.
        let agentModDates: [String: Date]
        /// Agent files not already in `SessionState.agentTailers` as of
        /// when the scan STARTED — re-checked against current state in
        /// `applyScanResults` before actually registering.
        let newAgentFiles: [(agentID: String, url: URL)]
        /// How many meta files this scan actually re-parsed (mtime
        /// changed, or no cache entry yet) — feeds `metaParseCount`.
        let parsedCount: Int
    }

    nonisolated private static func modificationDate(of url: URL) -> Date {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let date = attrs[.modificationDate] as? Date
        else { return .distantPast }  // unreadable mtime: treat as oldest, never prioritized
        return date
    }

    /// Ranks every agent file this session has ever discovered by mtime
    /// (newest first — refreshed on every scan by `scanDirectoryOffMain`'s
    /// stat pass, so this ranking is live: a file that keeps growing
    /// rises, one that goes quiet falls) and keeps only the top
    /// `maxAgentTailersPerSession` live. Anything
    /// newly promoted into that top rank gets started: under `isLazy`,
    /// always a full replay from zero (same choice `ensureLazyTail`
    /// already makes for every live agent tailer); otherwise a FIRST
    /// promotion (never started before) gets `start(replayExisting:
    /// false)` — a fresh EOF-seek is correct, nothing was ever read
    /// from it — while a RE-promotion (this agentID was live before,
    /// then demoted) gets `resume()` instead, so it picks up from the
    /// offset preserved across that demotion instead of silently
    /// dropping everything written during the gap (the same
    /// offset-preserving contract `activateHot` relies on `resume()`
    /// for on the session transcript tailer). Anything that drops rank
    /// gets `stop()`ed (fds released) but keeps its `SessionState
    /// .agentTailers` entry, so its offset is there to resume from
    /// later. Called only from `applyScanResults`, after new candidates
    /// are registered — see decision 3 in the type doc comment for why
    /// registration and starting are split like this.
    private func enforceAgentTailerCap(_ state: SessionState) {
        let rankedNewestFirst = state.agentTailers.keys.sorted { lhs, rhs in
            let lhsDate = state.agentFileModDates[lhs] ?? .distantPast
            let rhsDate = state.agentFileModDates[rhs] ?? .distantPast
            return lhsDate != rhsDate ? lhsDate > rhsDate : lhs > rhs
        }
        let wantLive = Set(rankedNewestFirst.prefix(Self.maxAgentTailersPerSession))

        for agentID in state.liveAgentTailerIDs where !wantLive.contains(agentID) {
            state.agentTailers[agentID]?.stop()
        }
        for agentID in wantLive where !state.liveAgentTailerIDs.contains(agentID) {
            guard let tailer = state.agentTailers[agentID] else { continue }
            if state.isLazy {
                Self.replayFullHistory(pool: self, sessionID: state.sessionID, tailer: tailer)
            } else if state.everStartedAgentTailerIDs.contains(agentID) {
                tailer.resume()  // re-promotion: continue from the offset the prior demotion's stop() preserved
            } else {
                tailer.start(replayExisting: false)  // first promotion, hot only: EOF-seek, bounded (decision 1)
            }
            state.everStartedAgentTailerIDs.insert(agentID)
        }
        state.liveAgentTailerIDs = wantLive
    }
}

/// Per-session bookkeeping. Every mutation happens on the main actor —
/// this class isn't itself thread-safe, it just doesn't need to be:
/// `ioQueue`-style off-main work (only `replayFullHistory`) captures
/// Sendable values (the tailer, the session id) out of this object,
/// never the object itself.
private final class SessionState {
    let sessionID: String
    var cwd: String
    let transcriptTailer: ClaudeTranscriptTailer
    /// Whether `transcriptTailer` has ever been started before —
    /// decides whether the next hot activation is a cold `start` or an
    /// incremental `resume` (see `ClaudeTranscriptTailer.resume()`).
    var hasStartedTranscript = false
    var isHot = false
    var isLazy = false
    var subagentsWatcher: DispatchSourceFileSystemObject?
    /// Every agent tailer this pool has ever constructed for this
    /// session — entries are NEVER removed, even once capped out by
    /// `FlowTailerPool.enforceAgentTailerCap` or the session stops. The
    /// object itself (and so its internal read offset) is never
    /// discarded; whether that offset actually gets REUSED on a later
    /// re-promotion — instead of a fresh `start()` silently dropping
    /// everything written during the demotion gap — depends on
    /// `everStartedAgentTailerIDs` below.
    var agentTailers: [String: ClaudeTranscriptTailer] = [:]
    /// Mtime of each agent file as of the most recent scan — the
    /// recency signal `enforceAgentTailerCap` ranks `agentTailers` by.
    /// Refreshed every scan from `FlowTailerPool.scanDirectoryOffMain`'s
    /// stat pass, so ranking is live, not frozen at discovery (see
    /// `enforceAgentTailerCap`'s doc).
    var agentFileModDates: [String: Date] = [:]
    /// Cached parse of every meta file this session's subagents dir
    /// currently contains, keyed by agent ID, alongside the mtime it
    /// was parsed at. `FlowTailerPool.scanDirectoryOffMain` reparses an
    /// entry only when its file's mtime has changed since this was last
    /// updated (see `FlowTailerPool.metaParseCount`) — but every entry
    /// present in a given scan's directory listing is still re-emitted
    /// via `onMeta` unconditionally regardless (see
    /// `scanDirectoryOffMain`'s comment).
    var metaCache: [String: (mtime: Date, meta: SubagentMeta)] = [:]
    /// Subset of `agentTailers.keys` currently holding a live fd pair,
    /// bounded by `FlowTailerPool.maxAgentTailersPerSession`. Every
    /// resume/revive/replay path is scoped to this set — an ID dropped
    /// from it by the cap stays in `agentTailers` (stopped, offset
    /// preserved) but is otherwise left alone until a fresh
    /// `enforceAgentTailerCap` ranking (triggered by newly-discovered
    /// files) puts it back in.
    var liveAgentTailerIDs: Set<String> = []
    /// Agent IDs `enforceAgentTailerCap` has ever called `start()` (or
    /// `replayFullHistory`, which itself calls `start()`) on at least
    /// once. Lets it tell a first-time promotion (no established
    /// offset yet — a fresh `start(replayExisting: false)` is correct)
    /// from a RE-promotion (previously live, then demoted by the cap —
    /// must `resume()` to continue from the offset that demotion's
    /// `stop()` preserved, rather than re-seeking to a fresh EOF and
    /// silently dropping the demotion-gap's lines).
    var everStartedAgentTailerIDs: Set<String> = []

    init(sessionID: String, cwd: String, transcriptTailer: ClaudeTranscriptTailer) {
        self.sessionID = sessionID
        self.cwd = cwd
        self.transcriptTailer = transcriptTailer
    }

    /// Fd-leak backstop for `subagentsWatcher`, mirroring
    /// `ClaudeTranscriptTailer.deinit`'s reasoning. `SessionState`
    /// entries are never removed from `FlowTailerPool.sessions` during
    /// normal operation (see `agentTailers`'s doc above), so this only
    /// fires when the whole pool is deallocated — e.g. its owning
    /// project window closes — without it, a still-resumed watcher
    /// source would leak its fd. Same accepted stray-callback race as
    /// `FlowTailerPool.handleTranscriptLines`'s `isHot`/`isLazy` guard:
    /// an event already in flight when the pool itself is torn down
    /// can't land anywhere, since nothing retains this `SessionState`
    /// to call back into once deinit starts.
    deinit {
        subagentsWatcher?.cancel()
    }
}
