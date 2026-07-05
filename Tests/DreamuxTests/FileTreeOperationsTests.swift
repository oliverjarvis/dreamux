import XCTest
@testable import Dreamux

/// The file tree's mutating verbs and its two string helpers. Paths
/// with spaces and quotes are the whole point of shell escaping —
/// those are the cases agents' repos actually contain.
final class FileTreeOperationsTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("filetree-ops-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - shellEscaped

    /// Plain, space-containing, and quote-containing paths — the
    /// single-quote escape must produce something a POSIX shell
    /// round-trips byte-for-byte.
    func testShellEscaping() {
        XCTAssertEqual(FileTreeOperations.shellEscaped("/a/b.txt"), "'/a/b.txt'")
        XCTAssertEqual(FileTreeOperations.shellEscaped("/a dir/b.txt"), "'/a dir/b.txt'")
        XCTAssertEqual(
            FileTreeOperations.shellEscaped("/it's here/x"),
            "'/it'\\''s here/x'")
    }

    // MARK: - relativePath

    func testRelativePathUnderRootAndOutside() {
        let root = URL(fileURLWithPath: "/repo/web/main")
        let nested = URL(fileURLWithPath: "/repo/web/main/src/app.ts")
        XCTAssertEqual(FileTreeOperations.relativePath(of: nested, under: root), "src/app.ts")
        let outside = URL(fileURLWithPath: "/elsewhere/x.txt")
        XCTAssertEqual(
            FileTreeOperations.relativePath(of: outside, under: root),
            "/elsewhere/x.txt",
            "not under root → absolute fallback, never a wrong relative guess")
    }

    func testRelativePathOfRootItselfIsDot() {
        let root = URL(fileURLWithPath: "/repo/web/main")
        XCTAssertEqual(FileTreeOperations.relativePath(of: root, under: root), ".")
    }

    // MARK: - create / rename / trash

    func testCreateFileAndFolderWithCollisionAndValidation() throws {
        let file = try FileTreeOperations.createFile(named: "notes.md", in: dir)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertThrowsError(try FileTreeOperations.createFile(named: "notes.md", in: dir)) {
            XCTAssertEqual($0 as? FileTreeOperationError, .alreadyExists("notes.md"))
        }
        let folder = try FileTreeOperations.createFolder(named: "sub", in: dir)
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDir)
        XCTAssertTrue(isDir.boolValue)
        XCTAssertThrowsError(try FileTreeOperations.createFile(named: "a/b", in: dir)) {
            XCTAssertEqual($0 as? FileTreeOperationError, .invalidName("a/b"))
        }
        XCTAssertThrowsError(try FileTreeOperations.createFile(named: "", in: dir)) {
            XCTAssertEqual($0 as? FileTreeOperationError, .invalidName(""))
        }
    }

    /// A vanished/nonexistent directory must throw, not hand back a URL
    /// for a file that was never actually written — the old
    /// FileManager.createFile(atPath:) call ignored its Bool return
    /// and fabricated success in exactly this case.
    func testCreateFileIntoNonexistentDirectoryThrows() {
        let ghost = dir.appendingPathComponent("does-not-exist")
        XCTAssertThrowsError(try FileTreeOperations.createFile(named: "notes.md", in: ghost))
    }

    /// A read-only directory can't accept a new file; the write must
    /// surface as a real thrown error rather than a phantom "created"
    /// URL. Permissions are restored in a defer so cleanup (which
    /// deletes `dir`) still works.
    func testCreateFileIntoReadOnlyDirectoryThrows() throws {
        let locked = dir.appendingPathComponent("locked")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: locked.path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: locked.path)
        }
        XCTAssertThrowsError(try FileTreeOperations.createFile(named: "notes.md", in: locked))
    }

    func testRenameMovesWithinDirectoryAndGuards() throws {
        let file = try FileTreeOperations.createFile(named: "old.txt", in: dir)
        let renamed = try FileTreeOperations.rename(file, to: "new.txt")
        XCTAssertEqual(renamed.lastPathComponent, "new.txt")
        XCTAssertEqual(renamed.deletingLastPathComponent().path, file.deletingLastPathComponent().path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: renamed.path))
        _ = try FileTreeOperations.createFile(named: "taken.txt", in: dir)
        XCTAssertThrowsError(try FileTreeOperations.rename(renamed, to: "taken.txt")) {
            XCTAssertEqual($0 as? FileTreeOperationError, .alreadyExists("taken.txt"))
        }
    }

    /// On the default case-insensitive APFS, fileExists("README.md")
    /// is true while renaming readme.md → README.md because it IS this
    /// file. rename must not mistake that for a collision, and the
    /// resulting directory listing must show the new casing.
    func testCaseOnlyRenameSucceedsWithNewCasing() throws {
        let file = try FileTreeOperations.createFile(named: "readme.md", in: dir)
        let renamed = try FileTreeOperations.rename(file, to: "README.md")
        XCTAssertEqual(renamed.lastPathComponent, "README.md")
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertTrue(names.contains("README.md"), "directory listing should show new casing")
    }

    /// Renaming to the exact current name is a no-op, not an opaque
    /// "already exists" for the name the file already has.
    func testSameNameRenameIsNoOp() throws {
        let file = try FileTreeOperations.createFile(named: "same.txt", in: dir)
        let result = try FileTreeOperations.rename(file, to: "same.txt")
        XCTAssertEqual(result, file)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    /// trashItem is recoverable-by-design; the test only asserts the
    /// file left its original location (the Trash's location is the
    /// OS's business).
    func testTrashRemovesFromOriginalLocation() throws {
        let file = try FileTreeOperations.createFile(named: "bye.txt", in: dir)
        try FileTreeOperations.trash(file)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }
}
