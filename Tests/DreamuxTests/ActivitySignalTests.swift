import XCTest
@testable import Dreamux

final class ActivitySignalTests: XCTestCase {
    private func signals(_ s: String) -> [ActivitySignal] {
        let bytes = Array(s.utf8)
        return PTYShellSession.extractActivitySignals(bytes[...])
    }

    func testExistingFlavoursKeepTheirMeaning() {
        XCTAssertEqual(signals("\u{07}"), [.ping])
        XCTAssertEqual(signals("\u{1B}]9;hello world\u{07}"), [.notification("hello world")])
        XCTAssertEqual(signals("\u{1B}]777;notify;Title;Body\u{07}"), [.notification("Title: Body")])
        // ConEmu numeric subcommand still ignored
        XCTAssertEqual(signals("\u{1B}]9;4;1;50\u{07}"), [])
    }

    func testControlSignalDecodes() {
        // base64url of {"session_id":"s-1"} — no padding chars needed here,
        // but the decoder must tolerate them (see next test).
        let b64 = Data("{\"session_id\":\"s-1\"}".utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
        let got = signals("\u{1B}]777;dreamux;session-start;\(b64)\u{07}")
        guard case .control(let verb, let json)? = got.first else {
            return XCTFail("expected control, got \(got)")
        }
        XCTAssertEqual(verb, "session-start")
        let dict = try? JSONSerialization.jsonObject(with: json) as? [String: Any]
        XCTAssertEqual(dict?["session_id"] as? String, "s-1")
    }

    func testControlSurvivesInterleavedOutputAndBadPayload() {
        let b64 = Data("{}".utf8).base64EncodedString()
        let mixed = "plain text\u{1B}]777;dreamux;stop;\(b64)\u{07}more\u{07}"
        XCTAssertEqual(signals(mixed), [.control(verb: "stop", json: Data("{}".utf8)), .ping])
        // Garbage payload → dropped, no crash, following signals intact.
        XCTAssertEqual(signals("\u{1B}]777;dreamux;stop;!!!\u{07}\u{07}"), [.ping])
    }
}
