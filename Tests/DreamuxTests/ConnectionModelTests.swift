import XCTest
@testable import Dreamux

final class ConnectionModelTests: XCTestCase {
    func testAuthKindRoundTripsEachCase() throws {
        let kinds: [AuthKind] = [
            .header(headerName: "Authorization", valueTemplate: "Bearer {token}"),
            .basic(username: "me"),
            .query(param: "api_key"),
            .env(vars: ["GH_TOKEN", "GITHUB_TOKEN"]),
        ]
        for kind in kinds {
            let data = try JSONEncoder().encode(kind)
            XCTAssertEqual(try JSONDecoder().decode(AuthKind.self, from: data), kind)
        }
        XCTAssertTrue(AuthKind.header(headerName: "A", valueTemplate: "{token}").isHTTP)
        XCTAssertTrue(AuthKind.basic(username: "u").isHTTP)
        XCTAssertTrue(AuthKind.query(param: "k").isHTTP)
        XCTAssertFalse(AuthKind.env(vars: ["X"]).isHTTP)
    }

    func testConnectionRoundTrips() throws {
        let c = Connection(id: "github", label: "GitHub",
            kind: .header(headerName: "Authorization", valueTemplate: "Bearer {token}"),
            hosts: ["api.github.com"], source: .importedFromCLI(tool: "gh"),
            createdAt: Date(timeIntervalSince1970: 1000))
        XCTAssertEqual(try JSONDecoder().decode(Connection.self,
            from: JSONEncoder().encode(c)), c)
    }

    func testManifestDecodesWithAndWithoutConnections() throws {
        // Old manifest (no requiresConnections) still decodes → [].
        let old = Data("""
        {"id":"\(UUID().uuidString)","name":"n","slug":"n","icon":"i",
         "description":"d","requiresCapabilities":["http"]}
        """.utf8)
        let m1 = try JSONDecoder().decode(AppletManifest.self, from: old)
        XCTAssertEqual(m1.requiresConnections, [])
        // New manifest round-trips the slots.
        var m2 = m1
        m2.requiresConnections = [ConnectionSlot(id: "github", label: "GitHub",
            hosts: ["api.github.com"], suggests: "github")]
        let decoded = try JSONDecoder().decode(AppletManifest.self,
            from: JSONEncoder().encode(m2))
        XCTAssertEqual(decoded.requiresConnections, m2.requiresConnections)
    }

    func testConnectionSlotDecodesWithoutRecipeFields() throws {
        // Old slot (no authKind/importCommand) → nils, back-compat.
        let json = Data(#"{"id":"gh","label":"GitHub","hosts":["api.github.com"]}"#.utf8)
        let slot = try JSONDecoder().decode(ConnectionSlot.self, from: json)
        XCTAssertNil(slot.authKind)
        XCTAssertNil(slot.importCommand)
        XCTAssertNil(slot.suggests)
    }

    func testConnectionSlotRoundTripsFullRecipe() throws {
        let slot = ConnectionSlot(
            id: "linear", label: "Linear", hosts: ["api.linear.app"], suggests: nil,
            authKind: .header(headerName: "Authorization", valueTemplate: "{token}"),
            importCommand: "linear-cli token")
        let decoded = try JSONDecoder().decode(ConnectionSlot.self,
            from: JSONEncoder().encode(slot))
        XCTAssertEqual(decoded, slot)
        XCTAssertEqual(decoded.authKind, .header(headerName: "Authorization", valueTemplate: "{token}"))
        XCTAssertEqual(decoded.importCommand, "linear-cli token")
    }

    func testManifestWithRecipeSlotsStillDecodes() throws {
        let json = Data(#"""
        {"id":"00000000-0000-0000-0000-000000000000","name":"n","slug":"n","icon":"i",
         "description":"d","requiresCapabilities":["http"],
         "requiresConnections":[{"id":"gh","label":"GitHub","hosts":["api.github.com"],
           "authKind":{"header":{"headerName":"Authorization","valueTemplate":"Bearer {token}"}},
           "importCommand":"gh auth token"}]}
        """#.utf8)
        let m = try JSONDecoder().decode(AppletManifest.self, from: json)
        XCTAssertEqual(m.requiresConnections.first?.importCommand, "gh auth token")
        XCTAssertEqual(m.requiresConnections.first?.authKind,
            .header(headerName: "Authorization", valueTemplate: "Bearer {token}"))
    }
}
