import XCTest
@testable import Dreamux

/// Intercepts every request on a private URLSession so client tests
/// run with zero network. Set `handler` per test.
final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let (status, data) = handler(request)
        let response = HTTPURLResponse(
            url: url, statusCode: status, httpVersion: nil, headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class SkillsRegistryClientTests: XCTestCase {
    private var client: SkillsRegistryClient!

    override func setUp() {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        client = SkillsRegistryClient(
            baseURL: URL(string: "https://stub.test")!,
            session: URLSession(configuration: config)
        )
    }

    override func tearDown() { StubURLProtocol.handler = nil }

    func testSearchBuildsQueryAndDecodes() async throws {
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/search")
            let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
            XCTAssertEqual(components.queryItems?.first { $0.name == "q" }?.value, "react")
            XCTAssertEqual(components.queryItems?.first { $0.name == "limit" }?.value, "30")
            let body = #"{"skills":[{"id":"a/b/c","skillId":"c","name":"c","installs":5,"source":"a/b"}]}"#
            return (200, Data(body.utf8))
        }
        let results = try await client.search(query: "react")
        XCTAssertEqual(results.map(\.id), ["a/b/c"])
    }

    func testShortQueryThrowsWithoutRequest() async {
        StubURLProtocol.handler = { _ in
            XCTFail("no request should be made for a 1-char query")
            return (500, Data())
        }
        do {
            _ = try await client.search(query: "r")
            XCTFail("expected queryTooShort")
        } catch SkillsRegistryError.queryTooShort {
        } catch { XCTFail("unexpected error: \(error)") }
    }

    func testNon200Throws() async {
        StubURLProtocol.handler = { _ in (503, Data()) }
        do {
            _ = try await client.search(query: "react")
            XCTFail("expected badStatus")
        } catch SkillsRegistryError.badStatus(let code) {
            XCTAssertEqual(code, 503)
        } catch { XCTFail("unexpected error: \(error)") }
    }
}
