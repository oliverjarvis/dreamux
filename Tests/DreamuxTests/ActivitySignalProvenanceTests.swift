import XCTest
@testable import Dreamux

final class ActivitySignalProvenanceTests: XCTestCase {

    private func signals(_ text: String) -> [ActivitySignal] {
        let bytes = Array(text.utf8)
        return PTYShellSession.extractActivitySignals(bytes[bytes.startIndex..<bytes.endIndex])
    }

    func testProvenanceLoggingIsOffByDefault() {
        // The probe is diagnostic, not a permanent tax on every byte the
        // terminal reads.
        XCTAssertFalse(PTYShellSession.provenanceLoggingEnabled(env: [:]))
        XCTAssertFalse(PTYShellSession.provenanceLoggingEnabled(env: ["DREAMUX_NOTIFY_DEBUG": "0"]))
        XCTAssertTrue(PTYShellSession.provenanceLoggingEnabled(env: ["DREAMUX_NOTIFY_DEBUG": "1"]))
    }

    func testOSC9NotificationIsStillExtracted() {
        XCTAssertEqual(signals("\u{1B}]9;hello\u{07}"), [.notification("hello")])
    }

    func testAgentStateControlIsExtracted() throws {
        let body = Data(#"{"state":"blocked"}"#.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let extracted = signals("\u{1B}]777;dreamux;agent-state;\(body)\u{07}")
        guard case .control(let verb, let json) = try XCTUnwrap(extracted.first) else {
            return XCTFail("expected .control")
        }
        XCTAssertEqual(verb, "agent-state")
        let decoded = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: json) as? [String: Any]
        )
        XCTAssertEqual(decoded["state"] as? String, "blocked")
    }

    func testBareBellIsStillAPingAndCarriesNoMessage() {
        XCTAssertEqual(signals("\u{07}"), [.ping])
    }

    func testConEmuProgressIsNotANotification() {
        XCTAssertTrue(signals("\u{1B}]9;4;1;50\u{07}").isEmpty)
    }
}
