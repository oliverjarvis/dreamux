import XCTest
@testable import Dreamux

final class ClaudeTranscriptTailerTests: XCTestCase {
    var sandbox: TestSandbox!

    override func setUpWithError() throws { sandbox = try TestSandbox() }
    override func tearDown() { sandbox.destroy(); sandbox = nil }

    /// Appends `s` to the file at `url` (creating it first if needed),
    /// seeking to end so repeated calls accumulate content the way a
    /// real append-only transcript file grows.
    private func append(_ s: String, to url: URL) throws {
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        handle.write(s.data(using: .utf8)!)
    }

    func testReplayExistingReadsFromZero() throws {
        let url = sandbox.root.appendingPathComponent("transcript.jsonl")
        try append("line1\n", to: url)
        try append("line2\n", to: url)
        try append("line3\n", to: url)

        var received: [String] = []
        let lock = NSLock()
        let exp = expectation(description: "replay delivers 3 lines")
        let queue = DispatchQueue(label: "test.tailer.delivery.replay")
        let tailer = ClaudeTranscriptTailer(url: url, deliveryQueue: queue) { lines in
            lock.lock()
            received.append(contentsOf: lines)
            let count = received.count
            lock.unlock()
            if count >= 3 { exp.fulfill() }
        }
        tailer.start(replayExisting: true)
        defer { tailer.stop() }

        wait(for: [exp], timeout: 2)
        lock.lock()
        XCTAssertEqual(received, ["line1", "line2", "line3"])
        lock.unlock()
    }

    func testSeekToEOFSkipsExisting() throws {
        let url = sandbox.root.appendingPathComponent("transcript.jsonl")
        try append("line1\n", to: url)
        try append("line2\n", to: url)
        try append("line3\n", to: url)

        var received: [String] = []
        let lock = NSLock()
        let exp = expectation(description: "only the 2 appended lines arrive")
        let queue = DispatchQueue(label: "test.tailer.delivery.eof")
        let tailer = ClaudeTranscriptTailer(url: url, deliveryQueue: queue) { lines in
            lock.lock()
            received.append(contentsOf: lines)
            let count = received.count
            lock.unlock()
            if count >= 2 { exp.fulfill() }
        }
        tailer.start(replayExisting: false)
        defer { tailer.stop() }

        try append("line4\n", to: url)
        try append("line5\n", to: url)

        wait(for: [exp], timeout: 2)
        lock.lock()
        XCTAssertEqual(received, ["line4", "line5"])
        lock.unlock()
    }

    func testPartialLineBufferedUntilNewline() throws {
        let url = sandbox.root.appendingPathComponent("transcript.jsonl")
        FileManager.default.createFile(atPath: url.path, contents: nil)

        var received: [String] = []
        let lock = NSLock()
        var onDeliver: (() -> Void)?
        let queue = DispatchQueue(label: "test.tailer.delivery.partial")
        let tailer = ClaudeTranscriptTailer(url: url, deliveryQueue: queue) { lines in
            lock.lock()
            received.append(contentsOf: lines)
            lock.unlock()
            onDeliver?()
        }
        tailer.start(replayExisting: false)
        defer { tailer.stop() }

        // A bare partial line (no trailing newline) must not be delivered.
        let nothingYet = expectation(description: "nothing delivered for bare partial line")
        nothingYet.isInverted = true
        onDeliver = { nothingYet.fulfill() }
        try append("half", to: url)
        wait(for: [nothingYet], timeout: 0.5)
        lock.lock()
        XCTAssertTrue(received.isEmpty)
        lock.unlock()

        // Completing the line and adding another assembles both correctly.
        let linesArrived = expectation(description: "assembled lines arrive")
        onDeliver = {
            lock.lock()
            let count = received.count
            lock.unlock()
            if count >= 2 { linesArrived.fulfill() }
        }
        try append("-rest\nnext\n", to: url)
        wait(for: [linesArrived], timeout: 2)

        lock.lock()
        XCTAssertEqual(received, ["half-rest", "next"])
        lock.unlock()
    }

