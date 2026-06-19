import XCTest
import Combine
import CoreBluetooth
@testable import FoundryXKit

/// `@ble-hardware` lane — REAL CoreBluetooth against a REAL external Omi peripheral
/// (Omi's OmiSimulator running on a *second* Mac, or a worn Omi). It drives the real
/// `DeviceManager`: scan → discover → connect → subscribe, and asserts the stripped Opus
/// frames arrive. This is the only thing the door-free ambient test can't cover — that
/// DeviceManager/OmiBleSource actually drive CoreBluetooth end to end.
///
/// WHY external + skip-if-absent: a Mac's BLE radio cannot hear its **own** advertisements,
/// so an in-process / same-Mac peripheral is undiscoverable — real-BT connect inherently
/// needs two devices. So this lane:
///   • is SKIPPED unless `FOUNDRYX_BLE_HARDWARE=1` (needs BT + macOS BT permission), and
///   • SKIPS (not fails) if no Omi/sim peripheral is advertising in range.
/// Provide one per `features/omi-simulator-manual.md`, then:
///   `FOUNDRYX_BLE_HARDWARE=1 swift test --filter BLELoopbackTests`
final class BLELoopbackTests: XCTestCase {
    private var bag = Set<AnyCancellable>()

    func testRealBleScanConnectSubscribe() throws {
        guard ProcessInfo.processInfo.environment["FOUNDRYX_BLE_HARDWARE"] == "1" else {
            throw XCTSkip("@ble-hardware: set FOUNDRYX_BLE_HARDWARE=1 (real BT + permission) to run")
        }

        let dm = DeviceManager()
        var frameCount = 0
        let framesExp = expectation(description: "≥5 Opus frames")
        dm.onFrame = { _ in
            frameCount += 1
            if frameCount == 5 { framesExp.fulfill() }
        }

        // Scan; SKIP (don't fail) if no Omi/sim peripheral is advertising in range.
        let discovered = expectation(description: "discovered an Omi peripheral")
        dm.$discovered
            .sink { if !$0.isEmpty { discovered.fulfill() } }
            .store(in: &bag)
        dm.start()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { dm.startScan() }
        if XCTWaiter().wait(for: [discovered], timeout: 12) != .completed {
            dm.stop()
            throw XCTSkip("no Omi/sim peripheral advertising in range — run OmiSimulator on a second Mac or wear an Omi (see features/omi-simulator-manual.md)")
        }

        // A device is present → exercise the real connect + frame path.
        guard let dev = dm.discovered.first else { return XCTFail("discovered fired but list empty") }
        let connected = expectation(description: "connected")
        dm.$connectionState.sink { if case .connected = $0 { connected.fulfill() } }.store(in: &bag)
        dm.connect(dev)
        wait(for: [connected], timeout: 15)
        wait(for: [framesExp], timeout: 15)
        XCTAssertGreaterThanOrEqual(frameCount, 5, "connected but no audio frames streamed")
        dm.stop()
    }
}
