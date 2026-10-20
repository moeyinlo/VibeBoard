import AppKit
import XCTest
@testable import VibeBoardPlus

final class KeyboardActionTests: XCTestCase {
    func testKeyboardEventsHaveBalancedKeysAndModifiers() {
        for (action, key, flags) in [(ButtonAction.paste, 9, CGEventFlags.maskCommand),
                                      (.enter, 36, []), (.undo, 6, .maskCommand), (.escape, 53, [])] {
            let events = KeyboardActionSender.events(for: action)
            XCTAssertEqual(events.count, 2)
            XCTAssertEqual(events.first?.type, .keyDown)
            XCTAssertEqual(events.last?.type, .keyUp)
            for event in events {
                XCTAssertEqual(event.getIntegerValueField(.keyboardEventKeycode), Int64(key))
                XCTAssertEqual(event.flags, flags)
                XCTAssertEqual(event.getIntegerValueField(.keyboardEventAutorepeat), 0)
            }
        }
        XCTAssertTrue(KeyboardActionSender.events(for: .none).isEmpty)
    }
}
