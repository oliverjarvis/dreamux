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

    /// trashItem is recoverable-by-design; the test only asserts the
    /// file left its original location (the Trash's location is the
    /// OS's business).
    func testTrashRemovesFromOriginalLocation() throws {
        let file = try FileTreeOperations.createFile(named: "bye.txt", in: dir)
        try FileTreeOperations.trash(file)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }
}
