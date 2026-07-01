import Foundation

/// Report of one reconcile pass — surfaced in the UI and asserted in
/// tests. `skipped` lists collisions left untouched (a real file or
/// directory already sits where a link would go).
struct SkillLinkReport: Equatable, Sendable {
    var linked: [String] = []
    var skipped: [String] = []
}

/// Fans project-scope skills out to every git worktree in the project.
///
/// `npx skills add` (cwd = project root) puts canonical copies in
/// `<project>/.agents/skills/`. Agents, however, discover skills from
/// their starting directory up to the *repository* root — and every
/// agent in Dreamux starts inside a repo worktree, below the project
/// root, so the canonical copies are invisible to them. For each
/// worktree of each repo we therefore create
///
///     <worktree>/.agents/skills/<name> → relative link to canonical
///     <worktree>/.claude/skills/<name> → same target
///
/// (`.agents/skills` is the agentskills.io universal directory — Codex
/// and current Claude Code read it; the `.claude/skills` link covers
/// older Claude Code builds.) Feature aggregation dirs under
/// `features/<feature>/<repo>` are symlinks into these same worktrees,
/// so they're covered automatically.
///
/// Git noise is suppressed with a managed block in each repo's shared
/// `.bare/info/exclude` — local-only, never touches tracked files.
/// The pass is idempotent: stale links are repaired, links for
/// uninstalled skills removed, and anything that isn't a symlink into
/// the project's canonical store is left alone and reported.
enum SkillLinker {
    static let excludeBlockStart = "# >>> dreamux skills (managed) >>>"
    static let excludeBlockEnd = "# <<< dreamux skills (managed) <<<"
    private static let agentDirNames = [".agents", ".claude"]

