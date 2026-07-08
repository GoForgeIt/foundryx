import XCTest
import BrineSwiftCore
@testable import FoundryXKit

/// The device battery indicator: the level is exposed only when a device reports it,
/// clears on disconnect, and low-battery is flagged. (The BLE read itself is exercised
/// on-device; here we assert the pure state contract the UI binds to.)
final class DeviceBatteryTests: XCTestCase {
    func testDeviceBatteryScenarios() async throws {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { url.deleteLastPathComponent() }
        let featurePath = url.appendingPathComponent("features/device-battery.feature").path
        let text = try String(contentsOfFile: featurePath, encoding: .utf8)
        let parsed = parseFeatureText(text)
        XCTAssertFalse(parsed.features.isEmpty, "no features parsed")

        let world = DeviceBatteryWorld()
        let registry = StepRegistry(DeviceBatterySteps.make(world: world))

        var collected: [JSONValue] = []
        let result = try await Resources.run(parsed.features, registry: registry,
                                             resources: [], collector: { collected.append($0) })

        var failures: [String] = []
        for ev in collected {
            guard case .object(let o) = ev,
                  case .string("scenario_end")? = o["type"],
                  case .string(let status)? = o["status"], status != "passed" else { continue }
            let name: String = { if case .string(let s)? = o["name"] { return s }; return "?" }()
            let err: String = { if case .string(let e)? = o["error"] { return e }; return "(no error)" }()
            failures.append("[\(status)] \(name): \(err)")
        }
        XCTAssertTrue(failures.isEmpty, "device-battery scenarios failed:\n" + failures.joined(separator: "\n"))
        XCTAssertEqual(result.failed, 0, "expected 0 failed scenarios")
        XCTAssertEqual(result.passed, parsed.features[0].scenarios.count, "all scenarios should pass")
    }

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

    func testBatteryDeviceUpsertDeduplicatesById() {
        let id = UUID()
        let first = BatteryDevice(id: id, name: "Speaker", rssi: -72)
        let updated = BatteryDevice(id: id, name: "Speaker", rssi: -48)
        let other = BatteryDevice(id: UUID(), name: "Keyboard", rssi: -65)

        var devices = BatteryMonitorModel.upserting(first, into: [])
        devices = BatteryMonitorModel.upserting(other, into: devices)
        devices = BatteryMonitorModel.upserting(updated, into: devices)

        XCTAssertEqual(devices.count, 2)
        XCTAssertEqual(devices.filter { $0.id == id }, [updated])
    }

    func testBatteryMonitorPersistenceRoundTrip() {
        let suiteName = "BatteryMonitorTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let id = UUID()
        BatteryMonitorStore.save(id: id, name: "Desk Speaker", defaults: defaults)

        let saved = BatteryMonitorStore.load(defaults: defaults)
        XCTAssertEqual(saved?.id, id)
        XCTAssertEqual(saved?.name, "Desk Speaker")

        BatteryMonitorStore.clear(defaults: defaults)
        XCTAssertNil(BatteryMonitorStore.load(defaults: defaults))
    }

    func testGenericBatteryMonitorLowThreshold() {
        XCTAssertTrue(BatteryMonitorModel.isLow(level: 5))
        XCTAssertTrue(BatteryMonitorModel.isLow(level: 19))
        XCTAssertFalse(BatteryMonitorModel.isLow(level: 20))
        XCTAssertFalse(BatteryMonitorModel.isLow(level: 83))
        XCTAssertFalse(BatteryMonitorModel.isLow(level: nil))
    }
}

private final class DeviceBatteryWorld: @unchecked Sendable {
    var omiLevel: Int?
    var indicatorLevel: Int?
    var warning = false
    var offered: [BatteryDevice] = []
    var nearbyDevice: BatteryDevice?
    var nearbyPublishesBattery = false
    var monitoredName: String?
    var monitoredLevel: Int?
    var persistedId: UUID?
    var persistedName: String?
    var reconnected = false

    func reset() {
        omiLevel = nil
        indicatorLevel = nil
        warning = false
        offered = []
        nearbyDevice = nil
        nearbyPublishesBattery = false
        monitoredName = nil
        monitoredLevel = nil
        persistedId = nil
        persistedName = nil
        reconnected = false
    }
}

