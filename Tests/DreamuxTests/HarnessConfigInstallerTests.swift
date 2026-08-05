import XCTest
@testable import Dreamux

final class HarnessConfigInstallerTests: XCTestCase {
    var sandbox: TestSandbox!
    var configURL: URL!

    override func setUpWithError() throws {
        sandbox = try TestSandbox()
        configURL = sandbox.root.appendingPathComponent("hooks.json")
    }
    override func tearDown() { sandbox.destroy(); sandbox = nil }

    private let installer = HarnessConfigInstaller()
    private let hookCommand = "/Apps/Dreamux.app/Contents/Resources/bin/dreamux-hook event --harness cursor"

    private func json() throws -> [String: Any] {
        try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: configURL)) as? [String: Any]
        )
    }

    func testInstallCreatesTheFileWhenAbsent() throws {
        try installer.install(harnessID: "cursor", configURL: configURL, hookCommand: hookCommand)
        XCTAssertTrue(installer.isInstalled(harnessID: "cursor", configURL: configURL))
        let hooks = try XCTUnwrap(json()["hooks"] as? [String: Any])
        XCTAssertNotNil(hooks["beforeShellExecution"])
    }

    func testInstallPreservesForeignKeys() throws {
        try JSONSerialization.data(withJSONObject: [
            "version": 1,
            "hooks": ["afterEdit": [["command": "someone-elses-tool"]]],
            "unrelated": ["keep": "me"],
        ]).write(to: configURL)

        try installer.install(harnessID: "cursor", configURL: configURL, hookCommand: hookCommand)

        let root = try json()
        XCTAssertEqual(root["version"] as? Int, 1)
        XCTAssertNotNil(root["unrelated"])
        let hooks = try XCTUnwrap(root["hooks"] as? [String: Any])
        XCTAssertNotNil(hooks["afterEdit"], "a third-party hook must survive our install")
    }

    func testInstallIsIdempotent() throws {
        try installer.install(harnessID: "cursor", configURL: configURL, hookCommand: hookCommand)
        let first = try Data(contentsOf: configURL)
        try installer.install(harnessID: "cursor", configURL: configURL, hookCommand: hookCommand)
        XCTAssertEqual(try Data(contentsOf: configURL), first)
    }

    func testReinstallReplacesRatherThanDuplicates() throws {
        try installer.install(harnessID: "cursor", configURL: configURL, hookCommand: hookCommand)
        try installer.install(harnessID: "cursor", configURL: configURL,
                              hookCommand: hookCommand + "-v2")
        let hooks = try XCTUnwrap(json()["hooks"] as? [String: Any])
        let entries = try XCTUnwrap(hooks["beforeShellExecution"] as? [[String: Any]])
        let ours = entries.filter { ($0["dreamux"] as? Bool) == true }
        XCTAssertEqual(ours.count, 1, "re-install must replace our block, not append another")
        XCTAssertEqual(ours.first?["command"] as? String, hookCommand + "-v2")
    }

    func testUninstallRemovesOnlyOurBlock() throws {
        try JSONSerialization.data(withJSONObject: [
            "hooks": ["beforeShellExecution": [["command": "someone-elses-tool"]]],
            "unrelated": ["keep": "me"],
        ]).write(to: configURL)

        try installer.install(harnessID: "cursor", configURL: configURL, hookCommand: hookCommand)
        try installer.uninstall(harnessID: "cursor", configURL: configURL)

        XCTAssertFalse(installer.isInstalled(harnessID: "cursor", configURL: configURL))
        let hooks = try XCTUnwrap(json()["hooks"] as? [String: Any])
        let entries = try XCTUnwrap(hooks["beforeShellExecution"] as? [[String: Any]])
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?["command"] as? String, "someone-elses-tool")
        XCTAssertNotNil(try json()["unrelated"])
    }

    func testInstallBacksUpAnExistingFileOnce() throws {
        try Data(#"{"hooks":{}}"#.utf8).write(to: configURL)
        try installer.install(harnessID: "cursor", configURL: configURL, hookCommand: hookCommand)
        let backup = configURL.appendingPathExtension("dreamux.bak")
        XCTAssertEqual(String(decoding: try Data(contentsOf: backup), as: UTF8.self),
                       #"{"hooks":{}}"#)

        // A second install must not overwrite the pristine backup with
        // an already-modified file.
        try installer.install(harnessID: "cursor", configURL: configURL, hookCommand: hookCommand)
        XCTAssertEqual(String(decoding: try Data(contentsOf: backup), as: UTF8.self),
                       #"{"hooks":{}}"#)
    }

    func testMalformedConfigIsRefusedWithoutMutation() throws {
        try Data("{ this is not json".utf8).write(to: configURL)
        XCTAssertThrowsError(
            try installer.install(harnessID: "cursor", configURL: configURL, hookCommand: hookCommand)
        ) { error in
            XCTAssertEqual(error as? HarnessConfigInstaller.InstallError, .unreadableConfig)
        }
        XCTAssertEqual(String(decoding: try Data(contentsOf: configURL), as: UTF8.self),
                       "{ this is not json")
    }

    func testUninstallOnAnAbsentFileIsNotAnError() throws {
        XCTAssertNoThrow(try installer.uninstall(harnessID: "cursor", configURL: configURL))
    }
}
