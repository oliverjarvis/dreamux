import XCTest
@testable import Dreamux

final class CLICredentialImporterTests: XCTestCase {
    func testGhDraft() {
        let d = CLICredentialImporter.draft(provider: "gh", token: "ghp_abc")!
        XCTAssertEqual(d.token, "ghp_abc")
        XCTAssertEqual(d.hosts, ["api.github.com"])
        XCTAssertEqual(d.preferredID, "github")
        if case .header(let name, let tmpl) = d.kind {
            XCTAssertEqual(name, "Authorization"); XCTAssertEqual(tmpl, "Bearer {token}")
        } else { XCTFail("expected header kind") }
        if case .importedFromCLI(let tool) = d.source { XCTAssertEqual(tool, "gh") }
        else { XCTFail("expected importedFromCLI") }
    }

    func testExpoDraftAndStateParse() {
        let d = CLICredentialImporter.draft(provider: "expo", token: "expo_xyz")!
        XCTAssertEqual(d.hosts, ["api.expo.dev"])
        XCTAssertEqual(d.preferredID, "expo")
        XCTAssertEqual(CLICredentialImporter.parseExpoStateJSON(
            #"{"auth":{"sessionSecret":"expo_xyz"}}"#), "expo_xyz")
        XCTAssertNil(CLICredentialImporter.parseExpoStateJSON(#"{"auth":{}}"#))
    }

    func testGhTokenParse() {
        XCTAssertEqual(CLICredentialImporter.parseToken(provider: "gh",
            cliOutput: "gho_TOKEN123\n"), "gho_TOKEN123")
        XCTAssertNil(CLICredentialImporter.parseToken(provider: "gh", cliOutput: "\n"))
    }

    func testUnknownProvider() {
        XCTAssertNil(CLICredentialImporter.draft(provider: "nope", token: "t"))
    }
}
