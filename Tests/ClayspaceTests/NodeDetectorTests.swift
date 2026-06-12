import XCTest
@testable import Clayspace

final class NodeDetectorTests: XCTestCase {
    private var sandboxDir: URL!

    override func setUp() async throws {
        sandboxDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("node-detector-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sandboxDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: sandboxDir)
        super.tearDown()
    }

    /// Write an executable fake `node` into a fresh dir; `script` is the
    /// shell body (e.g. `echo v24.0.0` or `exit 1` for a broken shim).
    private func makeNodeDir(_ name: String, script: String) throws -> String {
        let dir = sandboxDir.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let node = dir.appendingPathComponent("node")
        try "#!/bin/sh\n\(script)\n".write(to: node, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: node.path)
        return dir.path
    }

    func testSkipsBrokenShimAndPicksWorkingNode() async throws {
        // The asdf failure mode: shim exists and is executable but dies.
        let broken = try makeNodeDir("shims", script: "echo 'No version is set' >&2; exit 1")
        let working = try makeNodeDir("real", script: "echo v24.13.0")

        let resolution = await NodeDetector.detect(candidates: [broken, working])
        XCTAssertEqual(resolution?.binDirectory, working)
        XCTAssertEqual(resolution?.version, "v24.13.0")
    }

    func testNoWorkingNodeReturnsNil() async throws {
        let broken = try makeNodeDir("shims", script: "exit 1")
        let resolution = await NodeDetector.detect(candidates: [broken, "/nonexistent/dir"])
        XCTAssertNil(resolution)
    }

    func testDefaultCandidatesIncludeWellKnownLocations() async {
        let candidates = await NodeDetector.defaultCandidates()
        XCTAssertTrue(candidates.contains("/opt/homebrew/bin"))
        XCTAssertTrue(candidates.contains("/usr/local/bin"))
    }
}
