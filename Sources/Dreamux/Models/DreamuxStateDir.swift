import Foundation

/// The per-project `.dreamux/` runtime-state directory (plan queue, run
/// ledger, sidebar layout). Creation always drops a `.gitignore` of `*`
/// so runtime state never travels via git: a clone must start with an
/// empty slate — a committed auto-run toggle arriving WITHOUT the
/// ledger/fired-once records would auto-launch every `**Runs:**
/// parallel` plan in the docs history on first open.
enum DreamuxStateDir {
    /// Create the directory containing `fileURL` (if needed) and ensure
    /// its `.gitignore`. Callers invoke this instead of raw
    /// `createDirectory` on every save — cheap, idempotent, and it
    /// retrofits existing projects the next time any state file writes.
    static func ensure(containing fileURL: URL) {
        let dir = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        let gitignore = dir.appendingPathComponent(".gitignore")
        if !FileManager.default.fileExists(atPath: gitignore.path) {
            try? Data("*\n".utf8).write(to: gitignore, options: .atomic)
        }
    }
}
