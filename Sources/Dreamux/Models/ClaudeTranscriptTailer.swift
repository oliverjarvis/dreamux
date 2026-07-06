import Foundation
import Darwin

/// Tails ONE append-only file (a Claude session transcript `.jsonl`)
/// via a kqueue `DispatchSource`, delivering newly-appended lines as
/// they land. Not `@MainActor` — `init`/`start`/`stop` may be called
/// from any thread (they're internally serialized onto a private
/// utility queue); `onLines` is always delivered on the caller-supplied
/// `deliveryQueue`.
///
/// Mirrors the fd/DispatchSource idiom of `DocStore.rebuildWatchers`
/// (open the path `O_EVTONLY`, watch `.write/.extend/.rename/.delete`),
/// but reads incrementally from a stored byte offset instead of
/// rescanning, since transcripts can grow to megabytes over a long
/// session.
final class ClaudeTranscriptTailer: @unchecked Sendable {
    private let url: URL
    private let deliveryQueue: DispatchQueue
    private let onLines: ([String]) -> Void
    /// Fires once per `partialCapBytes` overflow, with the byte count
    /// of the newline-less remainder that was dropped (see
    /// `readAvailable`). `nil` by default so existing callers are
    /// unaffected; delivered on `deliveryQueue` exactly like `onLines`.
    private let onDroppedBytes: ((Int) -> Void)?

    /// All mutable state below is confined to this serial queue. Public
    /// `start`/`stop` calls dispatch onto it (synchronously, so a test
    /// or caller can rely on the read offset already being established
    /// — e.g. "seek to EOF" — before doing anything that would race it,
    /// like appending to the file).
    private let queue: DispatchQueue

    private var readHandle: FileHandle?
    private var source: DispatchSourceFileSystemObject?
    private var offset: UInt64 = 0
    private var partial = Data()
    /// Set when a cap overflow drops a still-growing, newline-less
    /// remainder (see `readAvailable`) without ever having seen that
    /// line's own terminator. The next `\n` found afterward closes off
    /// bytes that are the ORPHANED TAIL of the abandoned line, not the
    /// start of a new one — `drainCompleteLines` discards that one
    /// segment (not delivered, not itself counted as a further drop)
    /// and clears this flag, resuming normal delivery from the
    /// following byte. Left untouched by `resume()`, exactly like
    /// `partial`/`offset` — a drop that happened before a `stop()`
    /// still has an orphaned tail to discard once watching resumes.
    private var isRecoveringFromDrop = false
    /// `true` when not currently watching — covers both "never started"
    /// and "explicitly stopped". Stays `false` while dormant between a
    /// rotation and its retry (that's still a "started" session, just
    /// between fds).
    private var isStopped = true
    /// One reopen retry is allowed per disruption (initial missing file,
    /// or a `.delete`/`.rename` mid-tail); reset to `false` whenever a
    /// `start()` call or a successful reopen establishes a new baseline.
    private var didAttemptRetryOpen = false
    private var retryWorkItem: DispatchWorkItem?

    private static let chunkSize = 65_536
    private static let lineBatchCap = 2_000
    private static let partialCapBytes = 1_048_576
    private static let reopenRetryDelay: TimeInterval = 0.5

    private enum InitialOffsetMode {
        case zero
        case endOfFile
        /// Keep whatever `offset`/`partial` already hold — used by
        /// `resume()` to continue incrementally after a `stop()`,
        /// rather than re-seeking. See `resume()`'s doc comment.
        case preserveCurrent
    }

    /// `onLines`/`onDroppedBytes` aren't required to be `@Sendable` by
    /// this class's public signature, but handing either to
    /// `deliveryQueue.async` crosses a concurrency-domain boundary the
    /// compiler wants proof of safety for. This class already asserts
    /// that safety via `@unchecked Sendable`; boxing the closure
    /// carries that same assertion down to each call site instead of
    /// loosening the public `init`. Generic so both callback shapes
    /// share one box type.
    private struct Box<T>: @unchecked Sendable {
        let f: (T) -> Void
    }

    init(
        url: URL, deliveryQueue: DispatchQueue,
        onLines: @escaping ([String]) -> Void,
        onDroppedBytes: ((Int) -> Void)? = nil
    ) {
        self.url = url
        self.deliveryQueue = deliveryQueue
        self.onLines = onLines
        self.onDroppedBytes = onDroppedBytes
        self.queue = DispatchQueue(label: "com.dreamux.claude.transcript-tailer")
    }

