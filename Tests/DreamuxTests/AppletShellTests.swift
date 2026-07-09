import XCTest
@testable import Dreamux

final class AppletShellTests: XCTestCase {
    func testExecCapturesOutputAndExitCode() async {
        let cwd = FileManager.default.temporaryDirectory
        let ok = await AppletShell.exec(cmd: "echo hi; echo err 1>&2", cwd: cwd, timeout: 10)
        XCTAssertEqual(ok.stdout, "hi\n")
        XCTAssertEqual(ok.stderr, "err\n")
        XCTAssertEqual(ok.code, 0)
        let fail = await AppletShell.exec(cmd: "exit 3", cwd: cwd, timeout: 10)
        XCTAssertEqual(fail.code, 3)
    }

    func testExecTimesOut() async {
        let start = Date()
        let result = await AppletShell.exec(
            cmd: "sleep 30", cwd: FileManager.default.temporaryDirectory, timeout: 1)
        XCTAssertLessThan(Date().timeIntervalSince(start), 10)
        XCTAssertNotEqual(result.code, 0)
    }

    func testExecRunsInCwd() async {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("shell-cwd-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let result = await AppletShell.exec(cmd: "pwd", cwd: dir, timeout: 10)
        XCTAssertEqual(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines),
                       dir.resolvingSymlinksInPath().path)
    }
}
