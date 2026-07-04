import Foundation

/// Types a `claude "$(cat <promptfile>)"` invocation into a PTY shell,
/// reliably. Extracted from RunSetupView so every claude-driving flow
/// (run detect/isolate/diagnose, plan execution, planning kickoff)
/// shares the one battle-tested delivery loop. See the doc comments on
/// `send` for why prompts go through a file and why delivery is
/// verified by echo rather than timing.
@MainActor
enum ClaudePromptDriver {
    /// Type the claude command into the Run terminal, reliably. A
    /// still-booting zsh silently DISCARDS typed input (zle's terminal
    /// setup runs tcsetattr with TCSAFLUSH), and no timing heuristic is
    /// safe — heavyweight rc files produce multi-second silent gaps
    /// that look exactly like "prompt drawn, shell idle". So instead of
    /// trusting timing, we verify delivery: a live line editor always
    /// echoes typed input, so send, then watch for ANY output. Silence
    /// means the bytes were flushed — wait and send again. The first
    /// send that lands echoes within milliseconds and ends the loop.
    static func send(_ prompt: String, into session: TabSession) {
        // The prompt goes through a file, not the keyboard: prompts are
        // kilobytes of multi-line text, and the PTY input path is built
        // for human-scale typing (kernel input queues are small, and a
        // mid-line overflow silently truncates the command). A short
        // `claude "$(cat …)"` types reliably and keeps the invocation
        // visible in the terminal for the user.
        let command: String
        do {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("dreamux-prompts", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let file = dir.appendingPathComponent("\(UUID().uuidString).txt")
            try prompt.write(to: file, atomically: true, encoding: .utf8)
            command = Self.claudeCommand("$(cat \(Self.shellQuote(file.path)))", quoted: false)
        } catch {
            // Fall back to inline typing — long-prompt hazards beat
            // not sending anything at all.
            command = Self.claudeCommand(prompt)
        }
        deliver(command, into: session)
    }

    /// Type a single line into an ALREADY-RUNNING agent's REPL — the live
    /// `claude` session a plan is executing in — echo-verified. Unlike
    /// `send`, this does NOT wrap the text in a `claude …` invocation (the
    /// agent is up and waiting for input; the line IS the message) and it
    /// does not shell-quote — the bytes are typed verbatim into the REPL,
    /// then a newline submits. Used by `PlanNudgeCenter` to fold appended
    /// tasks and course corrections into a running plan through the same
    /// quiescence + echo discipline `send` uses.
    static func type(_ line: String, into session: TabSession) {
        deliver(line + "\n", into: session)
    }

    /// The shared echo-verified delivery loop. A still-booting zle silently
    /// DISCARDS typed input (its terminal setup runs tcsetattr with
    /// TCSAFLUSH) and no timing heuristic is safe, so delivery is verified
    /// by echo: wait for the shell to fall quiet, send, then watch for ANY
    /// output newer than the send — silence means the bytes were flushed,
    /// so wait and send again; the first send that lands ends the loop.
    private static func deliver(_ command: String, into session: TabSession) {
        Task {
            let deadline = Date().addingTimeInterval(45)
            // Don't even attempt before the shell has said anything —
            // the very first burst (title escape, profile output) is
            // the earliest moment input could plausibly survive.
            while !session.isShellQuiescent(for: 0.4) && Date() < deadline {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            while Date() < deadline {
                let sentAt = Date()
                session.send(command)
                // Echo check: any output newer than the send proves
                // the shell received (and echoed) it. Silence means a
                // still-initializing zle flushed the input queue —
                // wait and type again; the first send that lands ends
                // the loop.
                let echoDeadline = Date().addingTimeInterval(2.0)
                while Date() < echoDeadline {
                    if let last = session.lastShellOutputAt, last > sentAt { return }
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
            }
        }
    }

    /// One full `claude '<prompt>'` line ready to drop into the shell.
    /// The binary half comes from `ClaudeCodeIntegration` so the e2e
    /// harness can substitute a deterministic fake via
    /// `DREAMUX_CLAUDE_BIN`.
    /// One full claude invocation line ready to type into the shell.
    /// `quoted: false` passes `argument` through verbatim for shell
    /// constructs like `"$(cat …)"` — the caller is then responsible
    /// for its quoting.
    static func claudeCommand(_ argument: String, quoted: Bool = true) -> String {
        let arg = quoted ? shellQuote(argument) : "\"\(argument)\""
        return ClaudeCodeIntegration.claudeInvocation + " " + arg + "\n"
    }

    /// Wrap text in single quotes for safe shell pasting, escaping any
    /// embedded single quotes the standard '\'' way.
    static func shellQuote(_ text: String) -> String {
        let escaped = text.replacingOccurrences(of: "'", with: "'\\''")
        return "'\(escaped)'"
    }
}
