import Foundation

/// Runs an applet builder's `shell.exec` bridge calls: an ad-hoc `/bin/sh
/// -lc` command in a caller-chosen cwd, with a hard wall-clock timeout and
/// output caps. Callable from any actor/isolation — the applet bridge calls
/// it from a detached `Task`, off the main actor.
enum AppletShell {
    /// Streams stdout/stderr are each capped at 1 MB (truncated, not an
    /// error — a runaway `cmd` producing gigabytes must not blow memory).
    private static let maxBytes = 1 * 1024 * 1024

    /// Run `cmd` via `/bin/sh -lc` in `cwd`. Pipes are drained off the
    /// calling thread (a `readabilityHandler` on a background dispatch
    /// queue) — a command that fills the ~64 KB kernel pipe buffer before
    /// anyone reads it would otherwise deadlock the child against us. On
    /// timeout a detached watchdog calls `terminate()`; Foundation's
    /// `Process` puts the child in its own process group and `terminate()`
    /// signals that whole group, so shell-spawned grandchildren die too.
    static func exec(cmd: String, cwd: URL, timeout: TimeInterval = 60) async -> (stdout: String, stderr: String, code: Int32) {
        let processBox = ProcessBox()

        return await withCheckedContinuation { (continuation: CheckedContinuation<(stdout: String, stderr: String, code: Int32), Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/sh")
                process.arguments = ["-lc", cmd]
                process.currentDirectoryURL = cwd
                // `chdir()` always lands the kernel's cwd on the fully
                // resolved (symlink-free) path — `getcwd()`, which a
                // fresh shell's `pwd` falls back to, can't recover the
                // logical path we were handed. Set `PWD` explicitly so
                // bash's inherited-PWD fast path (it trusts PWD when its
                // stat matches ".") preserves the exact `cwd` string,
                // matching what callers (and `URL.resolvingSymlinksInPath`,
                // which deliberately leaves /tmp, /var, /etc unresolved)
                // expect `pwd` to print.
                var env = ProcessInfo.processInfo.environment
                env["PWD"] = cwd.path
                process.environment = env

                let outPipe = Pipe()
                let errPipe = Pipe()
                process.standardOutput = outPipe
                process.standardError = errPipe

                let accumulator = CappedOutputAccumulator(maxBytes: maxBytes)

                // Installed unconditionally, before `run()`: nothing else
                // reads these pipes, so a command producing more than the
                // kernel pipe buffer would block writing while we block on
                // waitUntilExit(), deadlocking both sides.
                outPipe.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    if data.isEmpty {
                        handle.readabilityHandler = nil
                        return
                    }
                    accumulator.appendStdout(data)
                }
                errPipe.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    if data.isEmpty {
                        handle.readabilityHandler = nil
                        return
                    }
                    accumulator.appendStderr(data)
                }

                processBox.set(process)

                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: (
                        stdout: "",
                        stderr: "failed to launch: \(error.localizedDescription)",
                        code: -1
                    ))
                    return
                }

                // Watchdog: fires after `timeout` and terminates the whole
                // process group if it's still running. Cancelled once the
                // process exits on its own.
                let watchdog = Task.detached {
                    try? await Task.sleep(nanoseconds: UInt64(max(timeout, 0) * 1_000_000_000))
                    processBox.terminate()
                }

                process.waitUntilExit()
                watchdog.cancel()

                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil

                // Drain any bytes that landed after the last readability
                // callback fired — important for commands that finish in
                // a single fast chunk.
                let tailOut = outPipe.fileHandleForReading.readDataToEndOfFile()
                let tailErr = errPipe.fileHandleForReading.readDataToEndOfFile()
                if !tailOut.isEmpty { accumulator.appendStdout(tailOut) }
                if !tailErr.isEmpty { accumulator.appendStderr(tailErr) }

                continuation.resume(returning: (
                    stdout: accumulator.stdoutText,
                    stderr: accumulator.stderrText,
                    code: process.terminationStatus
                ))
            }
        }
    }
}

/// Thread-safe holder so the watchdog (a detached `Task`) and the
/// dispatch-queue block running the process can both reach it safely.
private final class ProcessBox: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?

    func set(_ p: Process) {
        lock.lock(); defer { lock.unlock() }
        process = p
    }

    func terminate() {
        lock.lock()
        let p = process
        lock.unlock()
        guard let p, p.isRunning else { return }
        p.terminate()
    }
}

/// Accumulates stdout/stderr bytes from readability-handler callbacks
/// (which may run concurrently on the pipe's dispatch queue), capping each
/// stream at `maxBytes` — a runaway command must not blow memory.
private final class CappedOutputAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private let maxBytes: Int
    private var stdoutData = Data()
    private var stderrData = Data()

    init(maxBytes: Int) {
        self.maxBytes = maxBytes
    }

    func appendStdout(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        Self.append(data, to: &stdoutData, maxBytes: maxBytes)
    }

    func appendStderr(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        Self.append(data, to: &stderrData, maxBytes: maxBytes)
    }

    var stdoutText: String {
        lock.lock(); defer { lock.unlock() }
        // Lossy, total decode — not `String(data:encoding:.utf8)`: the 1 MB
        // cap can (and, for any near-cap non-ASCII output, will) truncate
        // mid multi-byte sequence, and the strict initializer returns nil
        // for the *whole* buffer on any invalid tail rather than just the
        // last character, silently discarding everything captured so far.
        return String(decoding: stdoutData, as: UTF8.self)
    }

    var stderrText: String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: stderrData, as: UTF8.self)
    }

    private static func append(_ data: Data, to buffer: inout Data, maxBytes: Int) {
        guard buffer.count < maxBytes else { return }
        let remaining = maxBytes - buffer.count
        buffer.append(data.prefix(remaining))
    }
}
