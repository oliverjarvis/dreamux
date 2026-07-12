import Foundation

/// Single owner of every per-bundle-id derivation: the emit-socket path
/// (and its `DREAMUX_EMIT_SOCKET` env input), the App Support dir that
/// holds `signals.db`, and the state dir that holds `projects.json` /
/// `connections.json` / `AppStudioData`.
///
/// The keystone of self-hosting isolation: a tagged debug build stamps a
/// unique `CFBundleIdentifier` (`com.dreamux.Dreamux.<tag>`), so every
/// path below forks automatically while untagged builds stay byte-
/// identical. All functions take injectable `bundleID` / `env` / `base`
/// params so they unit-test without touching `Bundle.main` or the real FS.
enum BundleIdentity {
    /// The untagged base identifier — also the fallback when `Bundle.main`
    /// has no id (the XCTest host, the `dreamux` CLI).
    static let baseBundleID = "com.dreamux.Dreamux"

    /// Effective `CFBundleIdentifier`, or `baseBundleID` when absent.
    static func bundleID(_ bundle: Bundle = .main) -> String {
        bundle.bundleIdentifier ?? baseBundleID
    }

    /// The build tag carried in a tagged id (`com.dreamux.Dreamux.<tag>`
    /// → `<tag>`); nil for the bare base id, an empty suffix, or any id
    /// that isn't a suffix of the base.
    static func buildTag(bundleID id: String = bundleID()) -> String? {
        let prefix = baseBundleID + "."
        guard id.hasPrefix(prefix) else { return nil }
        let tag = String(id.dropFirst(prefix.count))
        return tag.isEmpty ? nil : tag
    }

    /// Emit-socket path. `DREAMUX_EMIT_SOCKET` (non-empty) is an explicit
    /// override — the parent app reads the same variable it exports to
    /// child shells; otherwise `/tmp/dreamux-emit-<bundleID>.sock`
    /// (`/tmp` because `sun_path` caps at 104 bytes).
    static func emitSocketPath(
        env: [String: String] = ProcessInfo.processInfo.environment,
        bundleID id: String = bundleID()
    ) -> String {
        if let override = env["DREAMUX_EMIT_SOCKET"], !override.isEmpty {
            return override
        }
        return "/tmp/dreamux-emit-\(id).sock"
    }

    /// Per-bundle Application Support dir `<base>/<bundleID>/` — home of
    /// `signals.db`. Caller creates it.
    static func appSupportBundleDir(base: URL, bundleID id: String = bundleID()) -> URL {
        base.appendingPathComponent(id, isDirectory: true)
    }

    /// State dir for `projects.json` / `connections.json` /
    /// `AppStudioData`. Untagged → `<base>/Dreamux` (the legacy literal,
    /// byte-identical to pre-isolation); tagged → `<base>/<bundleID>`,
    /// co-located with that tag's `signals.db` under one deletable folder.
    static func stateDirectory(base: URL, bundleID id: String = bundleID()) -> URL {
        if buildTag(bundleID: id) == nil {
            return base.appendingPathComponent("Dreamux", isDirectory: true)
        }
        return base.appendingPathComponent(id, isDirectory: true)
    }
}
