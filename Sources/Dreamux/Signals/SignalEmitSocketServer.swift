import Foundation
import Darwin
import Combine

/// Unix-domain socket the dreamux-signals MCP bridge connects to so
/// external clients (Claude Code sessions, scripts, future HTTP API,
/// …) can write signals into the bus alongside their reads.
///
/// Protocol: newline-delimited JSON. Each connection handles one
/// request then closes — keeps the surface dumb and avoids
/// long-running connection bookkeeping. Request shape:
///
///     { "action": "emit",
///       "signal": {
///         "kind":     "<required>",
///         "source":   "<optional, defaults to 'external'>",
///         "severity": "info|success|warning|critical",
///         "tags":     { "k": "v", ... },
///         "payload":  <any JSON>
///       } }
///
/// Response (newline-terminated JSON):
///
///     { "ok": true, "id": "<assigned signal id>" }
///     { "ok": false, "error": "<reason>" }
///
/// The socket lives next to `signals.db` under the app's bundle-id
/// dir so the MCP bridge can find it via the same scan logic.
///
/// Implementation note: we use BSD sockets (`socket(2)` etc.) rather
/// than Network.framework because `NWListener` doesn't have
/// first-class Unix-domain support — the workarounds (custom
/// `NWProtocolStack`) are more code than the C API directly.
final class SignalEmitSocketServer: @unchecked Sendable {
    private let bus: SignalBus
    private let acceptQueue: DispatchQueue
    private let workQueue: DispatchQueue
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var socketPath: String = ""

    init(bus: SignalBus) {
        self.bus = bus
        self.acceptQueue = DispatchQueue(label: "dreamux.signals.emit-socket.accept", qos: .utility)
        self.workQueue = DispatchQueue(label: "dreamux.signals.emit-socket.work", qos: .utility, attributes: .concurrent)
    }

    /// Emit-socket path. Delegates to `BundleIdentity` so bind
    /// (`SignalBus`), export (`PTYShellSession`), and the
    /// `DREAMUX_EMIT_SOCKET` override all share one source of truth.
    /// `/tmp` keeps `sun_path` under its 104-byte cap.
    static func defaultSocketPath() -> String {
        BundleIdentity.emitSocketPath()
    }

