import XCTest
import Foundation
import FoundryXKit

/// Device-page presentation units (track 20260714T1800 §8) — the pure values
/// the App's DeviceScreen renders 1:1. The matching user-facing scenarios live
/// in features/capture-sources.feature (run by CaptureSourceRegistryTests).
final class DevicePagePresentationTests: XCTestCase {

    // MARK: Computer memory

    func testUnpairedComputerMemoryOffersPairingHonestly() {
        let p = ComputerMemoryPresentation.resolve(.notConnected)
        XCTAssertEqual(p.title, "Connect your computer")
        XCTAssertEqual(p.subtitle, "Pair the desktop app for full-history search and local Brain runs")
        XCTAssertEqual(p.statusLabel, "Not connected")
        XCTAssertFalse(p.isConnected)
        XCTAssertEqual(p.actionTitle, "Connect your computer")
        XCTAssertTrue(p.actionIsPrimary)
        XCTAssertEqual(p.footer, "Pairing is end-to-end encrypted to your own machine.")
    }

    func testPairedComputerMemoryShowsNameAndDisconnect() {
        let p = ComputerMemoryPresentation.resolve(.connected(name: "Nick's MacBook"))
        XCTAssertEqual(p.title, "Nick's MacBook")
        XCTAssertEqual(p.subtitle, "Desktop app paired · Full-history search ready")
        XCTAssertEqual(p.statusLabel, "Connected")
        XCTAssertTrue(p.isConnected)
        XCTAssertEqual(p.actionTitle, "Disconnect computer")
        XCTAssertFalse(p.actionIsPrimary)
        XCTAssertEqual(p.footer, "Pairing is end-to-end encrypted to your own machine.")
    }

    func testPairedComputerWithoutAFriendlyNameFallsBack() {
        // host/resolve doesn't return a friendly name yet — never render "" or a tunnel hash.
        XCTAssertEqual(ComputerMemoryPresentation.resolve(.connected(name: nil)).title, "Your computer")
        XCTAssertEqual(ComputerMemoryPresentation.resolve(.connected(name: "")).title, "Your computer")
    }

    // MARK: Metrics strip

    func testMetricsLabelsAreBatterySignalFirmware() {
        XCTAssertEqual(DeviceMetricsPresentation.labels, ["Battery", "Signal", "Firmware"])
    }

    func testConnectedMetricsShowFirmwareAndBattery() {
        let m = DeviceMetricsPresentation.resolve(omiConnected: true, batteryPercent: 78, signal: "Strong",
                                                 firmware: .reported("2.4.1"))
        XCTAssertEqual(m.battery, "78%")
        XCTAssertEqual(m.signal, "Strong")
        // The value the DEVICE reported, and the only way one can get here. The prototype's
        // hard-coded "2.4.1" for every connected device is gone (T5 / spec R3): a version a
        // user might quote to support is the most plausible-looking default in the strip.
        XCTAssertEqual(m.firmware, "2.4.1")
    }

    func testDisconnectedMetricsShowNA() {
        let m = DeviceMetricsPresentation.resolve(omiConnected: false, batteryPercent: nil, signal: "N/A",
                                                 firmware: .unavailable)
        XCTAssertEqual(m.battery, "N/A")
        XCTAssertEqual(m.firmware, "N/A")
    }

    // MARK: Capture-source rows

    @MainActor
    func testPhoneMicRowOffersASecondSource() {
        let reg = registry()
        let phone = reg.sources.first { $0.category == .phoneMic }!
        let row = CaptureSourceRowPresentation.resolve(for: phone, omiConnected: false)
        XCTAssertEqual(row.title, "Phone microphone")
        XCTAssertEqual(row.subtitle, "Use this iPhone as another capture source")
    }

    @MainActor
    func testOmiRowSubtitleTracksConnection() {
        let reg = registry()
        let omi = reg.sources.first { $0.category == .omi }!
        XCTAssertEqual(CaptureSourceRowPresentation.resolve(for: omi, omiConnected: true).subtitle,
                       "Use the wearable for capture")
        XCTAssertEqual(CaptureSourceRowPresentation.resolve(for: omi, omiConnected: false).subtitle,
                       "Reconnect Omi to use this source")
        XCTAssertEqual(CaptureSourceRowPresentation.resolve(for: omi, omiConnected: true).title,
                       "Omi microphone")
    }

    @MainActor
    func testPrototypeRowsAreExactlyTheTwoBuiltIns() {
        let reg = registry()
        _ = reg.addAppleWatchScaffold()
        let rows = CaptureSourceRowPresentation.prototypeRows(reg.sources)
        XCTAssertEqual(rows.map(\.category), [.omi, .phoneMic])
    }

    // MARK: B1 source guard — the shipped view keeps prototype parity

    func testDeviceScreenSourceHasNoAppOnlySections() throws {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { url.deleteLastPathComponent() }   // -> package root
        let src = try String(contentsOfFile: url.appendingPathComponent("App/DeviceScreen.swift").path,
                             encoding: .utf8)
        for forbidden in ["Bluetooth battery", "Conversation splitting", "Add source",
                          "AddSourceSheet", "Device ID", "managed in Settings", "Pair in Settings"] {
            XCTAssertFalse(src.contains(forbidden),
                           "DeviceScreen.swift still contains app-only literal: \(forbidden)")
        }
        // And it renders from the real presentation builders (not re-hardcoded copy).
        XCTAssertTrue(src.contains("ComputerMemoryPresentation"),
                      "DeviceScreen should render the Computer memory section from ComputerMemoryPresentation")
        XCTAssertTrue(src.contains("DeviceMetricsPresentation"),
                      "DeviceScreen should render the metrics strip from DeviceMetricsPresentation")
        XCTAssertTrue(src.contains("CaptureSourceRowPresentation"),
                      "DeviceScreen should render source rows from CaptureSourceRowPresentation")
    }

    // MARK: helpers

    @MainActor
    private func registry() -> CaptureSourceRegistry {
        CaptureSourceRegistry(store: InMemoryCaptureSourceStore(),
                              discovery: CaptureSourceRegistryTests.FakeAudioInputDiscovery())
    }
}
