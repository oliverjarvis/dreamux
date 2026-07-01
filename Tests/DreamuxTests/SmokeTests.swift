import XCTest
@testable import Dreamux

/// Smallest possible proof that the test target links against the
/// executable target and `@testable import` resolves. If this file
/// fails to build, nothing else in the suite is trustworthy.
final class SmokeTests: XCTestCase {
    /// Exercise the hand-rolled TOML-subset parser with the exact shape
    /// the Run pane teaches Claude to write — one isolated runner (has
    /// `port_env`) and one fixed-port runner (doesn't).
    func testParseAllReadsTwoRunners() {
        let toml = """
        # written by fake-claude during detect

        [[runners]]
        name = "portenv-server"
        cwd = "repos/portenv-server/main"
        start = "python3 server.py"
        stop = "pkill -f 'python3 server.py'"
        port = 4600
        port_env = "PORTENV_SERVER_PORT"

        [[runners]]
        name = "fixedport-server"
        cwd = "repos/fixedport-server/main"
        start = "python3 server.py"
        stop = "pkill -f 'python3 server.py'"
        port = 4700
        """

        let runners = ParsedRunner.parseAll(toml)
        XCTAssertEqual(runners.count, 2)

        XCTAssertEqual(runners[0].name, "portenv-server")
        XCTAssertEqual(runners[0].cwd, "repos/portenv-server/main")
        XCTAssertEqual(runners[0].start, "python3 server.py")
        XCTAssertEqual(runners[0].stop, "pkill -f 'python3 server.py'")
        XCTAssertEqual(runners[0].port, 4600)
        XCTAssertEqual(runners[0].portEnv, "PORTENV_SERVER_PORT")

        XCTAssertEqual(runners[1].name, "fixedport-server")
        XCTAssertEqual(runners[1].port, 4700)
        XCTAssertNil(runners[1].portEnv)
    }
}