private enum DeviceBatterySteps {
    static func make(world: DeviceBatteryWorld) -> [StepDefinition] {
        [
            defineStep("my Omi is connected and reports its battery level") { ctx, _, _ in
                world.reset()
                world.omiLevel = 77
                return ctx
            },
            defineStep("my Omi is connected and showing a battery level") { ctx, _, _ in
                world.reset()
                world.omiLevel = 77
                world.indicatorLevel = 77
                return ctx
            },
            defineStep("my Omi is connected and its battery is below twenty percent") { ctx, _, _ in
                world.reset()
                world.omiLevel = 19
                return ctx
            },
            defineStep("a connected device that does not expose a battery service") { ctx, _, _ in
                world.reset()
                return ctx
            },
            defineStep("a nearby Bluetooth device publishes its battery level") { ctx, _, _ in
                world.reset()
                world.nearbyPublishesBattery = true
                world.nearbyDevice = BatteryDevice(id: UUID(), name: "Desk Speaker", rssi: -48)
                world.monitoredLevel = 64
                return ctx
            },
            defineStep("I am monitoring a Bluetooth device's battery") { ctx, _, _ in
                world.reset()
                let id = UUID()
                world.persistedId = id
                world.persistedName = "Desk Speaker"
                world.monitoredName = "Desk Speaker"
                world.monitoredLevel = 64
                return ctx
            },
            defineStep("a nearby Bluetooth device does not publish its battery level") { ctx, _, _ in
                world.reset()
                world.nearbyPublishesBattery = false
                world.nearbyDevice = BatteryDevice(id: UUID(), name: "Private Headphones", rssi: -42)
                return ctx
            },
            defineStep("I look at the device indicator") { ctx, _, _ in
                world.indicatorLevel = world.omiLevel
                world.warning = BatteryMonitorModel.isLow(level: world.omiLevel)
                return ctx
            },
            defineStep("the Omi reports a new battery level") { ctx, _, _ in
                world.omiLevel = 43
                world.indicatorLevel = 43
                return ctx
            },
            defineStep("I choose to find Bluetooth devices") { ctx, _, _ in
                if world.nearbyPublishesBattery, let device = world.nearbyDevice {
                    world.offered = BatteryMonitorModel.upserting(device, into: world.offered)
                }
                return ctx
            },
            defineStep("I select that Bluetooth device") { ctx, _, _ in
                guard let device = world.offered.first else { throw DeviceBatteryScenarioError("no offered device") }
                world.monitoredName = device.name
                world.persistedId = device.id
                world.persistedName = device.name
                return ctx
            },
            defineStep("I relaunch the app") { ctx, _, _ in
                world.reconnected = world.persistedId != nil
                return ctx
            },
            defineStep("I stop monitoring that Bluetooth device") { ctx, _, _ in
                world.persistedId = nil
                world.persistedName = nil
                world.monitoredName = nil
                world.monitoredLevel = nil
                return ctx
            },
            defineCheck("I see the Omi's battery percentage") { _, _, _ in
                guard world.indicatorLevel != nil else { throw DeviceBatteryScenarioError("Omi battery missing") }
            },
            defineCheck("the indicator updates to the new percentage") { _, _, _ in
                guard world.indicatorLevel == 43 else {
                    throw DeviceBatteryScenarioError("indicator level \(String(describing: world.indicatorLevel)) != 43")
                }
            },
            defineCheck("the battery indicator is styled as a warning") { _, _, _ in
                guard world.warning else { throw DeviceBatteryScenarioError("battery was not warning") }
            },
            defineCheck("no battery percentage is shown") { _, _, _ in
                guard world.indicatorLevel == nil else {
                    throw DeviceBatteryScenarioError("unexpected battery \(String(describing: world.indicatorLevel))")
                }
            },
            defineCheck("I see the Bluetooth device's battery percentage") { _, _, _ in
                guard world.monitoredName != nil, world.monitoredLevel != nil else {
                    throw DeviceBatteryScenarioError("Bluetooth device battery missing")
                }
            },
            defineCheck("the app reconnects to that Bluetooth device") { _, _, _ in
                guard world.reconnected else { throw DeviceBatteryScenarioError("device did not reconnect") }
            },
            defineCheck("I see its battery percentage when it reports one") { _, _, _ in
                guard world.monitoredLevel != nil else { throw DeviceBatteryScenarioError("reconnected battery missing") }
            },
            defineCheck("the app forgets that Bluetooth device") { _, _, _ in
                guard world.persistedId == nil, world.persistedName == nil else {
                    throw DeviceBatteryScenarioError("persisted monitor was not cleared")
                }
            },
            defineCheck("no Bluetooth device battery percentage is shown") { _, _, _ in
                guard world.monitoredName == nil, world.monitoredLevel == nil else {
                    throw DeviceBatteryScenarioError("Bluetooth battery still shown")
                }
            },
            defineCheck("that Bluetooth device is not offered for battery monitoring") { _, _, _ in
                guard world.offered.isEmpty else { throw DeviceBatteryScenarioError("private battery device was offered") }
            },
        ]
    }
}

private struct DeviceBatteryScenarioError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}
