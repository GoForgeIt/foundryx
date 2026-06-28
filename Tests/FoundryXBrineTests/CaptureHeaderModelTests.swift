import XCTest
import Foundation
import FoundryXKit

/// Door-free tests for the consolidated capture header's Omi scan control (Feature 3):
/// the pure `OmiScanPresentation` state machine (collapsed icon ↔ expanded "Scanning…"
/// pill) and the scan toggle, plus `DeviceManager.stopScan()` returning to idle. No
/// SwiftUI / no hardware — the view just renders this presentation.
final class CaptureHeaderModelTests: XCTestCase {

    /// Idle / disconnected → a small COLLAPSED icon (no label, no activity); tapping it
    /// starts a scan.
    func testIdleAndDisconnectedCollapseToATappableScanIcon() {
        for state in [DeviceConnectionState.idle, .disconnected] {
            let p = OmiScanPresentation.from(state)
            XCTAssertEqual(p, .collapsed)
            XCTAssertFalse(p.isExpanded)
            XCTAssertFalse(p.showsActivity)
            XCTAssertNil(p.label)
            XCTAssertEqual(p.tapAction, .startScan)
        }
    }

    /// Scanning → an EXPANDED "Scanning…" pill with a subtle activity indicator; tapping
    /// it again STOPS the scan (collapses back).
    func testScanningExpandsWithActivityAndTapStops() {
        let p = OmiScanPresentation.from(.scanning)
        XCTAssertEqual(p, .scanning)
        XCTAssertTrue(p.isExpanded)
        XCTAssertTrue(p.showsActivity)
        XCTAssertEqual(p.label, "Scanning…")
        XCTAssertEqual(p.tapAction, .stopScan)
    }

    /// Connecting → an expanded pill with the device name + activity; a tap is inert
    /// (the BLE lifecycle drives it, not the user).
    func testConnectingExpandsWithActivityAndIsNotTappable() {
        let p = OmiScanPresentation.from(.connecting("Omi-1234"))
        XCTAssertTrue(p.isExpanded)
        XCTAssertTrue(p.showsActivity)
        XCTAssertEqual(p.label, "Connecting…")
        XCTAssertEqual(p.tapAction, .none)
    }

    /// Connected → the distinct connected presentation (name label, no spinner, inert tap).
    func testConnectedIsDistinctAndInert() {
        let p = OmiScanPresentation.from(.connected("Omi-1234"))
        XCTAssertEqual(p, .connected("Omi-1234"))
        XCTAssertTrue(p.isExpanded)
        XCTAssertFalse(p.showsActivity)
        XCTAssertEqual(p.label, "Omi-1234")
        XCTAssertEqual(p.tapAction, .none)
    }

    /// Bluetooth off → a non-interactive collapsed icon (no label, no activity, inert tap).
    func testBluetoothOffIsCollapsedAndInert() {
        let p = OmiScanPresentation.from(.poweredOff)
        XCTAssertEqual(p, .off)
        XCTAssertFalse(p.isExpanded)
        XCTAssertFalse(p.showsActivity)
        XCTAssertNil(p.label)
        XCTAssertEqual(p.tapAction, .none)
    }

    /// `stopScan()` returns the manager to idle and clears any discovered devices (the
    /// header's Omi icon collapses back). Safe with no central created (no BLE prompt).
    @MainActor
    func testStopScanReturnsToIdleAndClearsDiscovered() async throws {
        let dm = DeviceManager()
        dm.stopScan()
        // setState/​setDiscovered hop to the main queue; let it run.
        let start = Date()
        while dm.connectionState != .idle, Date().timeIntervalSince(start) < 2 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(dm.connectionState, .idle)
        XCTAssertTrue(dm.discovered.isEmpty)
    }
}