    /// - Parameter replayExisting: `true` reads the whole file from
    ///   byte 0 (lazy-zoom into a transcript that already has content);
    ///   `false` seeks to the current EOF and only delivers lines
    ///   appended from here on.
    func start(replayExisting: Bool) {
        // Public API must never be called from the internal queue — sync
        // would deadlock (a queue can't wait on itself).
        dispatchPrecondition(condition: .notOnQueue(queue))
        queue.sync { self.startOnQueue(replayExisting: replayExisting) }
    }

    func stop() {
        dispatchPrecondition(condition: .notOnQueue(queue))
        queue.sync { self.stopOnQueue() }
    }

    /// Restarts watching from the offset a PRIOR `start()` established
    /// (`stopOnQueue()` deliberately never touches `offset`/`partial`),
    /// instead of resetting to zero or EOF like `start()` always does.
    /// Used when a session leaves the hot set (`stop()`) and later
    /// re-enters it (e.g. FlowTailerPool's reconcile): re-entry should
    /// pick up where it left off, not skip straight back to the new
    /// EOF (which would silently drop anything written during the
    /// gap) or replay the whole file again from byte 0. If this tailer
    /// was never started before, `offset` is still its initial 0, so
    /// this behaves like a cold `start(replayExisting: true)`.
    ///
    /// Rotation-while-stopped safety: since there's no fd open (and so
    /// no `.delete`/`.rename` event could have fired) during the gap,
    /// a same-path rotation that happened while stopped is caught here
    /// the same way live truncation is — if the reopened file is
    /// smaller than the stored offset, treat it as rotated and replay
    /// from zero instead of reading past EOF into nothing.
    func resume() {
        dispatchPrecondition(condition: .notOnQueue(queue))
        queue.sync { self.resumeOnQueue() }
    }

    /// True when this tailer believes it should be watching (`start()`/
    /// `resume()` was called and `stop()` hasn't been since) but
    /// currently has no live kqueue source — either mid-wait for its one
    /// reopen retry, or fully given up after that retry also failed (see
    /// `retryOnceOrGoDormant`). Both cases are the same thing to a
    /// caller: nothing will re-attempt opening the file until an
    /// explicit `resume()` (safe to call in either sub-state — it always
    /// tears down and retries immediately, so it can only help, never
    /// duplicate work). `FlowTailerPool.reconcile` reads this on every
    /// poll to revive an already-hot session's tailer that never got a
    /// live fd (its transcript file didn't exist yet when the session
    /// first went hot). Same not-on-queue precondition family as
    /// `start`/`stop`/`resume` above — this is a read, not a mutation,
    /// but it still must not run ON the tailer's own serial queue (that
    /// would deadlock `queue.sync` the same way a nested `start()` would).
    var isDormant: Bool {
        dispatchPrecondition(condition: .notOnQueue(queue))
        return queue.sync { !isStopped && source == nil }
    }

    deinit {
        // No other strong reference can exist once deinit runs (every
        // closure captures `self` weakly), so touching the
        // otherwise queue-confined state directly here can't race a
        // concurrent start()/stop()/event-handler call — this is a
        // fd-leak backstop; callers should still call stop() themselves.
        source?.cancel()
        try? readHandle?.close()
    }

    // MARK: - queue-confined

    private func startOnQueue(replayExisting: Bool) {
        tearDownCurrentWatch()
        retryWorkItem?.cancel()
        retryWorkItem = nil

        isStopped = false
        didAttemptRetryOpen = false
        resetPartialBuffer()
        offset = 0

        attemptOpen(offsetMode: replayExisting ? .zero : .endOfFile)
    }

    private func stopOnQueue() {
        guard !isStopped else { return }
        isStopped = true
        retryWorkItem?.cancel()
        retryWorkItem = nil
        tearDownCurrentWatch()
    }

    private func resumeOnQueue() {
        tearDownCurrentWatch()
        retryWorkItem?.cancel()
        retryWorkItem = nil

        isStopped = false
        didAttemptRetryOpen = false
        // Deliberately no `offset = 0` / `partial.removeAll()` here —
        // that's the entire difference from `startOnQueue`.

        attemptOpen(offsetMode: .preserveCurrent)
    }

    private func tearDownCurrentWatch() {
        source?.cancel()
        source = nil
        try? readHandle?.close()
        readHandle = nil
    }

