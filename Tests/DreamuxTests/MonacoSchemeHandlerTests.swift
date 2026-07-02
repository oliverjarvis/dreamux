import XCTest
@testable import Dreamux

final class MonacoSchemeHandlerTests: XCTestCase {
    func testRelativePathStripsHostAndLeadingSlash() {
        XCTAssertEqual(
            MonacoSchemeHandler.relativePath(for: URL(string: "app-monaco://app/vs/loader.js")!),
            "vs/loader.js"
        )
    }

    func testRelativePathDefaultsToIndex() {
        XCTAssertEqual(
            MonacoSchemeHandler.relativePath(for: URL(string: "app-monaco://app")!),
            "index.html"
        )
    }

    func testRelativePathRejectsForeignScheme() {
        XCTAssertNil(MonacoSchemeHandler.relativePath(for: URL(string: "https://example.com/x")!))
    }

    func testMimeTypes() {
        XCTAssertEqual(MonacoSchemeHandler.mimeType(forPathExtension: "js"), "text/javascript")
        XCTAssertEqual(MonacoSchemeHandler.mimeType(forPathExtension: "CSS"), "text/css")
        XCTAssertEqual(MonacoSchemeHandler.mimeType(forPathExtension: "ttf"), "font/ttf")
        XCTAssertEqual(MonacoSchemeHandler.mimeType(forPathExtension: "xyz"), "application/octet-stream")
    }

    func testVendoredAssetsArePresentInBundle() {
        let root = MonacoSchemeHandler.bundledRoot
        let fm = FileManager.default
        XCTAssertTrue(fm.fileExists(atPath: root.appendingPathComponent("index.html").path))
        XCTAssertTrue(fm.fileExists(atPath: root.appendingPathComponent("editor-boot.js").path))
        XCTAssertTrue(fm.fileExists(atPath: root.appendingPathComponent("vs/loader.js").path))
    }
}
