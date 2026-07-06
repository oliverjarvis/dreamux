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
        // Deliberately excludes sessions just activated above — those
        // already got their own `start()`/`resume()` this very poll, so
        // re-checking them here would only interrupt their own
        // just-scheduled retry for no benefit.
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
        for agentTailer in state.agentTailers.values where agentTailer.isDormant {
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
        for agentTailer in state.agentTailers.values { agentTailer.resume() }
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
        for agentTailer in state.agentTailers.values {
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
        guard sessions[sessionID] != nil else { return }
        onTranscriptLines(sessionID, lines)
        // The subagents dir may not exist yet — claude creates it
        // lazily, only once the session's first subagent spawns.
        // Rather than watching a path that doesn't exist, retry the
        // listing on every transcript wake, which happens whenever the
        // session does anything at all (see `ensureSubagentsWatcher`).
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

        for url in files where url.lastPathComponent.hasPrefix("agent-") && url.pathExtension == "jsonl" {
            let agentID = String(url.deletingPathExtension().lastPathComponent.dropFirst("agent-".count))
            guard !agentID.isEmpty, state.agentTailers[agentID] == nil else { continue }
            let tailer = ClaudeTranscriptTailer(
                url: url, deliveryQueue: deliveryQueue,
                onLines: Self.agentCallback(pool: self, sessionID: sessionID, agentID: agentID)
            )
            state.agentTailers[agentID] = tailer
            if state.isLazy {
                Self.replayFullHistory(pool: self, sessionID: sessionID, tailer: tailer)
            } else {
                tailer.start(replayExisting: false)  // hot only: EOF-seek, bounded (decision 1)
            }
        }
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
    var agentTailers: [String: ClaudeTranscriptTailer] = [:]

    init(sessionID: String, cwd: String, transcriptTailer: ClaudeTranscriptTailer) {
        self.sessionID = sessionID
        self.cwd = cwd
        self.transcriptTailer = transcriptTailer
    }
}
