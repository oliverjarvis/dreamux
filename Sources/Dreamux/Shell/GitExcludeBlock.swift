import Foundation

/// Rewrites one marker-delimited block in a repo's shared
/// `<repo>/.bare/info/exclude`.
///
/// Git reads the common directory's `info/exclude` for every worktree,
/// so one file per repo covers them all — and it's local-only, so
/// tracked files never change. Two independently-managed blocks share
/// this file (`SkillLinker` and `WorktreeEnvironment`), which is safe
/// only because of the invariant implemented here: every line outside
/// MY markers is preserved verbatim, and only my own block is rewritten.
enum GitExcludeBlock {
    /// Replace the block delimited by `startMarker`/`endMarker` with
    /// `patterns`, one per line. An empty `patterns` removes the block
    /// entirely. No-op when the repo has no `.bare/` — without a shared
    /// `info/exclude` there is nothing to write into. The file is only
    /// written when its bytes would actually change, so a repeat pass
    /// doesn't even touch the mtime.
    static func update(
        repoRoot: URL,
        startMarker: String,
        endMarker: String,
        patterns: [String]
    ) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: repoRoot.appendingPathComponent(".bare").path) else { return }
        let infoDir = repoRoot.appendingPathComponent(".bare/info", isDirectory: true)
        let excludeURL = infoDir.appendingPathComponent("exclude")
        try? fm.createDirectory(at: infoDir, withIntermediateDirectories: true)

        let existing = (try? String(contentsOf: excludeURL, encoding: .utf8)) ?? ""
        var kept: [String] = []
        var inBlock = false
        for line in existing.components(separatedBy: "\n") {
            if line == startMarker { inBlock = true; continue }
            if line == endMarker { inBlock = false; continue }
            if !inBlock { kept.append(line) }
        }
        while kept.last?.isEmpty == true { kept.removeLast() }

        var output = kept
        if !patterns.isEmpty {
            if !output.isEmpty { output.append("") }
            output.append(startMarker)
            output.append(contentsOf: patterns)
            output.append(endMarker)
        }
        let text = output.joined(separator: "\n") + "\n"
        if text != existing {
            try? text.write(to: excludeURL, atomically: true, encoding: .utf8)
        }
    }
}
