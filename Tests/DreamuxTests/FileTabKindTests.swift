import XCTest
@testable import Dreamux

final class FileTabKindTests: XCTestCase {
    func testExplicitExtensions() {
        XCTAssertEqual(FileTabKind.kind(forPathExtension: "md"), .markdown)
        XCTAssertEqual(FileTabKind.kind(forPathExtension: "MDX"), .markdown)
        XCTAssertEqual(FileTabKind.kind(forPathExtension: "csv"), .tabular)
        XCTAssertEqual(FileTabKind.kind(forPathExtension: "tsv"), .tabular)
        XCTAssertEqual(FileTabKind.kind(forPathExtension: "pdf"), .pdf)
        XCTAssertEqual(FileTabKind.kind(forPathExtension: "xlsx"), .officePreview)
        XCTAssertEqual(FileTabKind.kind(forPathExtension: "docx"), .officePreview)
        XCTAssertEqual(FileTabKind.kind(forPathExtension: "numbers"), .officePreview)
        XCTAssertEqual(FileTabKind.kind(forPathExtension: "svg"), .image)
    }

    func testUTTypeConformanceFallback() {
        XCTAssertEqual(FileTabKind.kind(forPathExtension: "png"), .image)
        XCTAssertEqual(FileTabKind.kind(forPathExtension: "heic"), .image)
        XCTAssertEqual(FileTabKind.kind(forPathExtension: "webp"), .image)
        XCTAssertEqual(FileTabKind.kind(forPathExtension: "mov"), .video)
        XCTAssertEqual(FileTabKind.kind(forPathExtension: "mp4"), .video)
        XCTAssertEqual(FileTabKind.kind(forPathExtension: "mp3"), .audio)
        XCTAssertEqual(FileTabKind.kind(forPathExtension: "wav"), .audio)
    }

    func testEverythingElseIsCode() {
        XCTAssertEqual(FileTabKind.kind(forPathExtension: "swift"), .code)
        XCTAssertEqual(FileTabKind.kind(forPathExtension: "toml"), .code)
        XCTAssertEqual(FileTabKind.kind(forPathExtension: "json"), .code)
        XCTAssertEqual(FileTabKind.kind(forPathExtension: ""), .code)
        XCTAssertEqual(FileTabKind.kind(forPathExtension: "zzznotreal"), .code)
    }

    func testMonacoBackedKinds() {
        XCTAssertTrue(FileTabKind.code.isMonacoBacked)
        XCTAssertTrue(FileTabKind.markdown.isMonacoBacked)
        XCTAssertTrue(FileTabKind.tabular.isMonacoBacked)
        XCTAssertFalse(FileTabKind.image.isMonacoBacked)
        XCTAssertFalse(FileTabKind.officePreview.isMonacoBacked)
    }
}
