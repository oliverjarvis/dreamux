import AppKit
import Darwin
import Foundation

/// Unix-domain-socket automation server for the e2e harness. Listens
/// on the path from `DREAMUX_E2E_SOCKET`, speaks newline-delimited
/// JSON (one request object per line, one response object per line),
/// and runs each command on the main actor so it can touch the app's
/// stores directly. See `Scripts/e2e/PROTOCOL.md` for the wire format.
///
/// Plain BSD sockets, deliberately: no Network.framework entitlements,
/// no permissions, nothing a sandboxed CI runner would balk at. The
/// accept loop lives on a private dispatch queue and handles one
/// connection at a time — commands are inherently sequential anyway
/// (the driver waits for each reply), and serializing here keeps the
/// MainActor hops trivially ordered.
final class E2EServer: @unchecked Sendable {
    @MainActor private static var shared: E2EServer?

    /// Bind and start accepting. Called once from `DreamuxApp.init`
    /// when e2e mode is active; failures are logged and swallowed —
    /// a broken harness shouldn't take the app down with it.
    @MainActor
    static func start(socketPath: String) {
        guard shared == nil else { return }
        let server = E2EServer(socketPath: socketPath)
        guard server.listenOnSocket() else {
            FileHandle.standardError.write(
                Data("[dreamux-e2e] failed to bind \(socketPath): \(String(cString: strerror(errno)))\n".utf8)
            )
            return
        }
        shared = server
        server.runAcceptLoop()
    }

    private let socketPath: String
    private var serverFD: Int32 = -1
    private let queue = DispatchQueue(label: "com.dreamux.e2e-server", qos: .userInitiated)

    private init(socketPath: String) {
        self.socketPath = socketPath
    }

    private func listenOnSocket() -> Bool {
        // A previous run may have left its socket file behind — stale
        // bind targets are the most common "server won't start" cause.
        unlink(socketPath)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }

        // Never leak the listener into spawned children (runner
        // processes, the embedded PTY shells). An inherited copy keeps
        // the socket alive after this process dies — a relaunching
        // driver would then connect to the orphan's backlog, where
        // nothing will ever accept().
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        // sun_path is 104 bytes on Darwin (including the NUL) — the
        // driver must keep socket paths short (e.g. under /tmp).
        guard pathBytes.count <= capacity else {
            close(fd)
            return false
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { dest in
            pathBytes.withUnsafeBytes { src in
                dest.copyBytes(from: src)
            }
        }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)

        let bound = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(fd, 4) == 0 else {
            close(fd)
            return false
        }
        serverFD = fd
        return true
    }

    private func runAcceptLoop() {
        queue.async { [self] in
            while true {
                let client = accept(serverFD, nil, nil)
                if client < 0 {
                    if errno == EINTR { continue }
                    break
                }
                serve(client: client)
            }
        }
    }

    /// Read newline-delimited requests off one connection until the
    /// peer closes it, replying to each in order. Runs on `queue`.
    private func serve(client: Int32) {
        defer { close(client) }
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(client, &chunk, chunk.count)
            if count <= 0 { return }
            buffer.append(contentsOf: chunk[0..<count])

            while let newline = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer[buffer.startIndex..<newline]
                buffer = Data(buffer[buffer.index(after: newline)...])
                let line = String(decoding: lineData, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !line.isEmpty else { continue }

                let reply = Self.runCommandBlocking(line: line)
                var out = reply.data
                out.append(0x0A)
                guard writeFully(out, to: client) else { return }

                if reply.isQuit {
                    // Reply already flushed — safe to tear the app
                    // down. terminate() never returns, so do it from
                    // the main queue after this connection unwinds.
                    DispatchQueue.main.async { NSApp.terminate(nil) }
                    // AppKit can stall graceful termination when
                    // sheets or live PTY shells are up. The harness
                    // needs deterministic death more than teardown
                    // niceties, so force the exit if terminate hasn't
                    // taken us down shortly after.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                        exit(0)
                    }
                    return
                }
            }
        }
    }

    private func writeFully(_ data: Data, to fd: Int32) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return false }
            var offset = 0
            while offset < raw.count {
                let written = write(fd, base.advanced(by: offset), raw.count - offset)
                if written <= 0 { return false }
                offset += written
            }
            return true
        }
    }

    /// Hop onto the main actor for the command, blocking this (socket)
    /// thread until it completes. Safe because the socket queue is
    /// never the main thread, and the main actor never waits on the
    /// socket queue — no cycle.
    private static func runCommandBlocking(line: String) -> (data: Data, isQuit: Bool) {
        let box = ReplyBox()
        let semaphore = DispatchSemaphore(value: 0)
        Task { @MainActor in
            let reply = await E2ECommands.handle(line: line)
            box.set(data: reply.data, isQuit: reply.isQuit)
            semaphore.signal()
        }
        semaphore.wait()
        return box.take()
    }
}

/// Lock-guarded carrier for the reply crossing from the MainActor task
/// back to the blocked socket thread. `Data`/`Bool` are value types —
/// the lock is only for the happens-before edge.
private final class ReplyBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data(#"{"error":"command produced no reply","ok":false}"#.utf8)
    private var isQuit = false

    func set(data: Data, isQuit: Bool) {
        lock.lock()
        self.data = data
        self.isQuit = isQuit
        lock.unlock()
    }

    func take() -> (data: Data, isQuit: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (data, isQuit)
    }
}
