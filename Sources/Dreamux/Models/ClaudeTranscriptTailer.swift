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
    }

    /// `onLines` isn't required to be `@Sendable` by this class's public
    /// signature, but handing it to `deliveryQueue.async` crosses a
    /// concurrency-domain boundary the compiler wants proof of safety
    /// for. This class already asserts that safety via `@unchecked
    /// Sendable`; boxing the closure carries that same assertion down
    /// to this one call site instead of loosening the public `init`.
    private struct Box: @unchecked Sendable {
        let f: ([String]) -> Void
    }

    init(url: URL, deliveryQueue: DispatchQueue, onLines: @escaping ([String]) -> Void) {
        self.url = url
        self.deliveryQueue = deliveryQueue
        self.onLines = onLines
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
        partial.removeAll(keepingCapacity: false)
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

    private func tearDownCurrentWatch() {
        source?.cancel()
        source = nil
        try? readHandle?.close()
        readHandle = nil
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
        offset = offsetMode == .zero ? 0 : (fstatOK ? UInt64(st.st_size) : 0)
        partial.removeAll(keepingCapacity: false)

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
            partial.removeAll(keepingCapacity: false)
        }

        readAvailable()

        if events.contains(.delete) || events.contains(.rename) {
            tearDownCurrentWatch()
            retryOnceOrGoDormant(offsetMode: .zero)
        }
    }

    /// Reads from `offset` to EOF in `chunkSize` chunks, splitting on
    /// `\n`. Buffers a trailing partial line across wakes (dropped with
    /// the buffer reset if it grows past `partialCapBytes`). Delivers
    /// at most `lineBatchCap` lines per call; if more were already
    /// buffered or on disk, re-arms immediately (via the queue, not a
    /// real kqueue wake) so the backlog drains without waiting for
    /// another write.
    private func readAvailable() {
        guard !isStopped, let handle = readHandle else { return }
        var batch: [String] = []

        readLoop: while true {
            while let newlineIndex = partial.firstIndex(of: 0x0A) {
                if batch.count >= Self.lineBatchCap { break readLoop }
                let lineData = partial[partial.startIndex..<newlineIndex]
                batch.append(String(decoding: lineData, as: UTF8.self))
                partial.removeSubrange(partial.startIndex...newlineIndex)
            }
            if batch.count >= Self.lineBatchCap { break }

            try? handle.seek(toOffset: offset)
            guard let chunk = try? handle.read(upToCount: Self.chunkSize), !chunk.isEmpty else {
                break
            }
            offset += UInt64(chunk.count)
            partial.append(chunk)
            if partial.count > Self.partialCapBytes {
                partial.removeAll(keepingCapacity: false)
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

// Accepted race: `readAvailable()` hands a batch to `deliveryQueue`
// via `.async` before returning. If `stop()` runs (on `queue`) after
// that hand-off but before the delivery queue executes it, the
// already-queued `onLines` call still fires once — its captured
// `lines`/`box` don't depend on any tailer state, so this is safe,
// just an extra delivery after the logical stop point. Same
// accepted-race shape as `ClaudeRegistryPoller`'s callers: teardown of
// the consumer (not a callback guard here) is what makes this fine to
// leave unclosed rather than adding synchronization overhead for a
// once-per-stop, non-corrupting race.
