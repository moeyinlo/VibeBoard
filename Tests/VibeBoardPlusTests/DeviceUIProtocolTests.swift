import XCTest
@testable import VibeBoardPlus

final class DeviceUIProtocolTests: XCTestCase {
    func testCompletionUsesFirmwareUIStateProtocol() throws {
        for text in ["", "你好\n\"VibeBoard\""] {
            let data = try SerialDeviceLink.uiStatePayload(.ready, text: text)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: String])
            XCTAssertEqual(object, ["event": "ui_state", "state": "ready", "text": text])
        }
    }

    func testFinalizingState() throws {
        let data = try SerialDeviceLink.uiStatePayload(.thinking)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: String])
        XCTAssertEqual(object["state"], "thinking")
        XCTAssertEqual(object["event"], "ui_state")
    }
}
