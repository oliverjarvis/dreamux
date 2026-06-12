import Foundation

/// Finds a node installation that actually runs. `npx` (which
/// `SkillsCLI` uses) needs node, but Clayspace.app launches with a
/// minimal GUI environment — and even a login shell can resolve `node`
/// to a broken asdf shim ("No version is set"). So candidates are
/// gathered (login-shell PATH first, then version managers
/// newest-first, then Homebrew/system) and each is *executed*
/// (`node --version`) until one works.
enum NodeDetector {
    struct Resolution: Equatable, Sendable {
        /// Directory containing working `node` and `npx` binaries.
        let binDirectory: String
        let version: String
    }

    static func detect() async -> Resolution? {
        await detect(candidates: await defaultCandidates())
    }

    /// Test seam: probe an explicit candidate list, in order.
    static func detect(candidates: [String]) async -> Resolution? {
        let fm = FileManager.default
        for dir in candidates {
            let node = (dir as NSString).appendingPathComponent("node")
            guard fm.isExecutableFile(atPath: node) else { continue }
            if let version = await probeVersion(nodePath: node) {
                return Resolution(binDirectory: dir, version: version)
            }
        }
        return nil
    }

    static func defaultCandidates() async -> [String] {
        var dirs: [String] = []
        if let shellDir = await loginShellNodeDirectory() {
            dirs.append(shellDir)
        }
        let home = NSHomeDirectory()
        dirs += versionedBinDirs(under: "\(home)/.asdf/installs/nodejs")
        dirs += versionedBinDirs(under: "\(home)/.nvm/versions/node")
        dirs += ["/opt/homebrew/bin", "/usr/local/bin"]
        return dirs
    }

    // MARK: - Internals

    /// `~/.asdf/installs/nodejs/<v>/bin` etc., newest version first.
    private static func versionedBinDirs(under root: String) -> [String] {
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []
        return entries
            .sorted { $0.compare($1, options: .numeric) == .orderedDescending }
            .map { "\(root)/\($0)/bin" }
    }

    /// Where the user's login shell resolves `node` — respects their
    /// real setup (nvm/asdf init in zshrc/zprofile) when it works.
    private static func loginShellNodeDirectory() async -> String? {
        let output = await runProcess(
            executable: "/bin/zsh", arguments: ["-l", "-c", "command -v node"]
        )
        guard let path = output?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty, path.hasPrefix("/")
        else { return nil }
        return (path as NSString).deletingLastPathComponent
    }

    /// nil unless `node --version` exits 0 and prints a `v…` string.
    private static func probeVersion(nodePath: String) async -> String? {
        guard let output = await runProcess(executable: nodePath, arguments: ["--version"]) else {
            return nil
        }
        let version = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return version.hasPrefix("v") ? version : nil
    }

    /// Tiny process runner: stdout on success, nil on failed launch or
    /// non-zero exit. Probes are short-lived; no streaming needed.
    private static func runProcess(executable: String, arguments: [String]) async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                let outPipe = Pipe()
                process.standardOutput = outPipe
                process.standardError = Pipe()
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: nil)
                    return
                }
                let data = outPipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: String(data: data, encoding: .utf8))
            }
        }
    }
}
