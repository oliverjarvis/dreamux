import XCTest
@testable import Dreamux

final class AppletBridgeCoreTests: XCTestCase {
    func testParse() {
        let req = BridgeRequest.parse(["id": 3, "method": "kv.get", "params": ["key": "k"]])
        XCTAssertEqual(req?.id, 3)
        XCTAssertEqual(req?.method, "kv.get")
        XCTAssertEqual(req?.params["key"] as? String, "k")
        XCTAssertNil(BridgeRequest.parse(["method": "kv.get"]))       // no id
        XCTAssertNil(BridgeRequest.parse("nonsense"))
    }

    func testCapabilityMappingAndGate() throws {
        XCTAssertNil(AppletBridgeCore.capability(forMethod: "context"))
        XCTAssertEqual(AppletBridgeCore.capability(forMethod: "kv.set"), .kv)
        XCTAssertEqual(AppletBridgeCore.capability(forMethod: "fs.read"), .fs)
        XCTAssertEqual(AppletBridgeCore.capability(forMethod: "http.fetch"), .http)
        XCTAssertEqual(AppletBridgeCore.capability(forMethod: "shell.exec"), .shell)
        XCTAssertEqual(AppletBridgeCore.capability(forMethod: "notify"), .notify)
        XCTAssertNoThrow(try AppletBridgeCore.checkAllowed(method: "context", granted: []))
        XCTAssertNoThrow(try AppletBridgeCore.checkAllowed(method: "kv.get", granted: [.kv]))
        XCTAssertThrowsError(try AppletBridgeCore.checkAllowed(method: "shell.exec", granted: [.kv])) {
            // The error message names the manifest fix.
            XCTAssertTrue("\($0.localizedDescription)".contains("requiresCapabilities"))
        }
        XCTAssertThrowsError(try AppletBridgeCore.checkAllowed(method: "bogus", granted: [.kv]))
    }
}
