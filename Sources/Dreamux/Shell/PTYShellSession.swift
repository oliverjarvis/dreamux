import Foundation
import Darwin
import GhosttyTerminal
import DreamuxPTY
import os

/// One attention/control event extracted from the PTY byte stream.
enum ActivitySignal: Equatable, Sendable {
    /// Bare BEL — generic ping, no payload.
    case ping
    /// OSC 9 / OSC 777;notify — human-readable notification body.
    case notification(String)
    /// OSC 777;dreamux;<verb>;<base64url-json> — structured event from
    /// dreamux-hook, arriving inside the session's own PTY so it is
    /// already correlated to this tab (session binding, chat state).
    case control(verb: String, json: Data)
}

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
    private var producedOutput = false
    private var lastOutputAt: Date?

    /// True once the child shell has written anything back. Necessary
    /// but NOT sufficient for programmatic input: zsh emits bytes
    /// (title escapes, profile output) well before its line editor is
    /// up, and zle's init runs tcsetattr with TCSAFLUSH, which DISCARDS
    /// anything typed in between. Use `isQuiescent(for:)` to know when
    /// typing is safe.
    var hasProducedOutput: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return producedOutput
    }

    /// True when the shell has produced output and then gone silent
    /// for at least `interval`. Startup output arrives in bursts and
    /// the prompt is usually the last of them — but a heavyweight rc
    /// file can also go silent for seconds mid-startup, so this is a
    /// "probably ready" signal, not a guarantee. Callers that must not
    /// lose input should verify the echo (see `lastOutputTimestamp`)
    /// and resend.
    func isQuiescent(for interval: TimeInterval) -> Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        guard producedOutput, let last = lastOutputAt else { return false }
        return Date().timeIntervalSince(last) >= interval
    }

    /// When the shell last wrote anything. A live line editor echoes
    /// typed input, so output newer than a `send` proves the shell
    /// actually received it (rather than zle's startup tcsetattr
    /// flushing it from the input queue).
    var lastOutputTimestamp: Date? {
        stateLock.lock(); defer { stateLock.unlock() }
        return lastOutputAt
    }

    private let ioQueue = DispatchQueue(label: "com.dreamux.pty.io", qos: .userInitiated)
    private let cwd: String?
    private let extraEnv: [String: String]
    private let onActivity: (@Sendable (String?) -> Void)?
    private let onControl: (@Sendable (String, Data) -> Void)?

    init(
        cwd: String? = nil,
        extraEnv: [String: String] = [:],
        onActivity: (@Sendable (String?) -> Void)? = nil,
        onControl: (@Sendable (String, Data) -> Void)? = nil
    ) {
        self.cwd = cwd
        self.extraEnv = extraEnv
        self.onActivity = onActivity
        self.onControl = onControl

        // Capture into a holder so the closures can refer to the eventual
        // `self` without a chicken-and-egg with `terminalSession`.
        let holder = SelfHolder()
        self.terminalSession = InMemoryTerminalSession(
            write: { data in holder.value?.writeToPTY(data) },
            resize: { viewport in holder.value?.handleResize(viewport) }
        )
        holder.value = self

        // The quit guard's registry is weak, so registering at init is
        // safe even for sessions that never start (they report no work).
        Task { @MainActor [weak self] in
            if let self { QuitGuard.shared.register(self) }
        }
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
        // Don't propagate the *launcher's* Claude-session identity into
        // Dreamux's terminals. If the app was started from within a Claude
        // Code session (e.g. launched from an agent's shell), these are
        // inherited — and any `claude` run here would then register as a
        // child/subagent of that session, writing no standalone transcript
        // (so a run's "open transcript" points at a file that never exists).
        // Strip them so every agent Dreamux spawns is a fresh top-level
        // session with its own transcript.
        for key in ["CLAUDE_CODE_SESSION_ID", "CLAUDE_CODE_CHILD_SESSION", "CLAUDE_CODE_ENTRYPOINT"] {
            env.removeValue(forKey: key)
        }
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
        env["TERM_PROGRAM"] = "Dreamux"
        env["LANG"] = env["LANG"] ?? "en_US.UTF-8"

        // Make `dreamux-hook` discoverable inside the shell. Coding
        // agents wire it into their hook config (e.g. Claude Code's
        // Stop / Notification hooks) to push structured notifications
        // back to the app.
        let resourceURL = Bundle.main.resourceURL
        if let bin = resourceURL?
            .appendingPathComponent("bin", isDirectory: true).path,
           FileManager.default.fileExists(atPath: bin) {
            let existing = env["PATH"] ?? "/usr/local/bin:/usr/bin:/bin"
            env["PATH"] = "\(bin):\(existing)"
            env["DREAMUX_BIN"] = bin
        }

        // Flow hooks (dreamux-hook flow) find the app's signal socket
        // through this; unset outside Dreamux, so the hook no-ops.
        env["DREAMUX_EMIT_SOCKET"] = SignalEmitSocketServer.defaultSocketPath()

        // Naive PATH prepend loses to Homebrew / nvm / asdf rc-file
        // gymnastics. For zsh we point ZDOTDIR at a bundled rc set that
        // sources the user's normal startup files and *then* re-prepends
        // Dreamux's bin via a precmd hook, so our shims (`claude`)
        // reliably resolve first.
        let shellName = (shellPath as NSString).lastPathComponent
        if shellName == "zsh",
           let zdotdir = resourceURL?
            .appendingPathComponent("zdotdir", isDirectory: true).path,
           FileManager.default.fileExists(atPath: zdotdir) {
            env["ZDOTDIR"] = zdotdir
        }

        for (k, v) in extraEnv { env[k] = v }
        let envStrings = env.map { "\($0.key)=\($0.value)" }

        // Allocate everything the child needs BEFORE fork. After fork we only
        // call async-signal-safe libc functions; no Swift runtime allocations.
        let cArgv = makeCStringArray(argv)
        let cEnvp = makeCStringArray(envStrings)
        let cShell = strdup(shellPath)!
        let cCwd: UnsafeMutablePointer<CChar>? = cwd.map { strdup($0)! }

        var master: Int32 = -1
        let pid = dreamux_forkpty(&master, 80, 24)

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
            let msg = "dreamux: execve failed\n"
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

        _ = dreamux_set_cloexec(master)
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

    /// Push text into the PTY as if the user typed it. Caller is
    /// responsible for any trailing newline (use `\n` to "press enter").
    func send(_ text: String) {
        writeToPTY(Data(text.utf8))
    }

    // MARK: - Private

    private func startReader(fd: Int32) {
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: ioQueue)
        let session = terminalSession
        let activityHandler = onActivity
        let controlHandler = onControl
        source.setEventHandler { [weak self] in
            var buffer = [UInt8](repeating: 0, count: 8192)
            let n = buffer.withUnsafeMutableBufferPointer { ptr -> Int in
                Darwin.read(fd, ptr.baseAddress, ptr.count)
            }
            if n > 0 {
                if let self {
                    self.stateLock.lock()
                    self.producedOutput = true
                    self.lastOutputAt = Date()
                    self.stateLock.unlock()
                }
                session.receive(Data(bytes: buffer, count: n))
                // Extract attention signals from this chunk: a plain BEL
                // (`\a`, 0x07) maps to a generic ping; an iTerm2-style
                // notification (`ESC ] 9 ; <body> BEL`) or an rxvt-style
                // (`ESC ] 777 ; notify ; <title> ; <body> BEL`) carries an
                // actual message that we surface in the notification.
                let signals = Self.extractActivitySignals(buffer.prefix(n))
                for signal in signals {
                    Self.logProvenance(signal)
                    switch signal {
                    case .ping: activityHandler?(nil)
                    case .notification(let message): activityHandler?(message)
                    case .control(let verb, let json): controlHandler?(verb, json)
                    }
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
        _ = dreamux_set_winsize(fd, viewport.columns, viewport.rows, xpix, ypix)
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

    /// Pulls attention signals out of a chunk of bytes. Returns one entry
    /// per BEL/OSC terminator: a bare BEL is `.ping`; the tail of an
    /// iTerm2 (`OSC 9`) or rxvt (`OSC 777 ; notify`) notification is
    /// `.notification`; the tail of a `OSC 777 ; dreamux ; …` control
    /// escape is `.control`.
    /// Opt-in provenance logging for "an ugly banner appears and we do
    /// not know who posted it". Off by default — this sits on the PTY
    /// read path, and the question it answers is asked once per fresh
    /// machine, not continuously.
    static func provenanceLoggingEnabled(
        env: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        env["DREAMUX_NOTIFY_DEBUG"] == "1"
    }

    private static let provenanceLogger = Logger(
        subsystem: "com.dreamux.Dreamux",
        category: "NotificationProvenance"
    )

    /// Record a notification-bearing escape verbatim so the emitter can
    /// be identified. Dreamux itself posts no AppleScript notifications,
    /// so anything the user sees that Dreamux did not post came through
    /// here or from a process spawned in this tab.
    static func logProvenance(_ signal: ActivitySignal) {
        guard provenanceLoggingEnabled() else { return }
        switch signal {
        case .ping:
            provenanceLogger.info("osc: bare BEL")
        case .notification(let body):
            provenanceLogger.info("osc: notification body=\(body, privacy: .public)")
        case .control(let verb, _):
            provenanceLogger.info("osc: control verb=\(verb, privacy: .public)")
        }
    }

    static func extractActivitySignals(_ data: ArraySlice<UInt8>) -> [ActivitySignal] {
        var signals: [ActivitySignal] = []
        var i = data.startIndex
        while i < data.endIndex {
            let byte = data[i]

            // OSC start: ESC ]
            if byte == 0x1B,
               i + 1 < data.endIndex,
               data[i + 1] == 0x5D {
                let bodyStart = i + 2
                var j = bodyStart
                var terminatorLength = 0
                while j < data.endIndex {
                    if data[j] == 0x07 {
                        terminatorLength = 1
                        break
                    }
                    // ESC \ (ST) terminator
                    if data[j] == 0x1B,
                       j + 1 < data.endIndex,
                       data[j + 1] == 0x5C {
                        terminatorLength = 2
                        break
                    }
                    j += 1
                }
                guard terminatorLength > 0 else { break } // partial OSC; bail

                let payload = Array(data[bodyStart..<j])
                let parts = Self.splitSemicolons(payload)
                if parts.first == "9", parts.count >= 2 {
                    // OSC 9 has two flavours we care about:
                    //   1. iTerm2 notification: `OSC 9 ; <body> BEL`.
                    //   2. ConEmu progress:     `OSC 9 ; <id> ; …`
                    //                           where <id> is a small
                    //                           integer (1, 2, 3, 4, …)
                    //                           and the rest are
                    //                           progress params.
                    // Disambiguate by looking at the *first* parameter:
                    // if it's purely numeric and there are extra
                    // semicolon-separated args, it's a sub-protocol —
                    // ignore. Otherwise rejoin all params after the OSC
                    // code as the body, so legitimate notifications
                    // with semicolons in the message don't get clipped.
                    let first = parts[1]
                    let isNumericSubcommand = parts.count > 2
                        && !first.isEmpty
                        && first.allSatisfy { $0.isASCII && $0.isNumber }
                    if !isNumericSubcommand {
                        let body = parts.dropFirst().joined(separator: ";")
                        signals.append(.notification(body))
                    }
                } else if parts.first == "777", parts.count >= 4, parts[1] == "dreamux" {
                    if let json = decodeBase64URL(parts[3]) {
                        signals.append(.control(verb: parts[2], json: json))
                    }
                    // undecodable payload: drop silently — a control
                    // event we can't parse must never become a banner.
                } else if parts.first == "777",
                          parts.count >= 4,
                          parts[1] == "notify" {
                    signals.append(.notification("\(parts[2]): \(parts[3])"))
                }
                // Any other OSC sub-protocol (titles, hyperlinks,
                // shell-integration markers, …) is left alone — no
                // signal at all.
                i = j + terminatorLength
                continue
            }

            // Bare BEL — generic ping with no payload
            if byte == 0x07 {
                signals.append(.ping)
                i += 1
                continue
            }

            i += 1
        }
        return signals
    }

    private static func splitSemicolons(_ bytes: [UInt8]) -> [String] {
        var parts: [String] = []
        var current: [UInt8] = []
        for b in bytes {
            if b == 0x3B { // ';'
                parts.append(String(bytes: current, encoding: .utf8) ?? "")
                current.removeAll(keepingCapacity: true)
            } else {
                current.append(b)
            }
        }
        parts.append(String(bytes: current, encoding: .utf8) ?? "")
        return parts
    }

    private static func decodeBase64URL(_ s: String) -> Data? {
        var b64 = s.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        return Data(base64Encoded: b64)
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

// MARK: - Quit guard

extension PTYShellSession: QuitGuardSource {
    /// Busy iff a job other than the shell owns the PTY's foreground
    /// process group — Terminal.app's own heuristic. `<= 0` means
    /// tcgetpgrp failed (dead or never-started PTY).
    static func foregroundIsBusy(foregroundPGID: pid_t, shellPID: pid_t) -> Bool {
        foregroundPGID > 0 && foregroundPGID != shellPID
    }

    var busyWork: BusyWork {
        stateLock.lock()
        let fd = masterFD
        let pid = childPID
        stateLock.unlock()
        guard fd >= 0, pid > 0 else { return BusyWork() }
        let busy = Self.foregroundIsBusy(foregroundPGID: tcgetpgrp(fd), shellPID: pid)
        return BusyWork(busyTerminals: busy ? 1 : 0)
    }
}