    /// Start (or restart) the listener. Idempotent — calling twice
    /// closes the previous fd and re-binds.
    func start(path: String) {
        stop()
        // Unix sockets can't re-bind a path that already exists;
        // unlink any stale file from a previous run.
        unlink(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            NSLog("SignalEmitSocketServer: socket() failed errno=%d", errno)
            return
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        // sun_path is a fixed-size C array of CChar; copy the
        // path bytes in carefully.
        let pathBytes = path.utf8CString
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
        guard pathBytes.count <= maxLen else {
            NSLog("SignalEmitSocketServer: socket path too long (%d > %d)", pathBytes.count, maxLen)
            close(fd)
            return
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { sunPath in
            sunPath.withMemoryRebound(to: CChar.self, capacity: maxLen) { dst in
                pathBytes.withUnsafeBufferPointer { src in
                    if let base = src.baseAddress {
                        dst.update(from: base, count: pathBytes.count)
                    }
                }
            }
        }

        // sockaddr_un (~106 bytes) is much larger than sockaddr
        // (~16 bytes), so `withMemoryRebound` would fail Swift's
        // stride-equality check. Use raw-pointer reinterpretation
        // instead — that's the canonical idiom for the BSD socket
        // type-punning dance.
        let bindResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
            let raw = UnsafeRawPointer(ptr)
            let sa = raw.assumingMemoryBound(to: sockaddr.self)
            return Darwin.bind(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
        guard bindResult == 0 else {
            NSLog("SignalEmitSocketServer: bind() failed errno=%d", errno)
            close(fd)
            return
        }

        // Tighten permissions: the user is the only legitimate
        // writer; nothing else on the box should be dropping
        // signals into the bus.
        chmod(path, 0o600)

        guard listen(fd, 16) == 0 else {
            NSLog("SignalEmitSocketServer: listen() failed errno=%d", errno)
            close(fd)
            return
        }

        self.listenFD = fd
        self.socketPath = path

        // Accept loop driven by a DispatchSource so we don't
        // block a thread on accept(). Each accepted connection
        // is handed off to the concurrent work queue.
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: acceptQueue)
        source.setEventHandler { [weak self] in
            self?.acceptOne()
        }
        // SOLE owner of the listen fd's close. Cancellation is the one
        // point where GCD guarantees the event handler can no longer
        // fire, so closing anywhere else (stop() used to as well) is a
        // double close that can kill an unrelated fd under reuse.
        source.setCancelHandler {
            close(fd)
        }
        source.resume()
        self.acceptSource = source
    }

    func stop() {
        // The accept source's cancel handler closes listenFD (exactly
        // once, after any in-flight accept); here we only cancel and
        // clear our state.
        acceptSource?.cancel()
        acceptSource = nil
        listenFD = -1
        if !socketPath.isEmpty {
            unlink(socketPath)
            socketPath = ""
        }
    }

    deinit { stop() }

    // MARK: - Accept + connection lifecycle

    private func acceptOne() {
        var addr = sockaddr_un()
        var len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connFD = withUnsafeMutablePointer(to: &addr) { ptr -> Int32 in
            let raw = UnsafeMutableRawPointer(ptr)
            let sa = raw.assumingMemoryBound(to: sockaddr.self)
            return accept(listenFD, sa, &len)
        }
        guard connFD >= 0 else {
            // EAGAIN/EWOULDBLOCK can happen under load; ignore.
            return
        }
        workQueue.async { [weak self] in
            self?.handle(connectionFD: connFD)
        }
    }

    private func handle(connectionFD fd: Int32) {
        // Read up to 64KB or until newline. Signals are small.
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while buffer.count < 65_536 {
            let n = chunk.withUnsafeMutableBufferPointer { recv(fd, $0.baseAddress, $0.count, 0) }
            if n <= 0 { break }
            buffer.append(chunk, count: n)
            if buffer.contains(0x0A) { break }
        }

        // Trim at first newline (if present) so trailing junk
        // doesn't trip the JSON parser.
        let requestData: Data
        if let nlIdx = buffer.firstIndex(of: 0x0A) {
            requestData = buffer.subdata(in: 0..<nlIdx)
        } else {
            requestData = buffer
        }

        // Branch on action. `emit` is one-shot (handle and close);
        // `subscribe` upgrades the connection to a server-streamed
        // newline-delimited feed of envelopes until the client
        // disconnects.
        guard let json = try? JSONSerialization.jsonObject(with: requestData),
              let dict = json as? [String: Any],
              let action = dict["action"] as? String else {
            close(fd)
            return
        }

        switch action {
        case "emit":
            let response = parseAndEmit(requestData: requestData, parsed: dict)
            writeJSONLine(fd: fd, object: response)
            close(fd)
        case "subscribe":
            handleSubscribe(fd: fd, request: dict)
            // Connection stays open; subscription handler closes it
            // when the client disconnects.
        default:
            writeJSONLine(fd: fd, object: ["ok": false, "error": "unknown action: \(action)"])
            close(fd)
        }
    }

    /// Long-running subscription connection. Streams every signal
    /// matching the filter as a newline-delimited JSON line. Tears
    /// down proactively when the client disconnects — even if no
    /// emit happens to notice the broken pipe — by watching the FD
    /// for EOF via a DispatchSourceRead. Without this, an MCP
    /// process that dies hard (panic / SIGKILL / lost connection)
    /// leaks the dreamux-side subscription until something tries to
    /// write through the dead pipe.
    private func handleSubscribe(fd: Int32, request: [String: Any]) {
        let filter = (request["filter"] as? [String: Any]) ?? [:]
        let kindFilter = filter["kind"] as? String
        let sourceFilter = filter["source"] as? String
        let projectFilter = filter["project_dir"] as? String
        // 0 = unbounded. Both budgets accept 0 to mean "no cap"; the
        // MCP push path uses this for live tail-forever semantics.
        let rawMax = (request["max_events"] as? Int) ?? Int.max
        let maxEvents = rawMax <= 0 ? Int.max : rawMax
        let timeoutSeconds = (request["timeout_seconds"] as? Int) ?? 0

        // Send an initial ack so the client knows the subscription
        // is live before any envelopes flow. Still a blocking write:
        // the buffer is empty at this point and O_NONBLOCK isn't set
        // on the fd yet.
        writeJSONLine(fd: fd, object: ["ok": true, "subscribed": true])

        // Everything after the ack is written non-blocking: envelope
        // writes run on the bus's serial delivery queue, so a stalled
        // subscriber blocking in send(2) would stall signal delivery
        // for the whole app. See `writeStreamLine` for the resulting
        // drop semantics.
        let fdFlags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, fdFlags | O_NONBLOCK)

        // Watch the FD for EOF / readable input. The MCP push side
        // never sends data after the initial subscribe request, so
        // *any* readable event after this point means the peer
        // closed (or sent unexpected data, also a teardown trigger).
        // Detecting this here is what makes the cleanup proactive:
        // without it we'd only notice the dead peer the next time a
        // signal happened to arrive and the envelope write failed.
        let eofSource = DispatchSource.makeReadSource(fileDescriptor: fd, queue: workQueue)
        let lockForEof = NSLock()
        let semaphoreForEof = DispatchSemaphore(value: 0)
        var eofDone = false
        let triggerTeardown = { [weak semaphoreForEof] in
            lockForEof.lock()
            let alreadyDone = eofDone
            eofDone = true
            lockForEof.unlock()
            if !alreadyDone {
                semaphoreForEof?.signal()
            }
        }
        eofSource.setEventHandler {
            // Peek at the connection — recv with MSG_PEEK returns 0
            // on clean EOF, -1 on error. The fd is O_NONBLOCK, so an
            // EAGAIN here is a spurious wakeup, not a dead peer.
            var byte: UInt8 = 0
            let n = recv(fd, &byte, 1, MSG_PEEK)
            if n == 0 { triggerTeardown(); return }
            if n < 0 && errno != EAGAIN && errno != EWOULDBLOCK { triggerTeardown() }
        }
        // SOLE owner of the connection fd's close. Cancellation is the
        // one point where GCD guarantees the read source's event
        // handler can no longer fire, so closing anywhere else risks a
        // recv on a closed — possibly reused — fd. Every exit path
        // below funnels into the single `eofSource.cancel()` at the end
        // of this function, giving exactly-once close.
        eofSource.setCancelHandler {
            close(fd)
        }
        eofSource.resume()

        var deliveredCount = 0
        let lock = NSLock()
        let semaphore = DispatchSemaphore(value: 0)
        // The sink runs on the bus's serial delivery queue (the bus
        // serializes all emits); writes to fd happen there, under
        // `lock`, and only after re-checking `done` — the shutdown
        // path flips `done` under the same lock BEFORE the fd close is
        // scheduled, so an envelope write can never race the close.
        var cancellable: AnyCancellable?
        var done = false

        cancellable = bus.publisher
            .filter { signal in
                if let kindFilter, signal.kind != kindFilter { return false }
                if let sourceFilter, signal.source != sourceFilter { return false }
                if let projectFilter, signal.tags["project_dir"] != projectFilter { return false }
                return true
            }
            .sink { signal in
                lock.lock()
                guard !done else {
                    lock.unlock()
                    return
                }

                let envelope: [String: Any] = [
                    "id": signal.id,
                    "kind": signal.kind,
                    "source": signal.source,
                    "ts": Int64(signal.ts.timeIntervalSince1970 * 1000),
                    "severity": signal.severity.rawValue,
                    "tags": signal.tags,
                    "payload": Self.payloadAsAny(signal.payload),
                ]
                switch self.writeStreamLine(fd: fd, object: ["signal": envelope]) {
                case .dropped:
                    // Subscriber's socket buffer is full. Live-tail
                    // semantics: this envelope is dropped rather than
                    // blocking the bus queue behind a stalled client;
                    // the subscription stays live for later signals.
                    lock.unlock()
                case .failed:
                    // Client gone (EPIPE, …) or mid-line stall — tear down.
                    done = true
                    lock.unlock()
                    semaphore.signal()
                case .sent:
                    deliveredCount += 1
                    let reachedCap = deliveredCount >= maxEvents
                    if reachedCap { done = true }
                    lock.unlock()
                    if reachedCap { semaphore.signal() }
                }
            }

        // Race three exit paths:
        //   1. peer-disconnect (eofSource fires)
        //   2. max_events reached / signal-write failure (semaphore signaled)
        //   3. timeout elapsed (when timeoutSeconds > 0)
        // Whichever wins, tear down the other watchers.
        let combined = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            semaphore.wait()
            combined.signal()
        }
        DispatchQueue.global(qos: .utility).async {
            semaphoreForEof.wait()
            combined.signal()
        }
        if timeoutSeconds > 0 {
            _ = combined.wait(timeout: .now() + .seconds(timeoutSeconds))
        } else {
            combined.wait()
        }

        // Final shutdown — the ONE place the connection winds down,
        // whichever exit path won the race above:
        //   1. `done` flips under the lock, so no envelope write can
        //      start after this point (an in-flight write holds the
        //      lock, so we can't get past this line mid-write either).
        //   2. The farewell goes out while the fd is still open —
        //      best-effort: dropped if the subscriber's buffer is
        //      full; it's about to get EOF anyway.
        //   3. Both helper semaphores are released so neither waiter
        //      block above leaks (extra signals are harmless).
        //   4. `eofSource.cancel()` — its cancel handler owns the
        //      close and GCD runs it exactly once, after any in-flight
        //      read event. No recv- or send-after-close on any path
        //      (max_events, write failure, EOF, timeout).
        lock.lock()
        done = true
        lock.unlock()
        cancellable?.cancel()
        _ = writeStreamLine(fd: fd, object: ["closed": true])
        semaphore.signal()
        triggerTeardown()
        eofSource.cancel()
    }

