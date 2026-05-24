import Foundation
import Observation

/// One `[[runners]]` entry parsed from `run.toml`. We use a hand-rolled
/// parser (see `ParsedRunner.parseAll`) so we don't have to add a TOML
/// dependency for the very constrained shape we ourselves write.
struct ParsedRunner: Identifiable, Hashable, Sendable {
    /// Same as `name` — fine to reuse since the TOML format forbids two
    /// runners with the same name.
    var id: String { name }
    var name: String
    var cwd: String?
    var start: String
    var stop: String?
    var port: Int?
    var portEnv: String?
}

extension ParsedRunner {
    /// Pull `[[runners]]` blocks out of a TOML body. This isn't a real
    /// parser — it understands one shape only:
    ///
    ///   [[runners]]
    ///   name = "frontend"
    ///   cwd = "repos/frontend/main"
    ///   start = "npm run dev"
    ///   stop = "pkill -f 'node.*dev'"
    ///   port = 3000
    ///   port_env = "FRONTEND_PORT"
    ///
    /// Quoted strings keep their contents verbatim (no escape handling
    /// beyond stripping the outer quotes). Lines we don't recognise are
    /// skipped silently — keeps Claude's occasional stray comments from
    /// blowing up the whole load.
    static func parseAll(_ toml: String) -> [ParsedRunner] {
        var results: [ParsedRunner] = []
        var pending: PendingRunner?

        for rawLine in toml.split(whereSeparator: { $0.isNewline }) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line == "[[runners]]" {
                if let p = pending, let materialised = p.materialise() {
                    results.append(materialised)
                }
                pending = PendingRunner()
                continue
            }
            guard let p = pending,
                  let eq = line.firstIndex(of: "=") else { continue }

            let key = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
            var value = String(line[line.index(after: eq)...])
                .trimmingCharacters(in: .whitespaces)
            if let strippedString = Self.stripQuotes(value) {
                value = strippedString
            }

            switch key {
            case "name": p.name = value
            case "cwd": p.cwd = value
            case "start": p.start = value
            case "stop": p.stop = value
            case "port": p.port = Int(value)
            case "port_env": p.portEnv = value
            default: break
            }
        }
        if let p = pending, let materialised = p.materialise() {
            results.append(materialised)
        }
        return results
    }

    private static func stripQuotes(_ value: String) -> String? {
        guard value.count >= 2 else { return nil }
        let first = value.first
        let last = value.last
        if (first == "\"" && last == "\"") || (first == "'" && last == "'") {
            return String(value.dropFirst().dropLast())
        }
        return nil
    }
}

private final class PendingRunner {
    var name: String?
    var cwd: String?
    var start: String?
    var stop: String?
    var port: Int?
    var portEnv: String?

    func materialise() -> ParsedRunner? {
        guard let name, !name.isEmpty,
              let start, !start.isEmpty else { return nil }
        return ParsedRunner(
            name: name,
            cwd: cwd,
            start: start,
            stop: stop,
            port: port,
            portEnv: portEnv
        )
    }
}

// MARK: - Runtime status

enum RunnerStatus: Hashable, Sendable {
    case idle
    case running(pid: Int32)
    case exited(code: Int32)
    case failed(message: String)

    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }
}

/// Owns one subprocess per `[[runners]]` definition. Outputs are streamed
/// line-by-line into the shared `SignalStore` so the Signals page sees
/// them in chronological order across every runner.
@MainActor
@Observable
final class RunnerManager {
    let project: Project
    private let signals: SignalStore

    private(set) var runners: [ParsedRunner] = []
    private(set) var status: [String: RunnerStatus] = [:]
    private var processes: [String: Process] = [:]
    private var stdoutBuffers: [String: String] = [:]
    private var stderrBuffers: [String: String] = [:]

    init(project: Project, signals: SignalStore) {
        self.project = project
        self.signals = signals
    }

