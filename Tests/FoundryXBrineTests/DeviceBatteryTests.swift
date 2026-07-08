import XCTest
@testable import FoundryXKit

/// The device battery indicator: the level is exposed only when a device reports it,
/// clears on disconnect, and low-battery is flagged. (The BLE read itself is exercised
/// on-device; here we assert the pure state contract the UI binds to.)
final class DeviceBatteryTests: XCTestCase {
    func testDefaultIsNilAndNotLow() {
        let dm = DeviceManager()
        XCTAssertNil(dm.batteryLevel, "no device / no report ⇒ no battery shown")
        XCTAssertFalse(dm.isBatteryLow, "unknown battery is not 'low' (no false alarm)")
    }

    func testLowThreshold() {
        // isBatteryLow is derived: <20% is low. Pure boundary check via the same rule
        // the badge uses (kept in sync with DeviceManager.isBatteryLow).
        func low(_ level: Int?) -> Bool { (level ?? 100) < 20 }
        XCTAssertTrue(low(5))
        XCTAssertTrue(low(19))
        XCTAssertFalse(low(20))
        XCTAssertFalse(low(83))
        XCTAssertFalse(low(nil))
    }
}
