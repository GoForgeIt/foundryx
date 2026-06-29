import XCTest
import Foundation
import FoundryXKit

/// The capture page is the ONLY place to start/stop recording, and source connection is
/// automatic + self-healing. These door-free tests pin the pure `CaptureSourcePresentation`
/// state machine the capture header renders:
///   • the auto-connect states (connecting / reconnecting / searching) read as STATUS —
///     the user never drives a scan;
///   • a clean nothing-connected idle surfaces the inline "Connect your Omi" affordance;
///   • a device-page toggle-OFF removes the Omi from the capture page (phone-mic only),
///     so a disabled source is never shown as the active source.
/// No SwiftUI / no CoreBluetooth — the view just renders this presentation.
final class CaptureSourcePresentationTests: XCTestCase {

    // MARK: connected → listening / paused (the single record/pause control)

    func testConnectedNotPausedIsListening() {
        let p = CaptureSourcePresentation.resolve(connection: .connected("Omi-1234"),
                                                  omiEnabled: true, isPaused: false)
        XCTAssertEqual(p, .listening(name: "Omi-1234"))
        XCTAssertTrue(p.isConnected)
        XCTAssertTrue(p.isCapturing)
        XCTAssertEqual(p.connectedName, "Omi-1234")
        XCTAssertFalse(p.showsConnectAffordance)
        XCTAssertFalse(p.isAutoConnecting)
    }

    func testConnectedPausedIsPaused() {
        let p = CaptureSourcePresentation.resolve(connection: .connected("Omi-1234"),
                                                  omiEnabled: true, isPaused: true)
        XCTAssertEqual(p, .paused(name: "Omi-1234"))
        XCTAssertTrue(p.isConnected)
        XCTAssertFalse(p.isCapturing)        // paused → the control offers Resume
        XCTAssertFalse(p.showsConnectAffordance)
    }

    // MARK: auto-connect states read as STATUS (no user-driven scan)

    func testConnectingReconnectingSearchingAreAutoConnectStatus() {
        let cases: [(DeviceConnectionState, CaptureSourcePresentation)] = [
            (.connecting("Omi-1234"), .connecting(name: "Omi-1234")),
            (.disconnected, .reconnecting),
            (.scanning, .searching),
        ]
        for (state, expected) in cases {
            let p = CaptureSourcePresentation.resolve(connection: state, omiEnabled: true, isPaused: false)
            XCTAssertEqual(p, expected)
            XCTAssertTrue(p.isAutoConnecting, "\(expected) should show auto-connect status")
            // These are self-healing — they must NOT ask the user to drive a connect/scan.
            XCTAssertFalse(p.showsConnectAffordance, "\(expected) must not surface the connect affordance")
            XCTAssertFalse(p.isConnected)
        }
    }

    // MARK: "no source connected" surfaces the inline Connect affordance

    func testIdleSurfacesTheInlineConnectAffordance() {
        let p = CaptureSourcePresentation.resolve(connection: .idle, omiEnabled: true, isPaused: false)
        XCTAssertEqual(p, .needsConnection)
        XCTAssertTrue(p.showsConnectAffordance, "nothing connected → show 'Connect your Omi'")
        XCTAssertFalse(p.isAutoConnecting)
        XCTAssertFalse(p.isConnected)
    }

    func testBluetoothOffAsksToEnableBluetoothViaTheConnectAffordance() {
        let p = CaptureSourcePresentation.resolve(connection: .poweredOff, omiEnabled: true, isPaused: false)
        XCTAssertEqual(p, .bluetoothOff)
        XCTAssertTrue(p.showsConnectAffordance)
        XCTAssertTrue(p.statusLine.localizedCaseInsensitiveContains("bluetooth"))
    }

    // MARK: a device-page toggle-OFF removes the Omi from the capture page

    func testDisabledOmiIsNeverShownAsActiveRegardlessOfLink() {
        // Even a live BLE link must short-circuit to `.omiDisabled` when the source is
        // toggled off — so a disabled source is never offered/shown as active here.
        for state in [DeviceConnectionState.connected("Omi-1234"), .connecting("Omi-1234"),
                      .scanning, .disconnected, .idle, .poweredOff] {
            let p = CaptureSourcePresentation.resolve(connection: state, omiEnabled: false, isPaused: false)
            XCTAssertEqual(p, .omiDisabled, "omiEnabled=false must override connection \(state)")
            XCTAssertFalse(p.isConnected)
            XCTAssertFalse(p.isCapturing)
            XCTAssertNil(p.connectedName)
            // It is not the user's job to re-arm a deliberately-disabled source from here.
            XCTAssertFalse(p.showsConnectAffordance)
        }
    }
}
