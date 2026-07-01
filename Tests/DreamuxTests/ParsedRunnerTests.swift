import XCTest
@testable import Dreamux

/// Must-parse corpus for `ParsedRunner.parseAll`, the hand-rolled
/// TOML-subset reader behind run.toml. Each case lives as a real .toml
/// file under `Tests/DreamuxTests/Fixtures/toml/` so the bytes the
/// parser sees are exactly the bytes on disk — important for the CRLF
/// and no-trailing-newline cases, which a Swift string literal would
/// quietly normalise.
///
/// Fixtures are loaded `#filePath`-relative (same trick as
/// `RepoFixtures`) rather than as SwiftPM resources: tests always run
/// from a checkout, and this avoids coupling fixture loading to
/// `Bundle.module` plumbing. Package.swift just `exclude`s the
/// directory so SwiftPM doesn't warn about unhandled files.
final class ParsedRunnerTests: XCTestCase {
    /// Read `Tests/DreamuxTests/Fixtures/toml/<name>` verbatim.
    private func fixture(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()           // .../Tests/DreamuxTests
            .appendingPathComponent("Fixtures/toml", isDirectory: true)
            .appendingPathComponent(name)
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func parse(_ name: String) throws -> [ParsedRunner] {
        try ParsedRunner.parseAll(fixture(name))
    }

    // MARK: - Happy paths

    /// The exact two-runner shape the detect prompt instructs Claude to
    /// write (RunSetupView.detectPrompt). If this stops round-tripping,
    /// Detect is broken for everyone.
    func testCanonicalDetectOutput() throws {
        let runners = try parse("canonical-detect.toml")
        XCTAssertEqual(
            runners,
            [
                ParsedRunner(
                    name: "frontend",
                    cwd: "repos/frontend/main",
                    start: "npm run dev",
                    stop: "pkill -f 'node.*dev'",
                    port: 3000,
                    portEnv: nil
                ),
                ParsedRunner(
                    name: "api",
                    cwd: "repos/api/main",
                    start: "cargo run",
                    stop: "pkill -f 'cargo run'",
                    port: 8080,
                    portEnv: nil
                ),
            ]
        )
    }

    /// The post-isolate shape: identical to detect output plus a
    /// `port_env` line appended by the isolate flow.
    func testPortEnvRunner() throws {
        let runners = try parse("port-env.toml")
        XCTAssertEqual(
            runners,
            [
                ParsedRunner(
                    name: "portenv-server",
                    cwd: "repos/portenv-server/main",
                    start: "python3 server.py",
                    stop: "pkill -f 'python3 server.py'",
                    port: 4600,
                    portEnv: "PORTENV_SERVER_PORT"
                ),
            ]
        )
    }

    // MARK: - Noise tolerance

    /// Comments, blank lines, and stray prose (with and without '=')
    /// interleaved through a block must all be skipped — the parser's
    /// whole reason for being lenient is that Claude sometimes leaves
    /// commentary in the file despite being told not to.
    func testCommentsBlankLinesAndProseAreSkipped() throws {
        let runners = try parse("comments-prose.toml")
        XCTAssertEqual(
            runners,
            [
                ParsedRunner(
                    name: "web",
                    cwd: "repos/web/main",
                    start: "npm run dev",
                    stop: nil,
                    port: 4610,
                    portEnv: nil
                ),
            ]
        )
    }

    /// Both quote styles strip only the OUTER quotes; '=' and '#'
    /// inside the quotes are payload, not syntax.
    func testQuotingPreservesEqualsAndHashInsideValues() throws {
        let runners = try parse("quoting.toml")
        XCTAssertEqual(runners.count, 2)

        let single = runners[0]
        XCTAssertEqual(single.name, "single")
        XCTAssertEqual(single.cwd, "repos/single/main")
        XCTAssertEqual(single.start, "FOO=bar PORT=4620 npm start")
        XCTAssertEqual(single.stop, "pkill -f 'npm #dev'")

        let double = runners[1]
        XCTAssertEqual(double.name, "double")
        XCTAssertEqual(double.start, "echo a=b # not a comment")
    }

    /// Unknown keys are silently ignored; the known keys around them
    /// still land.
    func testUnknownKeysIgnored() throws {
        let runners = try parse("unknown-keys.toml")
        XCTAssertEqual(
            runners,
            [
                ParsedRunner(
                    name: "extras",
                    cwd: nil,
                    start: "echo run",
                    stop: nil,
                    port: 4660,
                    portEnv: nil
                ),
            ]
        )
    }

    // MARK: - Missing / malformed keys

    /// Optional keys (cwd/stop/port/port_env) absent → nil. Required
    /// keys (name/start) absent or empty → that block is dropped while
    /// its neighbours survive intact.
    func testMissingKeys() throws {
        let runners = try parse("missing-keys.toml")
        XCTAssertEqual(runners.map(\.name), ["no-extras", "survivor"])

        let bare = runners[0]
        XCTAssertEqual(bare.start, "make run")
        XCTAssertNil(bare.cwd)
        XCTAssertNil(bare.stop)
        XCTAssertNil(bare.port)
        XCTAssertNil(bare.portEnv)
    }

    /// Duplicate key inside one block: the parser has no dup detection
    /// (real TOML would error), so assignment order means the LAST
    /// occurrence wins. Pinned deliberately — if someone adds first-wins
    /// or rejection semantics, this test should force a conscious look.
    func testDuplicateKeyLastWins() throws {
        let runners = try parse("duplicate-keys.toml")
        XCTAssertEqual(runners.count, 1)
        XCTAssertEqual(runners[0].name, "second")
        XCTAssertEqual(runners[0].start, "echo two")
        XCTAssertEqual(runners[0].port, 4631)
    }

    /// The `open` key rides along verbatim — `{port}` stays a literal
    /// placeholder at parse time (RunnerManager substitutes the
    /// instance's effective port when it fires the open).
    func testOpenKeyParsesVerbatim() throws {
        let raw = """
        [[runners]]
        name = "webapp"
        start = "npm run dev"
        port = 4634
        open = "http://localhost:{port}/dashboard"

        [[runners]]
        name = "headless"
        start = "echo worker"
        """
        let runners = ParsedRunner.parseAll(raw)
        XCTAssertEqual(runners[0].open, "http://localhost:{port}/dashboard")
        XCTAssertNil(runners[1].open, "open is optional and defaults to nil")
    }

    /// Two `[[runners]]` blocks with the same name collapse to the
    /// last one, in first-seen order. `ParsedRunner.id` is the name, so
    /// duplicates would double rows in every ForEach and double-start
    /// on play — and they're a plausible Claude-detect artifact, not a
    /// hypothetical.
    func testDuplicateRunnerNamesKeepLastDefinition() throws {
        let raw = """
        [[runners]]
        name = "webapp"
        start = "echo old"
        port = 4632

        [[runners]]
        name = "other"
        start = "echo other"

        [[runners]]
        name = "webapp"
        start = "echo new"
        port = 4633
        """
        let runners = ParsedRunner.parseAll(raw)
        XCTAssertEqual(runners.map(\.name), ["webapp", "other"], "first-seen order, no duplicates")
        XCTAssertEqual(runners[0].start, "echo new", "last definition wins")
        XCTAssertEqual(runners[0].port, 4633)
    }

    /// A port value `Int()` can't parse leaves `port` nil but keeps the
    /// runner. Includes the inline-comment quirk: the parser never
    /// strips trailing comments, so `port = 4650 # note` is "4650 #
    /// note" to Int() and also comes back nil. Documented behaviour —
    /// fixing it would mean teaching the parser comment-stripping.
    func testNonIntegerPortParsesRunnerWithNilPort() throws {
        let runners = try parse("bad-port.toml")
        XCTAssertEqual(runners.map(\.name), ["bad-port", "comment-port"])
        XCTAssertNil(runners[0].port)
        XCTAssertNil(runners[1].port, "inline comments after port are not stripped; Int() fails")
    }

    // MARK: - Line-ending and whitespace robustness

    /// CRLF endings (Claude on odd toolchains, or a user editing in a
    /// Windows-leaning editor), tab/space padding around keys, values,
    /// and the [[runners]] header itself, and no trailing newline on
    /// the final line — all must parse as if the file were pristine.
    func testCRLFWhitespaceAndNoTrailingNewline() throws {
        // Guard the fixture itself: if some tool "helpfully" normalises
        // its line endings, the test would silently stop covering CRLF.
        let raw = try fixture("crlf.toml")
        XCTAssertTrue(raw.contains("\r\n"), "fixture lost its CRLF endings")
        XCTAssertFalse(raw.hasSuffix("\n"), "fixture grew a trailing newline")

        let runners = ParsedRunner.parseAll(raw)
        XCTAssertEqual(
            runners,
            [
                ParsedRunner(
                    name: "crlf",
                    cwd: nil,
                    start: "echo crlf",
                    stop: nil,
                    port: 4640,
                    portEnv: nil
                ),
            ]
        )
    }

    // MARK: - Degenerate inputs

    func testEmptyFileYieldsNoRunners() throws {
        XCTAssertEqual(try parse("empty.toml"), [])
    }

    func testCommentsOnlyFileYieldsNoRunners() throws {
        XCTAssertEqual(try parse("comments-only.toml"), [])
    }
}
