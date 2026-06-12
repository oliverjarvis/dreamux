import Foundation

/// Scope a skill operation applies to: the user's home directory (`-g`
/// installs, picked up by agents everywhere) or one Clayspace project's
/// root, where canonical copies live under `<project>/.agents/skills/`.
enum SkillScope: Hashable, Sendable {
    case global
    case project(URL)

    /// Directory `npx skills` runs in. Global commands also pass `-g`,
    /// so for them the cwd only needs to exist.
    var workingDirectory: URL {
        switch self {
        case .global:
            return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        case .project(let root):
            return root
        }
    }

    var isGlobal: Bool {
        if case .global = self { return true }
        return false
    }
}

/// One result row from the public search endpoint
/// (`https://skills.sh/api/search?q=…`).
struct RegistrySkill: Identifiable, Hashable, Decodable, Sendable {
    /// Stable registry id: `<owner>/<repo>/<skill>`.
    let id: String
    /// Skill slug within its source repo — what `add -s` takes.
    let skillId: String
    let name: String
    let installs: Int
    /// `<owner>/<repo>` — what `npx skills add` takes as its package.
    let source: String

    /// Public page for the skill, used as a fallback when preview fails.
    var webURL: URL? {
        URL(string: "https://skills.sh/\(source)/\(skillId)")
    }
}

struct SkillSearchResponse: Decodable, Sendable {
    let skills: [RegistrySkill]
}

/// One entry from `npx skills list --json`.
struct InstalledSkill: Identifiable, Hashable, Decodable, Sendable {
    let name: String
    /// Canonical on-disk path (`…/.agents/skills/<name>`).
    let path: String
    /// "project" or "global", as the CLI reports it.
    let scope: String
    let agents: [String]

    var id: String { path }
    var isGlobal: Bool { scope == "global" }
}
