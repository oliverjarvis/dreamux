import XCTest
@testable import Dreamux

final class AppletDataStoreTests: XCTestCase {
    private func makeStore() -> (AppletDataStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("appdata-\(UUID().uuidString)", isDirectory: true)
        return (AppletDataStore(dataDir: dir), dir)
    }

    func testKvRoundTrip() throws {
        let (store, dir) = makeStore(); defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertNil(store.kvGet("missing"))
        try store.kvSet("board", value: ["cols": [["name": "todo"]]])
        let value = try XCTUnwrap(store.kvGet("board") as? [String: Any])
        XCTAssertNotNil(value["cols"])
        XCTAssertEqual(store.kvList().count, 1)
        try store.kvDelete("board")
        XCTAssertNil(store.kvGet("board"))
    }

    func testFsScopingAndOps() throws {
        let (store, dir) = makeStore(); defer { try? FileManager.default.removeItem(at: dir) }
        try store.fsWrite("notes/a.txt", text: "hello")
        XCTAssertEqual(try store.fsRead("notes/a.txt"), "hello")
        XCTAssertEqual(try store.fsList("notes"), ["a.txt"])
        try store.fsDelete("notes/a.txt")
        XCTAssertThrowsError(try store.fsRead("notes/a.txt"))
        // Escapes rejected.
        XCTAssertNil(store.scopedFileURL("../kv.json"))
        XCTAssertNil(store.scopedFileURL("a/../../outside"))
        XCTAssertThrowsError(try store.fsRead("../kv.json"))
    }
}
