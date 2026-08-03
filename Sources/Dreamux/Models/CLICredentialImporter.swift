import Foundation

/// Reads an existing CLI login and yields a token + a sensible default
/// Connection shape, so "Import from gh/eas" is one click.
enum CLICredentialImporter {
    struct Draft: Equatable {
        var token: String
        var label: String
        var kind: AuthKind
        var hosts: [String]
        var preferredID: String
        var source: Connection.Source
    }

    /// Known providers surfaced in the UI.
    static let providers: [(id: String, label: String)] = [
        ("gh", "GitHub (gh CLI)"),
        ("expo", "Expo (eas)"),
    ]

    /// Pure: build a Draft from a provider's already-captured token.
    static func draft(provider: String, token: String) -> Draft? {
        switch provider {
        case "gh":
            return Draft(
                token: token,
                label: "GitHub (gh CLI)",
                kind: .header(headerName: "Authorization", valueTemplate: "Bearer {token}"),
                hosts: ["api.github.com"],
                preferredID: "github",
                source: .importedFromCLI(tool: "gh")
            )
        case "expo":
            return Draft(
                token: token,
                label: "Expo (eas)",
                kind: .header(headerName: "Authorization", valueTemplate: "Bearer {token}"),
                hosts: ["api.expo.dev"],
                preferredID: "expo",
                source: .importedFromCLI(tool: "eas")
            )
        default:
            return nil
        }
    }

    /// Pure: parse a provider's CLI output into a token (nil if absent/empty).
    /// Same trim-and-nil-if-empty rule for every provider — only `gh` runs a
    /// CLI whose stdout needs parsing today, but the signature stays generic
    /// so a future provider slots in without a new code path.
    static func parseToken(provider: String, cliOutput: String) -> String? {
        let trimmed = cliOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Pure: parse Expo `~/.expo/state.json` contents into a token.
    private struct ExpoState: Decodable {
        struct Auth: Decodable {
            var sessionSecret: String?
        }
        var auth: Auth?
    }

    static func parseExpoStateJSON(_ contents: String) -> String? {
        guard let data = contents.data(using: .utf8),
              let state = try? JSONDecoder().decode(ExpoState.self, from: data),
              let secret = state.auth?.sessionSecret,
              !secret.isEmpty
        else { return nil }
        return secret
    }

    /// Live: run the provider's CLI (via AppletShell-style exec) and return a
    /// Draft, or nil if the user isn't logged in. (Build-gated; the parsing
    /// above is the tested part.)
    @MainActor static func importFromCLI(provider: String) async -> Draft? {
        switch provider {
        case "gh":
            guard let output = try? await runGhAuthToken(),
                  let token = parseToken(provider: "gh", cliOutput: output)
            else { return nil }
            return draft(provider: "gh", token: token)

        case "expo":
            if let envToken = ProcessInfo.processInfo.environment["EXPO_TOKEN"],
               let token = parseToken(provider: "expo", cliOutput: envToken) {
                return draft(provider: "expo", token: token)
            }
            let stateURL = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".expo", isDirectory: true)
                .appendingPathComponent("state.json", isDirectory: false)
            guard let data = try? Data(contentsOf: stateURL),
                  let contents = String(data: data, encoding: .utf8),
                  let token = parseExpoStateJSON(contents)
            else { return nil }
            return draft(provider: "expo", token: token)

        default:
            return nil
        }
    }

    /// Live: run an arbitrary user/applet-supplied command via `/bin/sh -lc`
    /// and return its trimmed stdout as a token, or nil on empty output /
    /// non-zero exit / launch failure. The command is ALWAYS user-triggered
    /// (never auto-run) — see the spec's consent rule; this is just the
    /// runner, not the gate.
    static func runCommand(_ command: String) async -> String? {
        let output: String? = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/sh")
                process.arguments = ["-lc", command]
                process.environment = ProcessInfo.processInfo.environment

                let outPipe = Pipe()
                let errPipe = Pipe()
                process.standardOutput = outPipe
                process.standardError = errPipe

                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: nil)
                    return
                }
                // Drain before waiting so a chatty command can't deadlock on
                // a full pipe buffer.
                let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                _ = errPipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()

                guard process.terminationStatus == 0 else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: String(data: outData, encoding: .utf8) ?? "")
            }
        }
        guard let output else { return nil }
        return parseToken(provider: "", cliOutput: output)
    }

    // MARK: - Process plumbing (gh)

    /// Path of the gh binary to exec: the `DREAMUX_GH_BIN` override when
    /// set (mirrors `GhOperations`), otherwise gh wherever `ToolLocator`
    /// finds it — PATH alone misses Homebrew in the installed app, which
    /// turned "Import from gh" into a silent no-op there.
    private static var ghInvocation: [String] {
        if let gh = ToolLocator.resolve(tool: "gh", overrideKey: "DREAMUX_GH_BIN") {
            return [gh]
        }
        return ["/usr/bin/env", "gh"]
    }

    /// Runs `gh auth token` non-interactively and returns raw stdout
    /// (untrimmed — `parseToken` does the trimming). Throws (rather than
    /// returning nil) on a launch failure or non-zero exit so the caller's
    /// `try?` collapses "gh missing" and "not logged in" alike into nil.
    private static func runGhAuthToken() async throws -> String {
        let invocation = ghInvocation
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: invocation[0])
                process.arguments = Array(invocation.dropFirst()) + ["auth", "token"]

                var env = ProcessInfo.processInfo.environment
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
                    continuation.resume(throwing: error)
                    return
                }
                // Drain before waiting so a chatty gh can't deadlock on a
                // full pipe buffer.
                let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                _ = errPipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()

                guard process.terminationStatus == 0 else {
                    continuation.resume(throwing: CocoaError(.fileReadUnknown))
                    return
                }
                continuation.resume(returning: String(data: outData, encoding: .utf8) ?? "")
            }
        }
    }
}
