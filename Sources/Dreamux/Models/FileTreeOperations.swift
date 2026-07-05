import Foundation

/// Errors the file tree's mutating verbs surface in the rename/create
/// sheets. Equatable so tests can pin exact cases.
enum FileTreeOperationError: LocalizedError, Equatable {
    case alreadyExists(String)
    case invalidName(String)

    var errorDescription: String? {
        switch self {
        case .alreadyExists(let name):
            return "\"\(name)\" already exists here."
        case .invalidName(let name):
            return name.isEmpty
                ? "Name can't be empty."
                : "\"\(name)\" isn't a valid file name."
        }
    }
}

/// The file tree's file-system verbs and shell/path helpers — kept off
/// the views so the behavior that can corrupt a worktree is unit-tested
/// against real temp directories.
enum FileTreeOperations {

    /// POSIX single-quote escaping: wrap in ', turn embedded ' into
    /// '\'' (close, escaped quote, reopen). Round-trips any byte
    /// sequence except NUL through /bin/sh unchanged.
    static func shellEscaped(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Path of `url` relative to `root` (no leading slash), or the
    /// absolute path when `url` isn't under `root` — a wrong relative
    /// path pasted into a terminal is worse than a long absolute one.
    static func relativePath(of url: URL, under root: URL) -> String {
        let standardizedRoot = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        if path == standardizedRoot { return "." }
        let rootPath = standardizedRoot.hasSuffix("/")
            ? standardizedRoot
            : standardizedRoot + "/"
        guard path.hasPrefix(rootPath) else { return path }
        return String(path.dropFirst(rootPath.count))
    }

    @discardableResult
    static func createFile(named name: String, in directory: URL) throws -> URL {
        let target = try validatedTarget(named: name, in: directory)
        // FileManager.createFile(atPath:) returns a Bool we mustn't
        // ignore: a read-only or vanished directory silently "succeeds"
        // and hands back a URL for a file that doesn't exist, so the
        // sheet dismisses and Monaco opens a dead tab. Data().write
        // throws a real error instead, and .withoutOverwriting makes
        // the create atomic — a check-then-create race lands on
        // .alreadyExists rather than silently truncating a file that
        // appeared between validatedTarget's check and this write.
        do {
            try Data().write(to: target, options: .withoutOverwriting)
        } catch CocoaError.fileWriteFileExists {
            throw FileTreeOperationError.alreadyExists(name)
        }
        return target
    }

    @discardableResult
    static func createFolder(named name: String, in directory: URL) throws -> URL {
        let target = try validatedTarget(named: name, in: directory)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        return target
    }

    /// Known limitation (tracked as a follow-up, not fixed here): an
    /// open Monaco editor tab holds the OLD fileURL —
    /// FileEditorTabSession.fileURL is immutable, so a dirty save after
    /// this rename rewrites the file back to the path it no longer
    /// lives at.
    @discardableResult
    static func rename(_ url: URL, to newName: String) throws -> URL {
        let currentName = url.lastPathComponent
        // Same name: nothing to do — a no-op beats an opaque
        // "already exists" for the name the file already has.
        if newName == currentName { return url }
        // Case-only rename (readme.md → README.md): on the default
        // case-insensitive APFS, fileExists(newName) is true because
        // it IS this file — skip the collision check; moveItem handles
        // case-only moves natively.
        if newName.caseInsensitiveCompare(currentName) == .orderedSame {
            guard !newName.isEmpty, !newName.contains("/"),
                  newName != ".", newName != ".." else {
                throw FileTreeOperationError.invalidName(newName)
            }
            let target = url.deletingLastPathComponent().appendingPathComponent(newName)
            try FileManager.default.moveItem(at: url, to: target)
            return target
        }
        let target = try validatedTarget(
            named: newName, in: url.deletingLastPathComponent())
        try FileManager.default.moveItem(at: url, to: target)
        return target
    }

    /// Recoverable delete — the file lands in the user's Trash. No
    /// confirmation dialog by design; undo is the Trash itself.
    ///
    /// Known limitation (tracked as a follow-up, not fixed here): an
    /// open Monaco editor tab holds the OLD fileURL —
    /// FileEditorTabSession.fileURL is immutable, so a dirty save after
    /// trashing a file rewrites the path that no longer exists,
    /// silently recreating it outside the Trash.
    static func trash(_ url: URL) throws {
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }

    private static func validatedTarget(named name: String, in directory: URL) throws -> URL {
        guard !name.isEmpty, !name.contains("/"), name != ".", name != ".." else {
            throw FileTreeOperationError.invalidName(name)
        }
        let target = directory.appendingPathComponent(name)
        guard !FileManager.default.fileExists(atPath: target.path) else {
            throw FileTreeOperationError.alreadyExists(name)
        }
        return target
    }
}
