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
}

private extension String {
    var nonEmptyIfExists: String? {
        FileManager.default.fileExists(atPath: self) ? self : nil
    }
}
