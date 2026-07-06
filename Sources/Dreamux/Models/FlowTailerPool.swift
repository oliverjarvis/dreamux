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
///    files once `enforceAgentTailerCap` re-ranks everything this
///    session has ever discovered. Anything that drops out of that
///    ranking gets `stop()`ed (fds released) but keeps its
///    `agentTailers` entry, so its read offset survives. Because
///    nothing is started until it's already ranked, an outlier session
///    directory with far more subagents than the cap never transiently
///    exceeds it mid-scan — see `maxAgentTailersPerSession`'s doc for
///    the concrete fd math.
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

    private var sessions: [String: SessionState] = [:]

    init(
        home: URL,
        onTranscriptLines: @escaping (_ sessionID: String, _ lines: [String]) -> Void,
        onAgentLines: @escaping (_ sessionID: String, _ agentID: String, _ lines: [String]) -> Void,
        onMeta: @escaping (_ sessionID: String, _ meta: SubagentMeta) -> Void
    ) {
        self.home = home
        self.onTranscriptLines = onTranscriptLines
        self.onAgentLines = onAgentLines
        self.onMeta = onMeta
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
            onLines: Self.transcriptCallback(pool: self, sessionID: sessionID)
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

    private func scanSubagentsDir(sessionID: String) {
        guard let state = sessions[sessionID] else { return }
        let dirURL = ClaudeHome.subagentsDirURL(home: home, cwd: state.cwd, sessionID: sessionID)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dirURL, includingPropertiesForKeys: nil
        ) else { return }

        // ALWAYS re-emit every meta found here — never dedup `onMeta`
        // itself. `FlowStore` clears its toolUse↔agent joins whenever a
        // lane's session completes (including a stale replayed stop
        // that later self-heals), so a meta already delivered once may
        // need to reach the store again to re-establish that join;
        // `onMeta` is idempotent there (it re-sets the same fields), so
        // re-delivery on every scan costs nothing but a dictionary
        // write. Dedup only matters below, for spawning tailers.
        for url in files where url.lastPathComponent.hasSuffix(".meta.json") {
            guard let meta = SubagentMeta.parse(url: url) else { continue }
            onMeta(sessionID, meta)
        }

        // Registered unconditionally — NOT started here. `init` opens no
        // fds, so it's safe to track every discovered file regardless of
        // the cap; `enforceAgentTailerCap` below decides which ones
        // actually get a live fd (see decision 3 in the type doc
        // comment).
        for url in files where url.lastPathComponent.hasPrefix("agent-") && url.pathExtension == "jsonl" {
            let agentID = String(url.deletingPathExtension().lastPathComponent.dropFirst("agent-".count))
            guard !agentID.isEmpty, state.agentTailers[agentID] == nil else { continue }
            state.agentTailers[agentID] = ClaudeTranscriptTailer(
                url: url, deliveryQueue: deliveryQueue,
                onLines: Self.agentCallback(pool: self, sessionID: sessionID, agentID: agentID)
            )
            state.agentFileModDates[agentID] = Self.modificationDate(of: url)
        }
        enforceAgentTailerCap(state)
    }

    private static func modificationDate(of url: URL) -> Date {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let date = attrs[.modificationDate] as? Date
        else { return .distantPast }  // unreadable mtime: treat as oldest, never prioritized
        return date
    }

    /// Re-ranks every agent file this session has ever discovered by
    /// mtime (newest first) and keeps only the top
    /// `maxAgentTailersPerSession` live: anything newly in that top
    /// rank gets started (EOF-seek if hot, full replay if lazy — same
    /// per-tailer choice `scanSubagentsDir` used to make inline);
    /// anything that drops out gets `stop()`ed. `SessionState
    /// .agentTailers` entries are never removed either way, so a
    /// stopped tailer's read offset survives. Called only from
    /// `scanSubagentsDir`, after new candidates are registered — see
    /// decision 3 in the type doc comment for why registration and
    /// starting are split like this.
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
            } else {
                tailer.start(replayExisting: false)  // hot only: EOF-seek, bounded (decision 1)
            }
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
    /// `FlowTailerPool.enforceAgentTailerCap` or the session stops, so
    /// a stopped tailer's read offset survives for whenever it might
    /// matter again.
    var agentTailers: [String: ClaudeTranscriptTailer] = [:]
    /// Mtime of each agent file at discovery time — the recency signal
    /// `enforceAgentTailerCap` ranks `agentTailers` by.
    var agentFileModDates: [String: Date] = [:]
    /// Subset of `agentTailers.keys` currently holding a live fd pair,
    /// bounded by `FlowTailerPool.maxAgentTailersPerSession`. Every
    /// resume/revive/replay path is scoped to this set — an ID dropped
    /// from it by the cap stays in `agentTailers` (stopped, offset
    /// preserved) but is otherwise left alone until a fresh
    /// `enforceAgentTailerCap` ranking (triggered by newly-discovered
    /// files) puts it back in.
    var liveAgentTailerIDs: Set<String> = []

    init(sessionID: String, cwd: String, transcriptTailer: ClaudeTranscriptTailer) {
        self.sessionID = sessionID
        self.cwd = cwd
        self.transcriptTailer = transcriptTailer
    }
}
