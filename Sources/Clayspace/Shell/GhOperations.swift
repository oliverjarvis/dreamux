import Foundation

enum GhError: LocalizedError {
    case ghNotInstalled
    case commandFailed(args: [String], stderr: String)

    var errorDescription: String? {
        switch self {
        case .ghNotInstalled:
            return "The GitHub CLI (gh) isn't installed. Install it with `brew install gh` and run `gh auth login`."
        case .commandFailed(let args, let stderr):
            let cmd = (["gh"] + args).joined(separator: " ")
            let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "gh command failed: \(cmd)" : "gh: \(trimmed)"
        }
    }
}

/// Async helpers around the GitHub CLI for the merge sheet's
/// "push the feature as a PR" path. Everything funnels through `gh` so
/// we inherit the user's existing auth — Clayspace never stores a
/// token. Like the claude shim, the binary is overridable via
/// `CLAYSPACE_GH_BIN` so tests and the e2e harness can substitute a
/// deterministic fake that talks to an on-disk "remote".
enum GhOperations {
    /// Status of the PR for a branch, as GitHub sees it. We ask gh
    /// rather than inferring from git ancestry because squash- and
    /// rebase-merged PRs produce commits unrelated to the local feature
    /// tip — ancestry would report those as never merged.
    struct PRStatus: Equatable, Sendable {
        enum State: String, Sendable {
            case open = "OPEN"
            case merged = "MERGED"
            case closed = "CLOSED"
        }
        let state: State
        let url: String
    }

    /// Path of the gh binary to exec: the `CLAYSPACE_GH_BIN` override
    /// when set, otherwise whatever `gh` resolves to on PATH.
    private static var ghInvocation: [String] {
        if let override = ProcessInfo.processInfo.environment["CLAYSPACE_GH_BIN"],
           !override.isEmpty {
            return [override]
        }
        return ["/usr/bin/env", "gh"]
    }

    /// True when a gh binary is reachable. Cheap enough to run during
    /// the merge sheet's pre-check; failure shows the install hint
    /// instead of a dead button.
    static func isAvailable() async -> Bool {
        (try? await runGh(["--version"], in: nil)) != nil
    }

    /// Create a PR for `branch` against `base`, returning its URL.
    /// Runs inside the feature worktree so gh resolves the right repo
    /// from `origin`. If a PR for this branch already exists, gh
    /// errors — we recover by looking the existing PR up and returning
    /// it, so re-clicking "Create PR" after a sheet re-open is
    /// idempotent rather than a failure.
    static func createPR(
        branch: String,
        base: String,
        title: String,
        body: String,
        in worktreeURL: URL
    ) async throws -> String {
        do {
            let output = try await runGh(
                ["pr", "create",
                 "--head", branch,
                 "--base", base,
                 "--title", title,
                 "--body", body],
                in: worktreeURL
            )
            // gh prints the new PR's URL as the last non-empty line.
            if let url = output
                .split(whereSeparator: { $0.isNewline })
                .map({ $0.trimmingCharacters(in: .whitespaces) })
                .last(where: { $0.hasPrefix("http") || $0.hasPrefix("file://") }) {
                return url
            }
            return output.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch let GhError.commandFailed(args, stderr) {
            if stderr.lowercased().contains("already exists"),
               let existing = await prStatus(branch: branch, in: worktreeURL) {
                return existing.url
            }
            throw GhError.commandFailed(args: args, stderr: stderr)
        }
    }

    /// Look up the PR associated with `branch`. nil when there is no
    /// PR (or gh/auth is unavailable) — callers treat that as "nothing
    /// to report", not an error, since this runs from the sheet's
    /// polling loop.
    static func prStatus(branch: String, in worktreeURL: URL) async -> PRStatus? {
        guard let output = try? await runGh(
            ["pr", "view", branch, "--json", "state,url"],
            in: worktreeURL
        ) else { return nil }
        guard let data = output.data(using: .utf8),
              let parsed = try? JSONDecoder().decode(PRViewPayload.self, from: data),
              let state = PRStatus.State(rawValue: parsed.state.uppercased())
        else { return nil }
        return PRStatus(state: state, url: parsed.url)
    }

    private struct PRViewPayload: Decodable {
        let state: String
        let url: String
    }

    // MARK: - Process plumbing

    /// Run gh non-interactively and return stdout. Mirrors
    /// `GitOperations.runGit`'s contract (background queue, prompt-free
    /// env, stderr folded into the error) without the line-streaming —
    /// gh calls here are short and their output is consumed whole.
    private static func runGh(_ args: [String], in cwd: URL?) async throws -> String {
        let invocation = ghInvocation
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: invocation[0])
                process.arguments = Array(invocation.dropFirst()) + args
                if let cwd { process.currentDirectoryURL = cwd }

                var env = ProcessInfo.processInfo.environment
                // Never let gh open an editor or pager, and disable
                // its interactive prompts — a hung sheet is worse than
                // a surfaced auth error.
                env["GH_PROMPT_DISABLED"] = "1"
                env["GH_PAGER"] = "cat"
                env["GIT_TERMINAL_PROMPT"] = "0"
                process.environment = env

                let outPipe = Pipe()
                let errPipe = Pipe()
                process.standardOutput = outPipe
                process.standardError = errPipe

                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: GhError.ghNotInstalled)
                    return
                }
                // Drain before waiting so a chatty gh can't deadlock on
                // a full pipe buffer (same hazard runGit guards against).
                let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()

                let outStr = String(data: outData, encoding: .utf8) ?? ""
                let errStr = String(data: errData, encoding: .utf8) ?? ""
                if process.terminationStatus != 0 {
                    continuation.resume(throwing: GhError.commandFailed(
                        args: args,
                        stderr: errStr.isEmpty ? outStr : errStr
                    ))
                } else {
                    continuation.resume(returning: outStr)
                }
            }
        }
    }
}
