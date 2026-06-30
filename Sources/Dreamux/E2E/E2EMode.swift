import Foundation

/// Process-wide switches for the e2e automation harness. Everything in
/// `Sources/Dreamux/E2E/` keys off `isActive`, which is true only
/// when the launcher set `DREAMUX_E2E_SOCKET` — so a normal user
/// launch never starts a socket server, never registers stores, and
/// never consumes bridge state. See `Scripts/e2e/PROTOCOL.md` for the
/// full environment contract.
enum E2EMode {
    /// Filesystem path the automation server binds its Unix domain
    /// socket to. `nil` (the normal case) disables the whole harness.
    static var socketPath: String? {
        guard let value = ProcessInfo.processInfo.environment["DREAMUX_E2E_SOCKET"],
              !value.isEmpty else { return nil }
        return value
    }

    /// True when this process is being driven by the e2e harness.
    static var isActive: Bool { socketPath != nil }

    /// Folder name (under `DREAMUX_PROJECTS_ROOT`) of a project the
    /// app should open a window for right after launch, so the driver
    /// doesn't have to script the Home view's project grid.
    static var autoOpenProjectName: String? {
        guard let value = ProcessInfo.processInfo.environment["DREAMUX_E2E_AUTOOPEN"],
              !value.isEmpty else { return nil }
        return value
    }
}