    /// Outcome of a non-blocking stream write. See `writeStreamLine`.
    private enum StreamWrite {
        /// Whole line written.
        case sent
        /// Nothing written — the buffer was full before the first
        /// byte. The line is dropped; the subscription stays live.
        case dropped
        /// Hard error (EPIPE, …) or the buffer filled MID-line. The
        /// connection must be torn down.
        case failed
    }

    /// Non-blocking line write for subscription streams (the fd has
    /// O_NONBLOCK set). Envelope writes run on the bus's serial
    /// delivery queue, where a blocking send(2) against a stalled
    /// subscriber would stall every signal in the app — so this never
    /// blocks.
    ///
    /// Drop semantics: if the buffer is full before anything is
    /// written, the line is dropped and the subscription stays live —
    /// a live tail that misses events under backpressure beats one
    /// that kills the feed. If the buffer fills MID-line we cannot
    /// drop (the peer already holds a partial line; writing the next
    /// envelope would corrupt the newline framing), so it reports
    /// `.failed` and the caller tears the connection down.
    private func writeStreamLine(fd: Int32, object: [String: Any]) -> StreamWrite {
        var data = (try? JSONSerialization.data(withJSONObject: object, options: [])) ?? Data()
        data.append(0x0A)
        var written = 0
        return data.withUnsafeBytes { ptr -> StreamWrite in
            guard let base = ptr.baseAddress else { return .failed }
            while written < data.count {
                let n = send(fd, base.advanced(by: written), data.count - written, 0)
                if n > 0 {
                    written += n
                    continue
                }
                if n < 0 && errno == EINTR { continue }
                if n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                    return written == 0 ? .dropped : .failed
                }
                return .failed
            }
            return .sent
        }
    }

    @discardableResult
    private func writeJSONLine(fd: Int32, object: [String: Any]) -> Bool {
        var data = (try? JSONSerialization.data(withJSONObject: object, options: [])) ?? Data()
        data.append(0x0A)
        var written = 0
        return data.withUnsafeBytes { ptr -> Bool in
            guard let base = ptr.baseAddress else { return false }
            while written < data.count {
                let n = send(fd, base.advanced(by: written), data.count - written, 0)
                if n <= 0 { return false }
                written += n
            }
            return true
        }
    }

    private static func payloadAsAny(_ payload: SignalPayload) -> Any {
        switch payload {
        case .null: return NSNull()
        case .bool(let b): return b
        case .int(let i): return i
        case .double(let d): return d
        case .string(let s): return s
        case .array(let arr): return arr.map { payloadAsAny($0) }
        case .object(let dict):
            var out: [String: Any] = [:]
            for (k, v) in dict { out[k] = payloadAsAny(v) }
            return out
        }
    }

    /// Parse the JSON, validate, build a `Signal`, hand to the bus.
    /// Errors return `{ ok: false, error: "..." }`; success returns
    /// `{ ok: true, id: "<assigned id>" }`.
    private func parseAndEmit(requestData: Data, parsed: [String: Any]? = nil) -> [String: Any] {
        let dict: [String: Any]
        if let parsed {
            dict = parsed
        } else {
            guard let json = try? JSONSerialization.jsonObject(with: requestData),
                  let parsedDict = json as? [String: Any] else {
                return ["ok": false, "error": "request not valid JSON object"]
            }
            dict = parsedDict
        }
        let action = dict["action"] as? String
        guard action == "emit" else {
            return ["ok": false, "error": "unknown action: \(action ?? "(nil)")"]
        }
        guard let signalDict = dict["signal"] as? [String: Any] else {
            return ["ok": false, "error": "missing 'signal' object"]
        }
        guard let kind = signalDict["kind"] as? String, !kind.isEmpty else {
            return ["ok": false, "error": "missing 'signal.kind'"]
        }
        let source = (signalDict["source"] as? String) ?? "external"
        let severityStr = (signalDict["severity"] as? String) ?? "info"
        let severity = SignalSeverityLevel(rawValue: severityStr) ?? .info
        let tags = (signalDict["tags"] as? [String: Any])?.reduce(into: [String: String]()) { acc, kv in
            if let s = kv.value as? String { acc[kv.key] = s }
        } ?? [:]
        let payload: SignalPayload
        if let raw = signalDict["payload"] {
            payload = SignalPayload.from(json: raw)
        } else {
            payload = .null
        }
        let signal = Signal(
            source: source,
            kind: kind,
            severity: severity,
            tags: tags,
            payload: payload
        )
        bus.emit(signal)
        return ["ok": true, "id": signal.id]
    }
}
