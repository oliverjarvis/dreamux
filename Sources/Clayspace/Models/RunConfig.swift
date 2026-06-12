import Foundation
import Observation

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
