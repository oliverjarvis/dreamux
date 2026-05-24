import Foundation
import Observation

/// Strategy for how a feature's worktree should run side-by-side with
/// other worktrees of the same repo. Drives both the Detect prompt
/// (whether we ask Claude to plan for unique ports) and the Modify
/// flow (whether we follow up with a code-modification pass).
enum RunPortStrategy: String, CaseIterable, Identifiable, Codable, Sendable {
    /// Each worktree binds a different port via an env-var / config
    /// override. Requires a code-modification pass.
    case uniquePort = "unique"
    /// Worktrees share the original port — running a new feature
    /// implicitly replaces whichever worktree was running before.
    case replace = "replace"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .uniquePort: return "Each worktree on its own port"
        case .replace: return "New worktree replaces previous run"
        }
    }

    var subtitle: String {
        switch self {
        case .uniquePort:
            return "We'll ask Claude to adjust the code so the port is read from an env var, then write the resolved port per-runner into run.toml."
        case .replace:
            return "No code changes — only one feature can run at a time on the shared port."
        }
    }
}

/// Thin wrapper around `<project>/.clayspace/run.toml`. We don't parse
/// the TOML; Claude writes it and we surface the raw text so the user
/// can see what was produced. Add structured parsing once the format
/// stabilises.
@MainActor
@Observable
final class RunConfigStore {
    let project: Project
    let configURL: URL
    /// Raw TOML text. `nil` when the file doesn't exist yet.
    private(set) var rawTOML: String?
    var portStrategy: RunPortStrategy = .uniquePort

    init(project: Project) {
        self.project = project
        self.configURL = project.rootPath
            .appendingPathComponent(".clayspace", isDirectory: true)
            .appendingPathComponent("run.toml")
        reload()
    }

    var exists: Bool { rawTOML != nil }

    func reload() {
        rawTOML = (try? String(contentsOf: configURL, encoding: .utf8))
    }
}
