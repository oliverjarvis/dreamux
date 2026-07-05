import XCTest
@testable import Dreamux

/// The loop-prevention contract between the UI ring buffer and the
/// persistent bus: app-origin lines forward exactly once; hydrated and
/// external lines never forward (or external emits would bounce
/// UI→bus→UI forever and hydration would re-persist history every
/// launch).
@MainActor
final class SignalForwardingTests: XCTestCase {

    func testAppendForwardsOncePerLineWithStream() {
        let store = SignalStore()
        var forwarded: [(String, String?)] = []
        store.forward = { entry, stream in forwarded.append((entry.message, stream)) }

        store.append(source: "web", line: "hello", stream: "stdout")
        store.append(source: "web", line: "plain")

        XCTAssertEqual(forwarded.count, 2)
        XCTAssertEqual(forwarded[0].0, "hello")
        XCTAssertEqual(forwarded[0].1, "stdout")
        XCTAssertNil(forwarded[1].1, "stream is optional — events have none")
    }

    func testAppendExternalNeverForwards() {
        let store = SignalStore()
        var forwarded = 0
        store.forward = { _, _ in forwarded += 1 }

        store.appendExternal(source: "external.claude", line: "finding: X")

        XCTAssertEqual(forwarded, 0)
        XCTAssertEqual(store.entries.count, 1, "still lands in the UI ring")
        XCTAssertEqual(store.knownSources, ["external.claude"])
    }

    func testAppendChunkThreadsStream() {
        let store = SignalStore()
        var streams: [String?] = []
        store.forward = { _, stream in streams.append(stream) }
        var buffer = ""
        store.appendChunk(source: "web", "a\nb\n", buffer: &buffer, stream: "stderr")
        XCTAssertEqual(streams, ["stderr", "stderr"])
    }
}

/// The status choke point: every distinct transition fires the hook,
/// idempotent writes stay silent — service.health must not spam on
/// every poll or repeated stop.
@MainActor
final class RunnerStatusHookTests: XCTestCase {
    func testStatusHookFiresOnTransitionOnly() throws {
        let sandbox = try TestSandbox()
        defer { sandbox.destroy() }
        let project = try sandbox.makeProject(named: "hook-proj")
        let manager = RunnerManager(project: project, signals: SignalStore())

        var events: [(String, String, RunnerStatus?, RunnerStatus)] = []
        manager.statusChanged = { events.append(($0, $1, $2, $3)) }

        // start() against a cwd that doesn't exist: Process.run() throws,
        // and the manager records .failed — one transition, from nil.
        // Mirrors RunnerManagerLogicTests.testReloadDropsStatusForRemovedRunners's
        // bad-cwd arrangement (direct start(), no reload needed).
        let ghost = ParsedRunner(name: "ghost", cwd: "repos/ghost/main", start: "echo boo")
        manager.start(ghost)

        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].0, "ghost")
        XCTAssertNil(events[0].2)
        if case .failed = events[0].3 {} else {
            XCTFail("expected .failed, got \(events[0].3)")
        }
    }
}
