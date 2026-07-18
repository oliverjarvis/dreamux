import XCTest
@testable import Dreamux

/// Glue check for the fixtures the e2e suites build on: prove that the
/// fake `claude` shim's detect mode, run against real bare-layout repos
/// made by `GitFixtures`, writes a run.toml that the app's own parser
/// accepts. If this fails, every later e2e test is chasing ghosts.
final class FakeClaudeDetectTests: XCTestCase {
    private var sandbox: TestSandbox!

    override func setUpWithError() throws {
        sandbox = try TestSandbox()
    }

    override func tearDown() {
        sandbox?.destroy()
        sandbox = nil
        super.tearDown()
    }

    func testDetectWritesRunTOMLThatParsedRunnerAccepts() async throws {
        let project = try sandbox.makeProject(named: "demo")

        // Commit copies of both sample apps into the Dreamux
        // repos/<name>/{.bare,main} layout — same shape the app builds.
        for app in ["portenv-server", "fixedport-server"] {
            try await GitFixtures.makeBareLayoutRepo(
                in: project.rootPath,
                name: app,
                files: RepoFixtures.sampleAppFiles(app)
            )
        }

        // The shim keys off this phrase (see RunConfigCard.detectPrompt);
        // the rest of the real prompt is irrelevant to it.
        let result = try await runProcess(
            RepoFixtures.fakeClaude,
            arguments: ["Inspect every repo under ./repos/* and write .dreamux/run.toml"],
            cwd: project.rootPath
        )
        XCTAssertEqual(result.status, 0, "fake claude failed: \(result.output)")
        XCTAssertTrue(result.output.contains("run.toml ready"))

        let tomlURL = project.rootPath
            .appendingPathComponent(".dreamux/run.toml")
        let toml = try String(contentsOf: tomlURL, encoding: .utf8)
        let runners = ParsedRunner.parseAll(toml)

        // Repos are concatenated in sorted order, so fixedport first.
        XCTAssertEqual(runners.map(\.name), ["fixedport-server", "portenv-server"])

        let fixed = runners[0]
        XCTAssertEqual(fixed.cwd, "repos/fixedport-server/main")
        // The fixtures anchor start/stop on the worktree's absolute
        // path ($PWD) so the stop pkill can never reach processes
        // outside the sandbox; the parser must hand the single-quoted
        // TOML values through verbatim for that contract to hold.
        XCTAssertEqual(fixed.start, "python3 \"$PWD/server.py\"")
        XCTAssertEqual(fixed.stop, "pkill -f \"$PWD/server.py\"")
        XCTAssertEqual(fixed.port, 4700)
        XCTAssertNil(fixed.portEnv, "fixedport fixture must not ship a port_env")

        let portenv = runners[1]
        XCTAssertEqual(portenv.cwd, "repos/portenv-server/main")
        XCTAssertEqual(portenv.port, 4600)
        XCTAssertEqual(portenv.portEnv, "PORTENV_SERVER_PORT")
    }

    /// Minimal async subprocess runner. Everything process-related is
    /// created inside the dispatched closure (same pattern as
    /// `GitOperations.runGit`) so no non-Sendable state crosses the
    /// continuation boundary under strict concurrency.
    private func runProcess(
        _ executable: URL,
        arguments: [String],
        cwd: URL
    ) async throws -> (status: Int32, output: String) {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = executable
                process.arguments = arguments
                process.currentDirectoryURL = cwd

                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe

                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                continuation.resume(returning: (
                    status: process.terminationStatus,
                    output: String(data: data, encoding: .utf8) ?? ""
                ))
            }
        }
    }
}
