import XCTest
@testable import Dreamux

final class FileEditorTabSessionTests: XCTestCase {
    private var sandbox: TestSandbox!

    override func setUpWithError() throws { sandbox = try TestSandbox() }
    override func tearDown() { sandbox?.destroy(); sandbox = nil }

    func testReadTextReturnsContentsForSmallUTF8File() throws {
        let url = sandbox.root.appendingPathComponent("a.swift")
        try "let x = 1\n".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(FileEditorTabSession.readText(at: url), "let x = 1\n")
    }

    func testReadTextRejectsBinary() throws {
        let url = sandbox.root.appendingPathComponent("blob.bin")
        try Data([0xFF, 0xFE, 0x00, 0x01]).write(to: url)
        XCTAssertNil(FileEditorTabSession.readText(at: url))
    }

    func testReadTextRejectsOversized() throws {
        let url = sandbox.root.appendingPathComponent("big.txt")
        try Data(count: 3 * 1024 * 1024).write(to: url) // 3 MB > 2 MB cap
        XCTAssertNil(FileEditorTabSession.readText(at: url))
    }

    func testJsStringQuotesAndEscapes() {
        XCTAssertEqual(FileEditorTabSession.jsString("hi"), "\"hi\"")
        // A quote and newline must come back escaped inside the literal.
        let out = FileEditorTabSession.jsString("a\"b\nc")
        XCTAssertTrue(out.hasPrefix("\"") && out.hasSuffix("\""))
        XCTAssertTrue(out.contains("\\\""))
        XCTAssertTrue(out.contains("\\n"))
    }

    @MainActor
    func testSupportedFlagReflectsReadability() throws {
        let text = sandbox.root.appendingPathComponent("ok.swift")
        try "hi".write(to: text, atomically: true, encoding: .utf8)
        XCTAssertTrue(FileEditorTabSession(fileURL: text).isSupported)

        let bin = sandbox.root.appendingPathComponent("x.bin")
        try Data([0xFF, 0xFE]).write(to: bin)
        XCTAssertFalse(FileEditorTabSession(fileURL: bin).isSupported)
    }

    func testDefaultViewModes() {
        XCTAssertEqual(FileEditorTabSession.defaultViewMode(for: .markdown), .rendered)
        XCTAssertEqual(FileEditorTabSession.defaultViewMode(for: .tabular), .table)
        XCTAssertEqual(FileEditorTabSession.defaultViewMode(for: .code), .source)
        XCTAssertEqual(FileEditorTabSession.defaultViewMode(for: .image), .source)
    }

    @MainActor
    func testKindAndCurrentTextAssignedAtInit() throws {
        let url = sandbox.root.appendingPathComponent("notes.md")
        try "# hi\n".write(to: url, atomically: true, encoding: .utf8)
        let session = FileEditorTabSession(fileURL: url)
        XCTAssertEqual(session.kind, .markdown)
        XCTAssertEqual(session.viewMode, .rendered)
        XCTAssertEqual(session.currentText, "# hi\n")
        XCTAssertTrue(session.isSupported)
    }

    @MainActor
    func testMediaKindsSkipTextReadAndUseExistence() throws {
        // 3 MB of noise with a movie extension: over the text cap, but
        // media kinds never read text — existence is enough.
        let url = sandbox.root.appendingPathComponent("clip.mov")
        try Data(count: 3 * 1024 * 1024).write(to: url)
        let session = FileEditorTabSession(fileURL: url)
        XCTAssertEqual(session.kind, .video)
        XCTAssertTrue(session.isSupported)
        XCTAssertEqual(session.currentText, "")

        let missing = FileEditorTabSession(
            fileURL: sandbox.root.appendingPathComponent("gone.mov"))
        XCTAssertFalse(missing.isSupported)
    }

    @MainActor
    func testOversizedTextStillUnsupported() throws {
        let url = sandbox.root.appendingPathComponent("big.csv")
        try Data(count: 3 * 1024 * 1024).write(to: url)
        XCTAssertFalse(FileEditorTabSession(fileURL: url).isSupported)
    }
}
