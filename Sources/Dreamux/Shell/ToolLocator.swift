import Foundation

/// Finds a CLI on disk without trusting the PATH the app happened to
/// inherit.
///
/// Dreamux.app started from ~/Applications is launched by launchd, so
/// it inherits the GUI PATH — `/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin`
/// — which omits `/opt/homebrew/bin`, where Apple Silicon Homebrew puts
/// everything. `/usr/bin/env gh` therefore exits 127 in the installed
/// app while working fine in a dev build (RunnerManager launches that
/// one through `/bin/sh -lc`, a login shell that runs path_helper). So
/// candidates are probed on the filesystem instead: PATH first, so a
/// deliberate install still wins, then the well-known install
/// directories `NodeDetector` and `MCPInstaller` already fall back to.
///
/// Deliberately a filesystem check, never an exec and never a login
/// shell: this runs from the merge sheet's pre-check, which must not
/// stall behind someone's slow shell profile.
enum ToolLocator {
    /// Where Homebrew (Apple Silicon, then Intel/manual) installs CLIs.
    static let wellKnownDirectories = ["/opt/homebrew/bin", "/usr/local/bin"]

    /// Absolute path of `tool`, or nil when it isn't installed anywhere
    /// we look — callers surface that as "install the CLI", never as an
    /// error.
    ///
    /// `overrideKey` (e.g. `DREAMUX_GH_BIN`) outranks every probe and is
    /// returned verbatim, *without* an existence check: pointing it at a
    /// path that isn't there is how the e2e harness and tests say
    /// "pretend this tool is missing". Falling back to a real binary
    /// there would make that impossible to express.
    static func resolve(
        tool: String,
        overrideKey: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        wellKnownDirectories: [String] = ToolLocator.wellKnownDirectories,
        fileManager: FileManager = .default
    ) -> String? {
        if let overrideKey,
           let override = environment[overrideKey],
           !override.isEmpty {
            return override
        }

        let pathDirectories = (environment["PATH"] ?? "")
            .split(separator: ":", omittingEmptySubsequences: true)
            .map(String.init)

        for directory in pathDirectories + wellKnownDirectories {
            let candidate = (directory as NSString).appendingPathComponent(tool)
            if isRunnableFile(candidate, fileManager) {
                return candidate
            }
        }
        return nil
    }

    /// `isExecutableFile` alone answers yes for directories (they're
    /// searchable), so a directory named `gh` would resolve as the CLI.
    /// Require a real file too.
    private static func isRunnableFile(_ path: String, _ fileManager: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory),
              !isDirectory.boolValue
        else { return false }
        return fileManager.isExecutableFile(atPath: path)
    }
}