    /// Every reset point that establishes a fresh, known-clean read
    /// boundary (a cold start, a fresh EOF-seek, or a detected
    /// truncation) clears `isRecoveringFromDrop` alongside `partial` —
    /// there's nothing orphaned to discard once reading resumes from a
    /// boundary like that. The one place that intentionally does NOT
    /// call this is the cap-overflow drop itself (`readAvailable`),
    /// which clears `partial` but SETS the flag instead.
    private func resetPartialBuffer() {
        partial.removeAll(keepingCapacity: false)
        isRecoveringFromDrop = false
    }

    /// Opens the read handle + event source and establishes `offset`
    /// per `offsetMode`. On failure (file doesn't exist yet, or the
    /// event fd can't be opened) hands off to the one-shot retry.
    private func attemptOpen(offsetMode: InitialOffsetMode) {
        guard !isStopped else { return }
        guard let handle = FileHandle(forReadingAtPath: url.path) else {
            retryOnceOrGoDormant(offsetMode: offsetMode)
            return
        }

        var st = stat()
        let fstatOK = fstat(handle.fileDescriptor, &st) == 0
        switch offsetMode {
        case .zero:
            offset = 0
            resetPartialBuffer()
        case .endOfFile:
            offset = fstatOK ? UInt64(st.st_size) : 0
            resetPartialBuffer()
        case .preserveCurrent:
            // Same truncation semantics as a live wake (see
            // `handleEvent`): if the file we just reopened is smaller
            // than where we left off, it was rotated/truncated while
            // we weren't watching — replay it from the start instead
            // of seeking past its new EOF.
            if fstatOK, UInt64(st.st_size) < offset {
                offset = 0
                resetPartialBuffer()
            }
        }

        let eventFD = open(url.path, O_EVTONLY)
        guard eventFD >= 0 else {
            try? handle.close()
            retryOnceOrGoDormant(offsetMode: offsetMode)
            return
        }

        readHandle = handle
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: eventFD,
            eventMask: [.write, .extend, .rename, .delete],
            queue: queue)
        src.setEventHandler { [weak self] in self?.handleEvent() }
        // SOLE owner of the event fd's close, run exactly once by GCD
        // after any in-flight event handler invocation completes.
        src.setCancelHandler { close(eventFD) }
        source = src
        src.resume()

