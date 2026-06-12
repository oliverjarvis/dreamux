import Foundation

/// The Claude Code integration is now zero-install: we ship a `claude`
/// shim at `Clayspace.app/Contents/Resources/bin/`, and `PTYShellSession`
/// prepends that directory to every spawned shell's `PATH`. When the
/// user types `claude` in a Clayspace tab they hit our shim, which
/// resolves the real binary and `exec`s it with an inline `--settings`
/// JSON that wires Stop / Notification hooks through `clayspace-hook`.
///
/// Outside Clayspace, `claude` keeps resolving to the real binary, so
/// the user's normal terminals are unaffected.
enum ClaudeCodeIntegration {
    /// Directory holding the shim CLIs.
    static var shimDirectory: URL? {
        let url = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/bin", isDirectory: true)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Path to the bundled `clayspace-hook` script.
    static var hookExecutablePath: String? {
        shimDirectory?.appendingPathComponent("clayspace-hook").path
            .nonEmptyIfExists
    }

    /// Shell snippet that invokes the Claude CLI. Normally the bare
    /// word `claude` (resolved through the spawned shell's PATH, where
    /// our shim sits first). The e2e harness sets
    /// `CLAYSPACE_CLAUDE_BIN` to a deterministic fake so Detect /
    /// Isolate / Diagnose flows don't depend on the user's PATH or
    /// zshrc; the override is shell-quoted so absolute paths with
    /// spaces survive being pasted into a terminal.
    static var claudeInvocation: String {
        if let override = ProcessInfo.processInfo.environment["CLAYSPACE_CLAUDE_BIN"],
           !override.isEmpty {
            return shellQuote(override)
        }
        return "claude"
    }

    /// Single-quote for safe shell pasting, escaping embedded single
    /// quotes the standard `'\''` way.
    private static func shellQuote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

private extension String {
    var nonEmptyIfExists: String? {
        FileManager.default.fileExists(atPath: self) ? self : nil
    }
}
