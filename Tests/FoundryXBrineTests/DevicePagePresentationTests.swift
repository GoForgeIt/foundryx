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

    // MARK: source guard — the shipped view is ONE LIST, and it derives no copy of its own

    /// WHAT THIS GATE USED TO HOLD, AND WHY IT MOVED (track
    /// 20260810T2158_unified_recording_device_list_wires_pocket_and_omi).
    ///
    /// It required `App/DeviceScreen.swift` to render `DeviceMetricsPresentation` (the
    /// Battery / Signal / Firmware strip) and `CaptureSourceRowPresentation` (the CAPTURE
    /// SOURCES rows) — the 20260714T1800 prototype's frame. On TestFlight 771837 that frame
    /// is exactly what a user found instead of their Pocket: a vendor hero block, a strip
    /// reading `N/A · N/A · N/A` for a device that had never reported anything, and a
    /// separate capture-sources section. `DESIGN-pocket-connect.md` §2 supersedes it with one
    /// list whose rows are peers, so this gate now holds THAT — and it holds the two
    /// anti-patterns as bans rather than leaving them merely un-required, because "the hero
    /// is gone" is the claim, not "something else is also present".
    ///
    /// The builders themselves are untouched and still unit-tested above; what changed is
    /// which surface is required to draw them.
    func testDeviceScreenIsOneListAndDerivesNoCopyOfItsOwn() throws {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { url.deleteLastPathComponent() }   // -> package root
        let src = try String(contentsOfFile: url.appendingPathComponent("App/DeviceScreen.swift").path,
                             encoding: .utf8)
        let code = AppSourceTree.withoutComments(of: src)

        for forbidden in ["Bluetooth battery", "Conversation splitting", "Add source",
                          "AddSourceSheet", "Device ID", "managed in Settings", "Pair in Settings"] {
            XCTAssertFalse(code.contains(forbidden),
                           "DeviceScreen.swift still contains app-only literal: \(forbidden)")
        }

        // THE HERO AND THE SPLIT, BANNED. Each of these is a literal the shipped screen drew.
        for forbidden in ["VOICE NOTE DEVICE", "Capture sources", "Connect Omi", "Disconnect Omi",
                          "Pair your Omi", "Looking for your Omi", "DeviceMetricsPresentation",
                          "CaptureSourceRowPresentation"] {
            XCTAssertFalse(code.contains(forbidden),
                           "App/DeviceScreen.swift still draws \"\(forbidden)\". The design's "
                               + "rule is one list of peers: a hero block for one vendor, or a "
                               + "section devices get sorted into, is \"one list, vendors "
                               + "first\" — which is what Nick was shown instead of his Pocket")
        }
        for forbidden in ["N/A", "In range"] {
            XCTAssertFalse(code.contains("\"\(forbidden)\""),
                           "App/DeviceScreen.swift renders the literal \"\(forbidden)\". A "
                               + "capability nobody read is absent or Unavailable, never N/A; "
                               + "and this phone cannot tell out-of-range from powered-off "
                               + "from connected-to-another-app")
        }

        // NOTHING IS SORTED HERE. The order is `RecordingSourceCatalog.merge`'s, which cannot
        // see the shape; a `sorted` or a `Section` in this file is how it would stop being.
        for forbidden in [".sorted(", "Section("] {
            XCTAssertFalse(code.contains(forbidden),
                           "App/DeviceScreen.swift contains `\(forbidden)` — the list's order "
                               + "comes from the merge and from nowhere else, and a section is "
                               + "a class the user gets sorted into")
        }

        // And it renders from the real presentation builders (not re-hardcoded copy).
        for required in ["ComputerMemoryPresentation", "UnifiedDeviceListPresentation",
                         "UnifiedDeviceListComposition", "RecordingDeviceConnectPresentation",
                         "RecordingDevicePage", "PocketOnboardingView"] {
            XCTAssertTrue(code.contains(required),
                          "App/DeviceScreen.swift no longer renders through `\(required)`")
        }
        XCTAssertTrue(code.contains("RecordingDeviceConnectPresentation.affordanceTitle"),
                      "the one connection affordance must be titled from the shipped constant")
        XCTAssertTrue(code.contains("RecordingDeviceConnectPresentation.emptyLine")
                          && code.contains("RecordingDeviceConnectPresentation.scanningLine"),
                      "the scanning and empty lines must be the shipped brand-free copy — they "
                          + "had zero consumers under App/ before this screen")
    }

    /// ACCEPTANCE 4: the affordance PRESENTS the Pocket onboarding flow.
    ///
    /// `PocketOnboardingView` shipped orphaned — a grep for it outside its own file returned
    /// nothing. `swift test` cannot compile `App/`, so a presenter that is deleted compiles
    /// fine and every scenario stays green; this reads the file instead.
    func testTheConnectAffordancePresentsThePocketOnboardingFlow() throws {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { url.deleteLastPathComponent() }
        let code = AppSourceTree.withoutComments(
            of: try String(contentsOfFile: url.appendingPathComponent("App/DeviceScreen.swift").path,
                           encoding: .utf8))
        XCTAssertTrue(code.contains("RecordingDeviceConnectSheet(device:"),
                      "the connect affordance no longer presents the connect sheet")
        XCTAssertTrue(code.contains("PocketOnboardingView(screen: .setupUnavailable)"),
                      "the connect sheet no longer reaches the Pocket setup ceremony — the "
                          + "view goes back to being orphaned, which is the defect this track "
                          + "exists to fix. §3.6 is where the flow honestly stops today")
        XCTAssertTrue(code.contains("PocketOnboardingView(screen: .education)"),
                      "the recorder education is unreachable — the design makes it permanently "
                          + "reachable from the list header and from the device page")

        // The presenters must be reachable from THE app, not only from this file.
        let referencing = try AppSourceTree.filesReferencing("PocketOnboardingView")
        XCTAssertTrue(referencing.contains("App/DeviceScreen.swift"),
                      "no App-side file outside PocketOnboardingView.swift references it — "
                          + "referencing files: \(referencing)")
    }

    /// ACCEPTANCE 7, from the other side: no record/stop control and no "In range", anywhere
    /// the record-then-sync page could put one.
    func testTheDeviceScreenNeverOffersARecordControlOrClaimsProximity() throws {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { url.deleteLastPathComponent() }
        let code = AppSourceTree.withoutComments(
            of: try String(contentsOfFile: url.appendingPathComponent("App/DeviceScreen.swift").path,
                           encoding: .utf8))
        for banned in ["startMicRecording", "stopMicRecording", "toggleRecording",
                       "In range", "in range"] {
            XCTAssertFalse(code.contains(banned),
                           "App/DeviceScreen.swift contains `\(banned)` — a device page may "
                               + "not start or stop a recording, and it may not claim a "
                               + "proximity this phone cannot observe")
        }
        XCTAssertTrue(code.contains("RecordingDevicePage.recorderIndicatorSentence")
                          || code.contains("page.recordingIndicatorSentence"),
                      "the band where a live device carries record/stop is blank for a "
                          + "record-then-sync device — the design's rule is that it is "
                          + "occupied by the true fact instead")
    }

    // MARK: helpers

    @MainActor
    private func registry() -> CaptureSourceRegistry {
        CaptureSourceRegistry(store: InMemoryCaptureSourceStore(),
                              discovery: CaptureSourceRegistryTests.FakeAudioInputDiscovery())
    }
}
