import Foundation
import Darwin
import GhosttyTerminal
import ClayspacePTY

/// Bridges Ghostty's `InMemoryTerminalSession` to a real PTY-backed shell.
///
/// `InMemoryTerminalSession` is a host-managed I/O backend: it tells us when
/// the user typed (`write` callback) and when the grid resized (`resize`
/// callback), and we feed it bytes from the shell via `receive(_:)`. We park
/// a real `zsh`/`bash` process on the slave side of a `forkpty(3)` PTY and
/// shuttle bytes between the two.
final class PTYShellSession: @unchecked Sendable {
    let terminalSession: InMemoryTerminalSession

    private let stateLock = NSLock()
    private var masterFD: Int32 = -1
    private var childPID: pid_t = -1
    private var readSource: DispatchSourceRead?
    private var isStarted = false
    private var isStopped = false

    private let ioQueue = DispatchQueue(label: "com.clayspace.pty.io", qos: .userInitiated)
    private let cwd: String?
    private let extraEnv: [String: String]
    private let onBell: (@Sendable () -> Void)?

    init(
        cwd: String? = nil,
        extraEnv: [String: String] = [:],
        onBell: (@Sendable () -> Void)? = nil
    ) {
        self.cwd = cwd
        self.extraEnv = extraEnv
        self.onBell = onBell

        // Capture into a holder so the closures can refer to the eventual
        // `self` without a chicken-and-egg with `terminalSession`.
        let holder = SelfHolder()
        self.terminalSession = InMemoryTerminalSession(
            write: { data in holder.value?.writeToPTY(data) },
            resize: { viewport in holder.value?.handleResize(viewport) }
        )
        holder.value = self
    }

    deinit {
        stateLock.lock()
        let pid = childPID
        let fd = masterFD
        stateLock.unlock()
        if pid > 0 { kill(pid, SIGHUP) }
        if fd >= 0 { close(fd) }
    }

    func start() {
        stateLock.lock()
        guard !isStarted, !isStopped else { stateLock.unlock(); return }
        isStarted = true
        stateLock.unlock()

        let shellPath = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let argv = [shellPath, "-l"]

        var env = ProcessInfo.processInfo.environment
        // Ghostty's `xterm-ghostty` terminfo lives inside Ghostty.app's
        // bundled Resources, not on the system path. Without it the shell
        // can't look up keymap capabilities (kbs / Backspace, cursor keys,
        // etc.) and characters get inserted as literal bytes. Point the
        // child at Ghostty.app's terminfo if we can find it; otherwise
        // fall back to xterm-256color so the shell still has a real entry.
        let terminfoLocations = [
            "/Applications/Ghostty.app/Contents/Resources/terminfo",
            "\(NSHomeDirectory())/Applications/Ghostty.app/Contents/Resources/terminfo",
        ]
        if let ghosttyTerminfo = terminfoLocations.first(where: {
            FileManager.default.fileExists(atPath: $0)
        }) {
            env["TERM"] = "xterm-ghostty"
            let existingDirs = env["TERMINFO_DIRS"]
            env["TERMINFO_DIRS"] = [ghosttyTerminfo, existingDirs, "/usr/share/terminfo"]
                .compactMap { $0 }
                .joined(separator: ":")
        } else {
            env["TERM"] = "xterm-256color"
        }
        env["COLORTERM"] = "truecolor"
        env["TERM_PROGRAM"] = "Clayspace"
        env["LANG"] = env["LANG"] ?? "en_US.UTF-8"
        for (k, v) in extraEnv { env[k] = v }
        let envStrings = env.map { "\($0.key)=\($0.value)" }

        // Allocate everything the child needs BEFORE fork. After fork we only
        // call async-signal-safe libc functions; no Swift runtime allocations.
        let cArgv = makeCStringArray(argv)
        let cEnvp = makeCStringArray(envStrings)
        let cShell = strdup(shellPath)!
        let cCwd: UnsafeMutablePointer<CChar>? = cwd.map { strdup($0)! }

        var master: Int32 = -1
        let pid = clayspace_forkpty(&master, 80, 24)

        if pid < 0 {
            free(cShell)
            if let cCwd { free(cCwd) }
            freeCStringArray(cArgv)
            freeCStringArray(cEnvp)
            stateLock.lock(); isStarted = false; stateLock.unlock()
            return
        }

        if pid == 0 {
            // CHILD: async-signal-safe operations only until execve.
            if let cCwd { _ = chdir(cCwd) }
            _ = execve(cShell, cArgv, cEnvp)
            // execve failed
            let msg = "clayspace: execve failed\n"
            _ = msg.withCString { write(2, $0, strlen($0)) }
            _exit(127)
        }

        // PARENT: free our local copies; child has its own COW pages.
        free(cShell)
        if let cCwd { free(cCwd) }
        freeCStringArray(cArgv)
        freeCStringArray(cEnvp)

        stateLock.lock()
        masterFD = master
        childPID = pid
        stateLock.unlock()

        _ = clayspace_set_cloexec(master)
        startReader(fd: master)
        watchChild(pid: pid)
    }

