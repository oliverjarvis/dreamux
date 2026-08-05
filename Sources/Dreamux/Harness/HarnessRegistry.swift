import Foundation

/// Reads `harnesses.json` — the single source of truth both Swift and
/// `dreamux-hook` consume — and answers which harnesses exist and which
/// are actually installed.
///
/// The file sits beside the shims (`Tools/` in a checkout,
/// `Contents/Resources/bin/` in the bundle) so one resolution rule works
/// in both layouts. `DREAMUX_HARNESSES_JSON` overrides it for tests.
@MainActor
final class HarnessRegistry {
    static let shared = HarnessRegistry(catalog: HarnessRegistry.load(from: HarnessRegistry.catalogURL))

    let catalog: HarnessCatalog

    init(catalog: HarnessCatalog) {
        self.catalog = catalog
    }

    static var catalogURL: URL? {
        if let override = ProcessInfo.processInfo.environment["DREAMUX_HARNESSES_JSON"],
           !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        guard let dir = ClaudeCodeIntegration.shimDirectory else { return nil }
        let url = dir.appendingPathComponent("harnesses.json")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    nonisolated static func load(from url: URL?) -> HarnessCatalog {
        guard let url,
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(HarnessCatalog.self, from: data),
              !decoded.harnesses.isEmpty
        else { return .claudeOnlyFallback }
        return decoded
    }

    func adapter(id: String) -> HarnessAdapter? {
        catalog.harnesses.first { $0.id == id }
    }

    /// Harnesses whose binary resolves somewhere on `PATH` other than
    /// our own shim directory (which would only find our shim again).
    func installed() -> [HarnessAdapter] {
        let shimDir = ClaudeCodeIntegration.shimDirectory?.path
        let dirs = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":").map(String.init)
            .filter { !$0.isEmpty && $0 != shimDir }
        return catalog.harnesses.filter { adapter in
            adapter.binaryNames.contains { name in
                dirs.contains { FileManager.default.isExecutableFile(atPath: "\($0)/\(name)") }
            }
        }
    }
}
