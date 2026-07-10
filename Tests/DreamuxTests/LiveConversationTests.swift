import XCTest
@testable import Dreamux

final class LiveConversationTests: XCTestCase {
    @MainActor
    func testParsesExistingContentThenTailsAppends() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("live-conv-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("t.jsonl")
        let line1 = "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"one\"}}\n"
        let line2 = "{\"type\":\"assistant\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"two\"}]}}\n"
        try line1.write(to: url, atomically: true, encoding: .utf8)

        let conv = LiveConversation(url: url)
        defer { conv.stop() }
        try await Self.eventually { conv.items.count == 1 }

        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(line2.utf8))
        try handle.close()
        try await Self.eventually { conv.items.count == 2 }
        guard case .assistantText(let text) = conv.items[1].kind else {
            return XCTFail("expected assistant text")
        }
        XCTAssertEqual(text, "two")
    }

    @MainActor
    func testRetriesUntilFileExists() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("live-conv-late-\(UUID().uuidString).jsonl")
        let conv = LiveConversation(url: url)
        defer { conv.stop() }
        XCTAssertFalse(conv.fileFound)
        try "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"late\"}}\n"
            .write(to: url, atomically: true, encoding: .utf8)
        try await Self.eventually(timeout: 3) { conv.fileFound && conv.items.count == 1 }
    }

    @MainActor
    static func eventually(timeout: TimeInterval = 2, _ cond: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !cond() {
            if Date() > deadline { return XCTFail("condition not met in \(timeout)s") }
            try await Task.sleep(nanoseconds: 30_000_000)
        }
    }
}
