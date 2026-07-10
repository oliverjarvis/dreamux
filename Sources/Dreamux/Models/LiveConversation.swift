import Foundation
import Observation

/// A live view over one Claude session transcript: parses what's
/// already on disk, then tails appends via a vnode watcher. Explicit
/// lifecycle — the owner (ClaudeSessionBinding) calls `stop()` when the
/// binding is replaced or torn down; deinit closes raw descriptors as a
/// backstop. Retries until the file exists: SessionStart can fire
/// before claude's first transcript flush.
@MainActor
@Observable
final class LiveConversation {
    private(set) var items: [TranscriptItem] = []
    private(set) var pendingQuestion: TranscriptAccumulator.PendingQuestion?
    private(set) var fileFound = false

    let url: URL
    @ObservationIgnored private let accumulator = TranscriptAccumulator()
    @ObservationIgnored private var readHandle: FileHandle?
    @ObservationIgnored private nonisolated(unsafe) var watchFD: Int32 = -1
    @ObservationIgnored private nonisolated(unsafe) var source: DispatchSourceFileSystemObject?
    @ObservationIgnored private var retryTimer: Timer?

    init(url: URL) {
        self.url = url
        openOrRetry()
    }

    deinit {
        source?.cancel()
        if watchFD >= 0 { close(watchFD) }
    }

    func stop() {
        retryTimer?.invalidate()
        retryTimer = nil
        source?.cancel()
        source = nil
        if watchFD >= 0 { close(watchFD) }
        watchFD = -1
        try? readHandle?.close()
        readHandle = nil
    }

    private func openOrRetry() {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            retryTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
                Task { @MainActor in self?.openOrRetry() }
            }
            return
        }
        fileFound = true
        readHandle = handle
        watchFD = open(url.path, O_EVTONLY)
        if watchFD >= 0 {
            let src = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: watchFD, eventMask: [.write, .extend], queue: .main)
            src.setEventHandler { [weak self] in self?.drain() }
            src.resume()
            source = src
        }
        drain()
    }

    private func drain() {
        guard let handle = readHandle,
              let data = try? handle.readToEnd(), !data.isEmpty else { return }
        let new = accumulator.feed(data)
        if !new.isEmpty { items.append(contentsOf: new) }
        pendingQuestion = accumulator.pendingQuestion
    }
}