    func stop() {
        stateLock.lock()
        guard !isStopped else { stateLock.unlock(); return }
        isStopped = true
        let pid = childPID
        childPID = -1
        stateLock.unlock()

        if pid > 0 { kill(pid, SIGHUP) }
        cleanup()
    }

    // MARK: - Private

    private func startReader(fd: Int32) {
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: ioQueue)
        let session = terminalSession
        let bellHandler = onBell
        source.setEventHandler { [weak self] in
            var buffer = [UInt8](repeating: 0, count: 8192)
            let n = buffer.withUnsafeMutableBufferPointer { ptr -> Int in
                Darwin.read(fd, ptr.baseAddress, ptr.count)
            }
            if n > 0 {
                session.receive(Data(bytes: buffer, count: n))
                // BEL (0x07) is the universal "I want your attention" signal
                // from CLI agents — ring once per chunk so a flurry of bells
                // collapses into a single host-side notification.
                if buffer.prefix(n).contains(0x07) {
                    bellHandler?()
                }
            } else if n == 0 || (n < 0 && errno != EAGAIN && errno != EINTR) {
                self?.handleEOF()
            }
        }
        source.resume()
        stateLock.lock()
        readSource = source
        stateLock.unlock()
    }

    private func watchChild(pid: pid_t) {
        DispatchQueue.global(qos: .background).async { [weak self] in
            var status: Int32 = 0
            let result = waitpid(pid, &status, 0)
            if result == pid {
                self?.handleEOF()
            }
        }
    }

    private func handleEOF() {
        cleanup()
    }

    private func writeToPTY(_ data: Data) {
        stateLock.lock()
        let fd = masterFD
        stateLock.unlock()
        guard fd >= 0 else { return }
        ioQueue.async {
            data.withUnsafeBytes { buf in
                guard let base = buf.baseAddress else { return }
                var written = 0
                let total = buf.count
                while written < total {
                    let n = write(fd, base.advanced(by: written), total - written)
                    if n <= 0 {
                        if errno == EINTR { continue }
                        return
                    }
                    written += n
                }
            }
        }
    }

    private func handleResize(_ viewport: InMemoryTerminalViewport) {
        stateLock.lock()
        let fd = masterFD
        stateLock.unlock()
        guard fd >= 0 else { return }
        let xpix = UInt16(min(viewport.widthPixels, 65535))
        let ypix = UInt16(min(viewport.heightPixels, 65535))
        _ = clayspace_set_winsize(fd, viewport.columns, viewport.rows, xpix, ypix)
    }

    private func cleanup() {
        stateLock.lock()
        let source = readSource
        readSource = nil
        let fd = masterFD
        masterFD = -1
        stateLock.unlock()

        source?.cancel()
        if fd >= 0 { close(fd) }
    }
}

// MARK: - Helpers

/// Indirection so `InMemoryTerminalSession` callbacks can reach the eventual
/// `self` without a strong cycle and without forcing init order constraints.
private final class SelfHolder: @unchecked Sendable {
    weak var value: PTYShellSession?
}

private func makeCStringArray(_ strings: [String]) -> UnsafeMutablePointer<UnsafeMutablePointer<CChar>?> {
    let buffer = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: strings.count + 1)
    for (i, s) in strings.enumerated() {
        buffer[i] = strdup(s)
    }
    buffer[strings.count] = nil
    return buffer
}

private func freeCStringArray(_ ptr: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) {
    var i = 0
    while let cstr = ptr[i] {
        free(cstr)
        i += 1
    }
    ptr.deallocate()
}