    func testTruncationResetsOffset() throws {
        let url = sandbox.root.appendingPathComponent("transcript.jsonl")
        try append("line1\n", to: url)
        try append("line2\n", to: url)
        try append("line3\n", to: url)

        var received: [String] = []
        let lock = NSLock()
        var onDeliver: (() -> Void)?
        let queue = DispatchQueue(label: "test.tailer.delivery.truncate")
        let tailer = ClaudeTranscriptTailer(url: url, deliveryQueue: queue) { lines in
            lock.lock()
            received.append(contentsOf: lines)
            lock.unlock()
            onDeliver?()
        }

        let firstThree = expectation(description: "initial 3 lines")
        onDeliver = {
            lock.lock()
            let count = received.count
            lock.unlock()
            if count >= 3 { firstThree.fulfill() }
        }
        tailer.start(replayExisting: true)
        defer { tailer.stop() }
        wait(for: [firstThree], timeout: 2)

        lock.lock()
        XCTAssertEqual(received, ["line1", "line2", "line3"])
        received.removeAll()
        lock.unlock()

        let afterTruncate = expectation(description: "post-truncation line arrives")
        onDeliver = {
            lock.lock()
            let count = received.count
            lock.unlock()
            if count >= 1 { afterTruncate.fulfill() }
        }

        let handle = try FileHandle(forWritingTo: url)
        handle.truncateFile(atOffset: 0)
        handle.write("newline\n".data(using: .utf8)!)
        try handle.close()

        wait(for: [afterTruncate], timeout: 2)
        lock.lock()
        XCTAssertEqual(received, ["newline"])
        lock.unlock()
    }

    func testStopIsIdempotentAndStopsDelivery() throws {
        let url = sandbox.root.appendingPathComponent("transcript.jsonl")
        try append("line1\n", to: url)

        var received: [String] = []
        let lock = NSLock()
        var onDeliver: (() -> Void)?
        let queue = DispatchQueue(label: "test.tailer.delivery.stop")
        let tailer = ClaudeTranscriptTailer(url: url, deliveryQueue: queue) { lines in
            lock.lock()
            received.append(contentsOf: lines)
            lock.unlock()
            onDeliver?()
        }

        let gotFirst = expectation(description: "initial line arrives")
        onDeliver = {
            lock.lock()
            let count = received.count
            lock.unlock()
            if count >= 1 { gotFirst.fulfill() }
        }
        tailer.start(replayExisting: true)
        wait(for: [gotFirst], timeout: 2)

        tailer.stop()

        let noMore = expectation(description: "nothing delivered after stop")
        noMore.isInverted = true
        onDeliver = { noMore.fulfill() }
        try append("line2\n", to: url)
        wait(for: [noMore], timeout: 0.5)

        lock.lock()
        XCTAssertEqual(received, ["line1"])
        lock.unlock()

        tailer.stop() // idempotent; must not crash
    }

    /// `resume()` is the pool's re-entry lever for a session that left
    /// and later re-joined the hot set: unlike `start()`, it must not
    /// reset to zero/EOF — it continues from the offset `stop()` froze,
    /// so nothing written during the gap is lost or re-delivered.
    func testResumeContinuesFromStoredOffsetAfterStop() throws {
        let url = sandbox.root.appendingPathComponent("transcript.jsonl")
        try append("line1\n", to: url)
        try append("line2\n", to: url)

        var received: [String] = []
        let lock = NSLock()
        var onDeliver: (() -> Void)?
        let queue = DispatchQueue(label: "test.tailer.delivery.resume")
        let tailer = ClaudeTranscriptTailer(url: url, deliveryQueue: queue) { lines in
            lock.lock()
            received.append(contentsOf: lines)
            lock.unlock()
            onDeliver?()
        }

        let gotFirstTwo = expectation(description: "initial 2 lines")
        onDeliver = {
            lock.lock()
            let count = received.count
            lock.unlock()
            if count >= 2 { gotFirstTwo.fulfill() }
        }
        tailer.start(replayExisting: true)
        wait(for: [gotFirstTwo], timeout: 2)
        tailer.stop()

        // Written entirely while stopped — must not be missed, and
        // must not be duplicated against the pre-stop lines either.
        try append("line3\n", to: url)

        lock.lock()
        received.removeAll()
        lock.unlock()

        let afterResume = expectation(description: "gap line arrives via resume")
        onDeliver = {
            lock.lock()
            let count = received.count
            lock.unlock()
            if count >= 1 { afterResume.fulfill() }
        }
        tailer.resume()

        wait(for: [afterResume], timeout: 2)
        lock.lock()
        XCTAssertEqual(received, ["line3"])
        lock.unlock()

        tailer.stop()
    }
}