        didAttemptRetryOpen = false
        readAvailable()
    }

    /// `.delete`/`.rename` or a missing file at open time each get one
    /// 500 ms-later reopen attempt (session dirs sometimes appear before
    /// their files); a second consecutive failure goes dormant until
    /// the next explicit `start()`.
    private func retryOnceOrGoDormant(offsetMode: InitialOffsetMode) {
        guard !isStopped, !didAttemptRetryOpen else { return }
        didAttemptRetryOpen = true
        let workItem = DispatchWorkItem { [weak self] in
            self?.attemptOpen(offsetMode: offsetMode)
        }
        retryWorkItem = workItem
        queue.asyncAfter(deadline: .now() + Self.reopenRetryDelay, execute: workItem)
    }

    private func handleEvent() {
        guard !isStopped, let handle = readHandle, let source else { return }
        let events = source.data

        // Truncation detection only. This fstat runs on the read fd we
        // already have open, which stays pinned to its vnode regardless
        // of what happens to the path — it can never observe an inode
        // change. A same-path rotation instead arrives as a
        // `.delete`/`.rename` vnode event, handled below by the retry path.
        var st = stat()
        if fstat(handle.fileDescriptor, &st) == 0, UInt64(st.st_size) < offset {
            offset = 0
            resetPartialBuffer()
        }

        readAvailable()

        if events.contains(.delete) || events.contains(.rename) {
            tearDownCurrentWatch()
            retryOnceOrGoDormant(offsetMode: .zero)
        }
    }

    /// Reads from `offset` to EOF in `chunkSize` chunks, splitting on
    /// `\n`. Buffers a trailing partial line across wakes. Every
    /// complete line already in `partial` is drained into `batch`
    /// BEFORE the cap check below runs — only the newline-less
    /// REMAINDER (the start of a line still being written) ever counts
    /// against `partialCapBytes`, so a single complete line bigger than
    /// the cap, or complete lines that land in the same chunk as one,
    /// are still delivered whole rather than discarded along with an
    /// unrelated overflow. Only that remainder is dropped — reporting
    /// its size via `onDroppedBytes` — if it grows past the cap. The
    /// bytes between the drop and the abandoned line's OWN eventual
    /// `\n` (however many more chunks that takes to arrive) are an
    /// orphaned tail, not a real line — `isRecoveringFromDrop` makes
    /// `drainCompleteLines` discard exactly that one segment instead of
    /// delivering it as a phantom line. Delivers at most `lineBatchCap`
    /// lines per call; if more were already buffered or on disk,
    /// re-arms immediately (via the queue, not a real kqueue wake) so
    /// the backlog drains without waiting for another write.
    private func readAvailable() {
        guard !isStopped, let handle = readHandle else { return }
        var batch: [String] = []

        // Extracts every complete line currently in `partial` into
        // `batch`, returning `true` (and leaving any remaining complete
        // lines for the next call) the moment `batch` hits
        // `lineBatchCap`. Called both before the first read this call
        // (drains anything left over from a prior batch-cap break) and
        // again right after every chunk append (drains whatever that
        // chunk just completed) — see this method's doc comment for why
        // the second call site is what makes the cap check below safe.
        // The very first segment closed off while `isRecoveringFromDrop`
        // is set is discarded rather than appended — it's the orphaned
        // tail of a line already reported as dropped, not new content —
        // and doesn't count against `lineBatchCap` (discarding costs
        // nothing, so it shouldn't defer real lines behind it).
        func drainCompleteLines() -> Bool {
            while let newlineIndex = partial.firstIndex(of: 0x0A) {
                if isRecoveringFromDrop {
                    // Discard unconditionally — before the batch-cap
                    // check, since this costs nothing and must not defer
                    // a real line behind it (see this method's doc
                    // comment).
                    partial.removeSubrange(partial.startIndex...newlineIndex)
                    isRecoveringFromDrop = false
                    continue
                }
                if batch.count >= Self.lineBatchCap { return true }
                let lineData = partial[partial.startIndex..<newlineIndex]
                batch.append(String(decoding: lineData, as: UTF8.self))
                partial.removeSubrange(partial.startIndex...newlineIndex)
            }
            return false
        }

        readLoop: while true {
            if drainCompleteLines() { break readLoop }

            try? handle.seek(toOffset: offset)
            guard let chunk = try? handle.read(upToCount: Self.chunkSize), !chunk.isEmpty else {
                break
            }
            offset += UInt64(chunk.count)
            partial.append(chunk)

            if drainCompleteLines() { break readLoop }

            if partial.count > Self.partialCapBytes {
                let droppedBytes = partial.count
                // NOT `resetPartialBuffer()` — this is the one place
                // that intentionally SETS `isRecoveringFromDrop` rather
                // than clearing it, since the abandoned line's own
                // terminator hasn't been seen yet.
                partial.removeAll(keepingCapacity: false)
                isRecoveringFromDrop = true
                if let onDroppedBytes {
                    let box = Box(f: onDroppedBytes)
                    deliveryQueue.async { box.f(droppedBytes) }
                }
            }
        }

        if !batch.isEmpty {
            let lines = batch
            let box = Box(f: onLines)
            deliveryQueue.async { box.f(lines) }
        }

        // Hitting the cap means more may remain (either still-buffered
        // full lines or more bytes on disk); re-arm to drain it. If
        // nothing remains, this no-ops on the next call.
        if batch.count >= Self.lineBatchCap {
            queue.async { [weak self] in self?.readAvailable() }
        }
    }
}

// Accepted race: `readAvailable()` hands a batch (or a drop's byte
// count) to `deliveryQueue` via `.async` before returning. If `stop()`
// runs (on `queue`) after that hand-off but before the delivery queue
// executes it, the already-queued `onLines`/`onDroppedBytes` call
// still fires once — its captured `lines`/`droppedBytes`/`box` don't
// depend on any tailer state, so this is safe, just an extra delivery
// after the logical stop point. Same
// accepted-race shape as `ClaudeRegistryPoller`'s callers: teardown of
// the consumer (not a callback guard here) is what makes this fine to
// leave unclosed rather than adding synchronization overhead for a
// once-per-stop, non-corrupting race. When the consumer is
// `FlowTailerPool`, this is exactly the race its
// `handleTranscriptLines` guards against re-triggering
// `ensureSubagentsWatcher` for: the stray delivery itself is fine to
// forward, but any side effect beyond that must check `isHot`/`isLazy`
// first.
