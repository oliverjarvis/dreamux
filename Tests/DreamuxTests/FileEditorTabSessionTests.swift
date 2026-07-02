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
}
