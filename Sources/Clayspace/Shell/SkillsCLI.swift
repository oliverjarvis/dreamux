import Foundation

enum SkillsCLIError: LocalizedError {
    case nodeUnavailable
    case commandFailed(args: [String], stderr: String)

    var errorDescription: String? {
        switch self {
        case .nodeUnavailable:
            return "Node.js is required to manage skills. Install it (e.g. `brew install node`) and reopen this section."
        case .commandFailed(let args, let stderr):
            let cmd = (["skills"] + args).joined(separator: " ")
            let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "skills command failed: \(cmd)" : "skills: \(trimmed)"
        }
    }
}

/// Async wrapper around the `skills` CLI (`npx -y skills …`) — the
/// canonical package manager for agent skills. All mutations and the
/// installed listing go through it so on-disk layout, lockfiles, and
/// update semantics stay exactly what the CLI produces.
///
/// Binary resolution: `CLAYSPACE_SKILLS_BIN` (tests/e2e) is executed
/// directly with the subcommand argv; otherwise we exec
/// `<nodeBinDirectory>/npx -y skills <argv…>` with that directory
/// prepended to PATH (npx needs to find its own node).
struct SkillsCLI: Sendable {
    /// Locked-on targets per product decision: every install reaches
    /// at least Claude Code and Codex.
    static let lockedAgents = ["claude-code", "codex"]

    let nodeBinDirectory: String?

    func add(
        source: String,
        skills: [String],
        extraAgents: [String],
        scope: SkillScope,
        onLine: (@Sendable (String) -> Void)? = nil
    ) async throws {
        var args = ["add", source]
        args += ["-s"] + skills
        args += ["-a"] + Self.lockedAgents + extraAgents
        if scope.isGlobal { args.append("-g") }
        args.append("-y")
        _ = try await run(args, cwd: scope.workingDirectory, onLine: onLine)
    }

    func list(scope: SkillScope) async throws -> [InstalledSkill] {
        var args = ["list", "--json"]
        if scope.isGlobal { args.append("-g") }
        let output = try await run(args, cwd: scope.workingDirectory)
        // The CLI may print spinner noise before the payload on some
        // terminals; the JSON array is the first `[`-rooted suffix.
        guard let start = output.firstIndex(of: "[") else { return [] }
        let payload = Data(String(output[start...]).utf8)
        return try JSONDecoder().decode([InstalledSkill].self, from: payload)
    }

    func remove(
        skills: [String],
        scope: SkillScope,
        onLine: (@Sendable (String) -> Void)? = nil
    ) async throws {
        var args = ["remove", "-s"] + skills + ["-a", "*"]
        if scope.isGlobal { args.append("--global") }
        args.append("-y")
        _ = try await run(args, cwd: scope.workingDirectory, onLine: onLine)
    }

    func update(
        skills: [String],
        scope: SkillScope,
        onLine: (@Sendable (String) -> Void)? = nil
    ) async throws {
        var args = ["update"] + skills
        args.append(scope.isGlobal ? "-g" : "-p")
        args.append("-y")
        _ = try await run(args, cwd: scope.workingDirectory, onLine: onLine)
    }

    // MARK: - Process plumbing

    /// (executable, leading args) for the current configuration.
    private func invocation() throws -> (String, [String]) {
        if let override = ProcessInfo.processInfo.environment["CLAYSPACE_SKILLS_BIN"],
           !override.isEmpty {
            return (override, [])
        }
        guard let nodeBinDirectory else { throw SkillsCLIError.nodeUnavailable }
        return ((nodeBinDirectory as NSString).appendingPathComponent("npx"), ["-y", "skills"])
    }

    /// Mirrors `GitOperations.runGit`'s contract: background queue,
    /// streamed lines, SIGTERM on task cancellation, stderr folded into
    /// the thrown error. (Same drain-unconditionally rationale — see
    /// the comment in GitOperations.swift.)
    private func run(
        _ args: [String],
        cwd: URL,
        onLine: (@Sendable (String) -> Void)? = nil
    ) async throws -> String {
        let (executable, leadingArgs) = try invocation()
        let nodeDir = nodeBinDirectory
        let processBox = SkillsProcessBox()

        return try await withTaskCancellationHandler(
            operation: {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
                    DispatchQueue.global(qos: .userInitiated).async {
                        let process = Process()
                        process.executableURL = URL(fileURLWithPath: executable)
                        process.arguments = leadingArgs + args
                        process.currentDirectoryURL = cwd

                        var env = ProcessInfo.processInfo.environment
                        if let nodeDir {
                            env["PATH"] = nodeDir + ":" + (env["PATH"] ?? "/usr/bin:/bin")
                        }
                        env["NO_COLOR"] = "1"
                        process.environment = env

                        let outPipe = Pipe()
                        let errPipe = Pipe()
                        process.standardOutput = outPipe
                        process.standardError = errPipe

                        let collector = SkillsOutputCollector()
                        outPipe.fileHandleForReading.readabilityHandler = { handle in
                            let data = handle.availableData
                            if data.isEmpty { handle.readabilityHandler = nil; return }
                            collector.append(data, isStdout: true, onLine: onLine)
                        }
                        errPipe.fileHandleForReading.readabilityHandler = { handle in
                            let data = handle.availableData
                            if data.isEmpty { handle.readabilityHandler = nil; return }
                            collector.append(data, isStdout: false, onLine: onLine)
                        }

                        processBox.set(process)
                        do {
                            try process.run()
                        } catch {
                            continuation.resume(throwing: error)
                            return
                        }
                        process.waitUntilExit()

                        outPipe.fileHandleForReading.readabilityHandler = nil
                        errPipe.fileHandleForReading.readabilityHandler = nil
                        let tailOut = outPipe.fileHandleForReading.readDataToEndOfFile()
                        let tailErr = errPipe.fileHandleForReading.readDataToEndOfFile()
                        if !tailOut.isEmpty { collector.append(tailOut, isStdout: true, onLine: onLine) }
                        if !tailErr.isEmpty { collector.append(tailErr, isStdout: false, onLine: onLine) }

                        if process.terminationStatus != 0 {
                            let stderr = collector.stderrText
                            continuation.resume(throwing: SkillsCLIError.commandFailed(
                                args: args,
                                stderr: stderr.isEmpty ? collector.stdoutText : stderr
                            ))
                        } else {
                            continuation.resume(returning: collector.stdoutText)
                        }
                    }
                }
            },
            onCancel: { processBox.terminate() }
        )
    }
}

/// Same shape as GitOperations' private ProcessBox — that one isn't
/// visible outside its file.
private final class SkillsProcessBox: @unchecked Sendable {
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

/// Accumulates both streams and emits complete lines to `onLine`.
private final class SkillsOutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var stdout = ""
    private var stderr = ""
    private var lineBuffer = ""

    var stdoutText: String { lock.lock(); defer { lock.unlock() }; return stdout }
    var stderrText: String { lock.lock(); defer { lock.unlock() }; return stderr }

    func append(_ data: Data, isStdout: Bool, onLine: (@Sendable (String) -> Void)?) {
        guard let text = String(data: data, encoding: .utf8) else { return }
        lock.lock()
        if isStdout { stdout += text } else { stderr += text }
        lineBuffer += text
        var lines: [String] = []
        while let idx = lineBuffer.firstIndex(of: "\n") {
            let raw = String(lineBuffer[..<idx])
            lineBuffer.removeSubrange(lineBuffer.startIndex...idx)
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { lines.append(trimmed) }
        }
        lock.unlock()
        if let onLine {
            for line in lines { onLine(line) }
        }
    }
}