    /// Skills canonically installed at the project root — the
    /// subdirectories of `<project>/.agents/skills/`.
    static func installedSkillNames(projectRoot: URL) -> [String] {
        let skillsDir = projectRoot.appendingPathComponent(".agents/skills", isDirectory: true)
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: skillsDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return entries
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false }
            .map(\.lastPathComponent)
            .sorted()
    }

    @discardableResult
    static func reconcile(projectRoot: URL) -> SkillLinkReport {
        let skills = installedSkillNames(projectRoot: projectRoot)
        var report = SkillLinkReport()
        for repoDir in repoDirectories(projectRoot: projectRoot) {
            // A directory under repos/ without .bare isn't a Dreamux
            // repo layout — there's no shared info/exclude to suppress
            // the links, so linking into it would create git noise.
            guard FileManager.default.fileExists(
                atPath: repoDir.appendingPathComponent(".bare").path)
            else { continue }
            updateExcludeFile(repoRoot: repoDir, skills: skills)
            for worktree in Repository(rootURL: repoDir).worktrees {
                reconcile(worktree: worktree, projectRoot: projectRoot,
                          skills: skills, report: &report)
            }
        }
        return report
    }

    // MARK: - Worktree pass

    private static func reconcile(
        worktree: URL,
        projectRoot: URL,
        skills: [String],
        report: inout SkillLinkReport
    ) {
        let fm = FileManager.default
        // No standardizedFileURL anywhere in here: every URL below is
        // built by appending literal components to projectRoot, so both
        // sides of every comparison share one spelling and plain
        // component math is correct (see lexicallyResolving for why
        // filesystem-dependent normalization must be avoided).
        let canonicalRoot = projectRoot
            .appendingPathComponent(".agents/skills", isDirectory: true)

        for agentDir in agentDirNames {
            let skillsParent = worktree.appendingPathComponent(
                "\(agentDir)/skills", isDirectory: true)

            // Remove links of ours whose skill is no longer installed.
            let existing = (try? fm.contentsOfDirectory(atPath: skillsParent.path)) ?? []
            for entry in existing where !skills.contains(entry) {
                let url = skillsParent.appendingPathComponent(entry)
                if isOurLink(url, canonicalRoot: canonicalRoot) {
                    try? fm.removeItem(at: url)
                }
            }

            for skill in skills {
                let linkURL = skillsParent.appendingPathComponent(skill)
                let canonical = canonicalRoot.appendingPathComponent(skill, isDirectory: true)
                let target = relativePath(from: skillsParent, to: canonical)

                if let existingDest = try? fm.destinationOfSymbolicLink(atPath: linkURL.path) {
                    if existingDest == target { continue }
                    if isOurLink(linkURL, canonicalRoot: canonicalRoot) {
                        try? fm.removeItem(at: linkURL)   // stale — repair below
                    } else {
                        report.skipped.append("\(linkURL.path) (foreign symlink)")
                        continue
                    }
                } else if fm.fileExists(atPath: linkURL.path) {
                    // Real file/dir — repo-owned skill. Never touch it.
                    report.skipped.append("\(linkURL.path) (repo-owned)")
                    continue
                }

                do {
                    try fm.createDirectory(at: skillsParent, withIntermediateDirectories: true)
                    try fm.createSymbolicLink(atPath: linkURL.path, withDestinationPath: target)
                    report.linked.append(linkURL.path)
                } catch {
                    report.skipped.append("\(linkURL.path) (\(error.localizedDescription))")
                }
            }

            removeIfEmpty(skillsParent)
            removeIfEmpty(worktree.appendingPathComponent(agentDir, isDirectory: true))
        }
    }

    /// A symlink we manage: its destination resolves inside the
    /// project's canonical skills store.
    private static func isOurLink(_ url: URL, canonicalRoot: URL) -> Bool {
        guard let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)
        else { return false }
        let resolved = lexicallyResolving(dest, against: url.deletingLastPathComponent())
        return resolved.hasPrefix(canonicalRoot.path + "/")
            || resolved == canonicalRoot.path
    }

    /// Resolve a symlink destination against the link's directory with
    /// pure component math: absolute paths pass through, "." is
    /// dropped, ".." pops one component (never above the root).
    ///
    /// Filesystem-independent folding is required here, not a nicety:
    /// `URL.standardizedFileURL` strips macOS's `/private` prefix only
    /// when the path currently EXISTS, so identity built on it flips
    /// across install/uninstall — the moment a skill's canonical dir is
    /// deleted, its links resolve to the `/private/…` spelling while
    /// `canonicalRoot` keeps the `/var/…` one, `isOurLink` says no, and
    /// the stale links leak forever. Lexical folding is physically
    /// correct for links we manage (every component below the project
    /// root is a real directory we own, no symlinked ancestors inside
    /// the walk); a foreign link that mis-folds merely gets skipped,
    /// which is the conservative outcome.
    static func lexicallyResolving(_ path: String, against base: URL) -> String {
        if path.hasPrefix("/") { return path }
        var parts = base.pathComponents   // absolute file URL: starts with "/"
        for component in path.split(separator: "/") {
            switch component {
            case ".":
                continue
            case "..":
                if parts.count > 1 { parts.removeLast() }   // never above root
            default:
                parts.append(String(component))
            }
        }
        // parts == ["/"] must join to "/", not ""; otherwise drop the
        // leading "/" component and rebuild from the root.
        return parts.count == 1 ? "/" : "/" + parts.dropFirst().joined(separator: "/")
    }

    private static func removeIfEmpty(_ dir: URL) {
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? ["x"]
        if contents.isEmpty {
            try? FileManager.default.removeItem(at: dir)
        }
    }

    // MARK: - Exclude management

    /// Rewrite the managed block in `<repo>/.bare/info/exclude`. Git
    /// reads the common dir's info/exclude for every worktree, so one
    /// file per repo covers them all — and it's local-only, so tracked
    /// files never change.
    private static func updateExcludeFile(repoRoot: URL, skills: [String]) {
        let infoDir = repoRoot.appendingPathComponent(".bare/info", isDirectory: true)
        let excludeURL = infoDir.appendingPathComponent("exclude")
        let fm = FileManager.default
        guard fm.fileExists(atPath: repoRoot.appendingPathComponent(".bare").path) else { return }
        try? fm.createDirectory(at: infoDir, withIntermediateDirectories: true)

        let existing = (try? String(contentsOf: excludeURL, encoding: .utf8)) ?? ""
        var kept: [String] = []
        var inBlock = false
        for line in existing.components(separatedBy: "\n") {
            if line == excludeBlockStart { inBlock = true; continue }
            if line == excludeBlockEnd { inBlock = false; continue }
            if !inBlock { kept.append(line) }
        }
        while kept.last?.isEmpty == true { kept.removeLast() }

        var output = kept
        if !skills.isEmpty {
            if !output.isEmpty { output.append("") }
            output.append(excludeBlockStart)
            for skill in skills {
                // Leading "/" anchors the pattern to the worktree root.
                output.append("/.agents/skills/\(skill)")
                output.append("/.claude/skills/\(skill)")
            }
            output.append(excludeBlockEnd)
        }
        let text = output.joined(separator: "\n") + "\n"
        if text != existing {
            try? text.write(to: excludeURL, atomically: true, encoding: .utf8)
        }
    }

    // MARK: - Discovery

    private static func repoDirectories(projectRoot: URL) -> [URL] {
        let reposDir = projectRoot.appendingPathComponent("repos", isDirectory: true)
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: reposDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return entries
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Relative path from directory `dir` to `target`, by pure
    /// component math. Both URLs must share one spelling of their
    /// common ancestor (true for everything SkillLinker builds — all
    /// URLs derive from the same `projectRoot`); no filesystem access,
    /// so the result is stable whether or not the paths exist yet.
    static func relativePath(from dir: URL, to target: URL) -> String {
        let fromParts = dir.pathComponents
        let toParts = target.pathComponents
        var common = 0
        while common < min(fromParts.count, toParts.count), fromParts[common] == toParts[common] {
            common += 1
        }
        let ups = Array(repeating: "..", count: fromParts.count - common)
        return (ups + toParts[common...]).joined(separator: "/")
    }
}