    func reload(from toml: String?) {
        guard let toml else {
            runners = []
            return
        }
        runners = ParsedRunner.parseAll(toml)
        // Seed `.idle` for any runner we've never started.
        for runner in runners where status[runner.name] == nil {
            status[runner.name] = .idle
        }
        // Drop status for runners that no longer exist.
        let names = Set(runners.map(\.name))
        status = status.filter { names.contains($0.key) }
    }

    func startAll() {
        for runner in runners {
            if !(status[runner.name]?.isRunning ?? false) {
                start(runner)
            }
        }
    }

    func stopAll() {
        for runner in runners {
            if status[runner.name]?.isRunning == true {
                stop(runner)
            }
        }
    }

    func start(_ runner: ParsedRunner) {
        if status[runner.name]?.isRunning == true { return }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-lc", runner.start]
        process.currentDirectoryURL = resolveCwd(for: runner)

        // Inherit the user shell env so PATH / NVM / asdf / pyenv shims
        // resolve the same way they would in a terminal. We don't bother
        // forwarding the unique-port env var here — Claude is expected to
        // have made the runner read its port_env at runtime, and the user
        // will set per-worktree overrides elsewhere.
        process.environment = ProcessInfo.processInfo.environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // Capture immutable copies for the async readers — once the
        // process starts these closures run off-actor.
        let name = runner.name
        let signals = self.signals

        stdoutBuffers[name] = ""
        stderrBuffers[name] = ""

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            guard let chunk = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                var buf = self.stdoutBuffers[name] ?? ""
                signals.appendChunk(source: name, chunk, buffer: &buf)
                self.stdoutBuffers[name] = buf
            }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            guard let chunk = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                var buf = self.stderrBuffers[name] ?? ""
                signals.appendChunk(source: name, chunk, buffer: &buf)
                self.stderrBuffers[name] = buf
            }
        }

        process.terminationHandler = { [weak self] proc in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.status[name] = .exited(code: proc.terminationStatus)
                self.processes.removeValue(forKey: name)
                // Flush any partial-line buffers as their final entry so
                // we don't silently drop unterminated tail output.
                if let tail = self.stdoutBuffers[name], !tail.isEmpty {
                    signals.append(source: name, line: tail)
                }
                if let tail = self.stderrBuffers[name], !tail.isEmpty {
                    signals.append(source: name, line: tail)
                }
                self.stdoutBuffers[name] = nil
                self.stderrBuffers[name] = nil
            }
        }

        do {
            try process.run()
            processes[name] = process
            status[name] = .running(pid: process.processIdentifier)
            signals.append(source: name, line: "› starting: \(runner.start)")
        } catch {
            status[name] = .failed(message: error.localizedDescription)
            signals.append(
                source: name,
                line: "✗ failed to start: \(error.localizedDescription)"
            )
        }
    }

    /// Stop a runner. If the runner declared an explicit `stop` command,
    /// we shell that out first (typical pattern: `pkill -f 'thing'`);
    /// otherwise we just SIGTERM the launched process directly.
    func stop(_ runner: ParsedRunner) {
        if let stop = runner.stop, !stop.isEmpty {
            let killer = Process()
            killer.executableURL = URL(fileURLWithPath: "/bin/sh")
            killer.arguments = ["-lc", stop]
            killer.currentDirectoryURL = resolveCwd(for: runner)
            killer.environment = ProcessInfo.processInfo.environment
            do {
                try killer.run()
                signals.append(source: runner.name, line: "› stopping: \(stop)")
            } catch {
                signals.append(
                    source: runner.name,
                    line: "✗ stop command failed: \(error.localizedDescription)"
                )
            }
        }

        if let process = processes[runner.name], process.isRunning {
            // Give the stop command a moment to land — many `pkill`-style
            // stoppers race with the runner's own shutdown. SIGTERM the
            // launched process directly so the terminationHandler fires
            // even if the user's stop command was a no-op.
            process.terminate()
        }
    }

    private func resolveCwd(for runner: ParsedRunner) -> URL {
        if let cwd = runner.cwd, !cwd.isEmpty {
            let url = URL(fileURLWithPath: cwd, relativeTo: project.rootPath)
            return url.standardizedFileURL
        }
        return project.rootPath
    }
}
