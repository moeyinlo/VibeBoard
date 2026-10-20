import XCTest
@testable import VibeBoardPlus

final class ButtonSettingsTests: XCTestCase {
    func testSettingsPersistAndUnknownButtonsAreIgnored() throws {
        let suite = "vibeboardplus.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = ButtonSettings(defaults: defaults)
        XCTAssertEqual(settings.action(for: "k1"), .voice)
        XCTAssertEqual(settings.action(for: "k4"), .voice)
        settings.save(["k1": .toggleVoice, "k2": .copyResult])
        let restored = ButtonSettings(defaults: defaults)
        XCTAssertEqual(restored.action(for: "K2"), .copyResult)
        XCTAssertEqual(restored.action(for: "unknown"), .none)
    }

    func testPressReleaseClickExecutesOnceAndLatchesAction() {
        var router = ButtonEventRouter()
        XCTAssertEqual(router.down("k2", session: 0, action: .copyResult), .action(.copyResult))
        XCTAssertNil(router.down("k2", session: 0, action: .voice))
        XCTAssertNil(router.up("k2", now: 10))
        XCTAssertNil(router.click("k2", action: .copyResult, now: 10.1))
        XCTAssertEqual(router.click("k2", action: .copyResult, now: 11), .action(.copyResult))
    }

    func testIndependentHoldAndToggleButtons() {
        var router = ButtonEventRouter()
        XCTAssertEqual(router.down("k1", session: UInt64.max, action: .voice), .start(UInt64.max))
        XCTAssertEqual(router.down("k3", session: 9, action: .toggleVoice), .toggle(9))
        XCTAssertNil(router.up("k3", now: 1))
        XCTAssertEqual(router.up("k1", now: 2), .finish)
        XCTAssertNil(router.up("k1", now: 3))
    }

    func testFourthButtonStartsOnDownAndFinishesOnceOnUp() {
        var router = ButtonEventRouter()
        XCTAssertEqual(router.down("k4", session: 42, action: .voice), .start(42))
        XCTAssertEqual(router.up("k4", now: 1), .finish)
        XCTAssertNil(router.click("k4", action: .voice, now: 1.1))
        XCTAssertNil(router.up("k4", now: 1.2))
    }
}
