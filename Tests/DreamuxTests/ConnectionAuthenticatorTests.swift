import XCTest
@testable import Dreamux

final class ConnectionAuthenticatorTests: XCTestCase {
    private let hosts = ["api.github.com"]

    func testExactHostMatchOnly() {
        XCTAssertTrue(ConnectionAuthenticator.hostAllowed(
            URL(string: "https://api.github.com/x")!, hosts: hosts))
        XCTAssertTrue(ConnectionAuthenticator.hostAllowed(   // case-insensitive
            URL(string: "https://API.GitHub.com/x")!, hosts: hosts))
        for bad in ["https://api.github.com.evil.com/x",
                    "https://evil.com/api.github.com",
                    "https://xapi.github.com/x",
                    "https://api.github.com.evil.com",
                    "https://140.82.113.3/x"] {
            XCTAssertFalse(ConnectionAuthenticator.hostAllowed(
                URL(string: bad)!, hosts: hosts), "should reject \(bad)")
        }
    }

    func testHTTPSOnly() {
        XCTAssertThrowsError(try ConnectionAuthenticator.authorize(
            URLRequest(url: URL(string: "http://api.github.com/x")!),
            url: URL(string: "http://api.github.com/x")!,
            kind: .header(headerName: "Authorization", valueTemplate: "Bearer {token}"),
            token: "T", hosts: hosts)) { XCTAssertEqual($0 as? ConnectionAuthError, .notHTTPS) }
    }

    func testHostRejectedGetsNoHeader() {
        XCTAssertThrowsError(try ConnectionAuthenticator.authorize(
            URLRequest(url: URL(string: "https://evil.com/x")!),
            url: URL(string: "https://evil.com/x")!,
            kind: .header(headerName: "Authorization", valueTemplate: "Bearer {token}"),
            token: "T", hosts: hosts)) {
            XCTAssertEqual($0 as? ConnectionAuthError, .hostNotAllowed("evil.com"))
        }
    }

    func testEachKindApplies() throws {
        let url = URL(string: "https://api.github.com/x")!
        let header = try ConnectionAuthenticator.authorize(URLRequest(url: url), url: url,
            kind: .header(headerName: "Authorization", valueTemplate: "token {token}"),
            token: "SEKRET", hosts: hosts)
        XCTAssertEqual(header.value(forHTTPHeaderField: "Authorization"), "token SEKRET")

        let basic = try ConnectionAuthenticator.authorize(URLRequest(url: url), url: url,
            kind: .basic(username: "me"), token: "pw", hosts: hosts)
        XCTAssertEqual(basic.value(forHTTPHeaderField: "Authorization"),
            "Basic " + Data("me:pw".utf8).base64EncodedString())

        let query = try ConnectionAuthenticator.authorize(URLRequest(url: url), url: url,
            kind: .query(param: "api_key"), token: "K", hosts: hosts)
        XCTAssertTrue(query.url!.query!.contains("api_key=K"))
        XCTAssertFalse(query.url!.path.contains("K"))   // token not in path
    }

    func testKindContextMismatches() {
        let url = URL(string: "https://api.github.com/x")!
        XCTAssertThrowsError(try ConnectionAuthenticator.authorize(URLRequest(url: url), url: url,
            kind: .env(vars: ["X"]), token: "T", hosts: hosts)) {
            XCTAssertEqual($0 as? ConnectionAuthError, .wrongKindForHTTP)
        }
        XCTAssertThrowsError(try ConnectionAuthenticator.env(
            for: .header(headerName: "A", valueTemplate: "{token}"), token: "T")) {
            XCTAssertEqual($0 as? ConnectionAuthError, .wrongKindForShell)
        }
        XCTAssertEqual(try ConnectionAuthenticator.env(for: .env(vars: ["GH_TOKEN"]), token: "T"),
                       ["GH_TOKEN": "T"])
    }

    func testCredentialNeverAttachedToADivergentRequestURL() throws {
        let divergent = try ConnectionAuthenticator.authorize(
            URLRequest(url: URL(string: "https://evil.com/x")!),
            url: URL(string: "https://api.github.com/x")!,
            kind: .header(headerName: "Authorization", valueTemplate: "Bearer {token}"),
            token: "T", hosts: hosts)
        XCTAssertEqual(divergent.url!.host, "api.github.com")   // evil url can't survive
        XCTAssertEqual(divergent.value(forHTTPHeaderField: "Authorization"), "Bearer T")
    }

    func testHeaderTemplateWithoutPlaceholderThrows() {
        let url = URL(string: "https://api.github.com/x")!
        XCTAssertThrowsError(try ConnectionAuthenticator.authorize(URLRequest(url: url), url: url,
            kind: .header(headerName: "Authorization", valueTemplate: "Bearer no-placeholder"),
            token: "T", hosts: hosts)) {
            XCTAssertEqual($0 as? ConnectionAuthError, .templateMissingPlaceholder)
        }
    }

    func testEnvToleratesDuplicateVarNames() throws {
        XCTAssertEqual(
            try ConnectionAuthenticator.env(for: .env(vars: ["GH_TOKEN", "GH_TOKEN"]), token: "T"),
            ["GH_TOKEN": "T"])
    }
}
