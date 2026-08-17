// THE DIAGNOSTIC SINK, ON EVERY LAUNCH, EXACTLY ONCE.
//
// WHAT WAS MEASURED. 1,569 diag lines reached the relay from one handset in a day. Zero of
// them were `cmd pocket…` lines and zero were recorder lines — while chat, capture and
// sign-in lines arrived normally. The recorder surface (`App/DeviceScreen.swift`) reports
// into `DoorLog.shared`; `App/RootView.swift` built its OWN `DoorLog()` and sinked THAT one.
// So the lines that did arrive were the ones written through the view's private instance,
// and every line written to the process-wide log died on the device.
//
// TWO DEFECTS, ONE SYMPTOM:
//
//   1. `App/FoundryXAppDelegate.swift` guarded the WHOLE of `didFinishLaunchingWithOptions`
//      on `launchOptions[.bluetoothCentrals] != nil` — a key iOS supplies only on a
//      background CoreBluetooth restoration relaunch. On a normal launch the method returned
//      before reaching `setRemoteSink`, so `DoorLog.shared` had no sink, `flush()` bailed at
//      its first guard, and nothing it held ever left the phone.
//
//   2. `setRemoteSink` unconditionally invalidated and rebuilt the 15-second backstop timer.
//      `RootView.init` runs again on every `.id`-driven rebuild — far more often than every
//      15 seconds — so each re-init killed the heartbeat before it could fire. That is why
//      "diag transport online" shipped every ~5 seconds and the periodic flush never ran at
//      all: the backstop was permanently reset to zero.
//
// These tests hold both. The behavioural ones can run because the LAUNCH DECISION lives in
// the Kit (`FoundryXLaunch`) rather than inside a SwiftUI body — `swift test` cannot compile
// `App/`, so a decision written there cannot be falsified. The source gates hold the part
// that necessarily lives in `App/`: that it delegates rather than re-deciding.

import XCTest
import Foundation
@testable import FoundryXKit

final class DiagnosticSinkLaunchTests: XCTestCase {

    /// A loopback discard port. The sink is exercised for real (a `Timer` is scheduled, a
    /// fire-and-forget POST is attempted) without any test reaching the network.
    private static let sink = URL(string: "http://127.0.0.1:9/diag/log")!
    private static let otherSink = URL(string: "http://127.0.0.1:9/diag/other")!

    override func tearDown() {
        // The process-wide log is shared with every other test in this suite. Leave it inert.
        DoorLog.shared.setRemoteSink(nil)
        super.tearDown()
    }

    private func announcements(_ log: DoorLog) -> [DoorLog.Entry] {
        log.entries.filter { $0.text.contains("diag transport online") }
    }

    // MARK: - Defect 1 — a normal launch must sink the process-wide log

    /// THE ONE THAT MATTERS. Before the fix there is no code path at all that sinks
    /// `DoorLog.shared` on an ordinary launch, so every `cmd pocket…` line dies on the device.
    func testANormalLaunchSinksTheProcessWideLog() {
        DoorLog.shared.setRemoteSink(nil)

        let plan = FoundryXLaunch.begin(bluetoothRestoration: false,
                                        diagnosticSink: Self.sink)

        XCTAssertEqual(DoorLog.shared.remoteSinkURL, Self.sink,
                       "a NORMAL launch left DoorLog.shared unsinked. Every call site that "
                           + "holds no log of its own — the whole recorder surface — reports "
                           + "into DoorLog.shared, and flush() returns at its first guard "
                           + "when there is no sink, so none of it ever leaves the phone")
        XCTAssertFalse(plan.runsBluetoothRestoration,
                       "a normal launch is not a CoreBluetooth restoration relaunch")
    }

    /// The restoration work stays behind its own guard — sinking the log on every launch must
    /// not have turned every launch into a BLE restoration bootstrap.
    func testOnlyARestorationRelaunchRunsTheRestorationBootstrap() {
        DoorLog.shared.setRemoteSink(nil)

        let restoration = FoundryXLaunch.begin(bluetoothRestoration: true,
                                               diagnosticSink: Self.sink)

        XCTAssertTrue(restoration.runsBluetoothRestoration)
        XCTAssertEqual(DoorLog.shared.remoteSinkURL, Self.sink,
                       "a restoration relaunch sinks the log too — it is the launch that most "
                           + "needs to be observable")
    }

    /// A build with no relay configured must not be a crash or a half-configured log.
    func testALaunchWithNoConfiguredRelayLeavesTheLogInert() {
        DoorLog.shared.setRemoteSink(nil)

        _ = FoundryXLaunch.begin(bluetoothRestoration: false, diagnosticSink: nil)

        XCTAssertNil(DoorLog.shared.remoteSinkURL)
    }

    // MARK: - Defect 2 — exactly once per process for the same URL

    /// THE HEARTBEAT KILLER. `setRemoteSink` invalidated the 15s backstop timer and built a
    /// new one on every call. `RootView.init` re-runs faster than 15s, so the backstop never
    /// fired once — measurable as the announcement shipping every few seconds. Installing the
    /// same sink twice must be a no-op: no second announcement, no second timer.
    func testInstallingTheSameSinkTwiceInstallsItOnce() {
        let log = DoorLog()

        log.setRemoteSink(Self.sink)
        log.setRemoteSink(Self.sink)
        log.setRemoteSink(Self.sink)

        XCTAssertEqual(announcements(log).count, 1,
                       "the sink was installed more than once for the same URL. Each install "
                           + "invalidates the periodic backstop flush before it can fire, so "
                           + "on a surface that re-inits faster than the 15s cadence the "
                           + "backstop never runs at all")
        log.setRemoteSink(nil)
    }

    /// The same, through the launch bootstrap the app actually calls — a second launch-time
    /// bootstrap (a restoration relaunch handing over to the UI) must not re-sink.
    ///
    /// COUNTED AS A DELTA, not an absolute. `DoorLog.shared` is a process-wide ring buffer
    /// every other test in this process also writes to, so an absolute count here measures
    /// the suite rather than the bootstrap — the same discipline
    /// `OneTapIsOneErrandFeatureTests` already takes a baseline for. Clearing it instead
    /// would make this test destroy evidence its neighbours are asserting on.
    func testRepeatedLaunchBootstrapsInstallTheSinkOnce() {
        DoorLog.shared.setRemoteSink(nil)
        let before = announcements(DoorLog.shared).count

        FoundryXLaunch.begin(bluetoothRestoration: true, diagnosticSink: Self.sink)
        FoundryXLaunch.begin(bluetoothRestoration: false, diagnosticSink: Self.sink)

        XCTAssertEqual(announcements(DoorLog.shared).count - before, 1,
                       "the launch bootstrap re-sinked an already-sinked log")
    }

    /// Idempotence is not inertness: pointing the log at a DIFFERENT relay must still work,
    /// or a build that changes its gateway silently keeps shipping to the old one.
    func testAChangedSinkIsInstalledAgain() {
        let log = DoorLog()

        log.setRemoteSink(Self.sink)
        log.setRemoteSink(Self.otherSink)

        XCTAssertEqual(log.remoteSinkURL, Self.otherSink)
        XCTAssertEqual(announcements(log).count, 2,
                       "a new relay URL is a new transport and says so")
        log.setRemoteSink(nil)
    }

    /// Clearing then re-installing must work — otherwise the idempotence guard would strand
    /// a log that was deliberately silenced.
    func testClearingTheSinkAllowsItToBeInstalledAgain() {
        let log = DoorLog()

        log.setRemoteSink(Self.sink)
        log.setRemoteSink(nil)
        XCTAssertNil(log.remoteSinkURL)
        log.setRemoteSink(Self.sink)

        XCTAssertEqual(log.remoteSinkURL, Self.sink)
        XCTAssertEqual(announcements(log).count, 2)
        log.setRemoteSink(nil)
    }

    // MARK: - Source gates: `App/` delegates the decision, it does not re-make it

    /// `swift test` cannot compile `App/`. This is the part of the invariant that has to be
    /// read off the file: the bootstrap that sinks the log must run BEFORE the restoration
    /// guard, not after it.
    func testTheAppDelegateSinksTheLogBeforeTheRestorationGuard() throws {
        let path = AppSourceTree.repoRoot
            .appendingPathComponent("App/FoundryXAppDelegate.swift")
        let code = AppSourceTree.code(of: try String(contentsOf: path, encoding: .utf8))

        // Non-vacuity: if the restoration guard moves, this gate must say so rather than pass
        // because it found nothing to be ordered against.
        guard let guardStart = code.range(of: "bluetoothCentrals") else {
            return XCTFail("App/FoundryXAppDelegate.swift no longer mentions `bluetoothCentrals`"
                               + " — this gate is checking a file that no longer holds the "
                               + "restoration guard it is about")
        }

        XCTAssertTrue(code[..<guardStart.lowerBound].contains("FoundryXLaunch.begin("),
                      "the launch bootstrap does not run before the CoreBluetooth restoration "
                          + "guard. iOS supplies `launchOptions[.bluetoothCentrals]` ONLY on a "
                          + "background restoration relaunch, so anything downstream of that "
                          + "guard never happens on a normal launch — which is exactly how "
                          + "DoorLog.shared shipped unsinked")
    }

    /// One sink, installed in one place. An App-side file that wires its own is the defect
    /// this whole fix is about, in its original form.
    func testNoAppSideFileWiresItsOwnRemoteSink() throws {
        XCTAssertEqual(try AppSourceTree.filesContaining("setRemoteSink("), [],
                       "an App-side file installs a diagnostic sink by hand. The launch "
                           + "bootstrap owns this, once per process, so that every log line "
                           + "goes to one place and the backstop timer survives")
    }

    /// The composition root must adopt the process-wide log rather than build a second one.
    /// A private instance is a log that the nineteen call sites holding none cannot reach.
    func testTheCompositionRootAdoptsTheProcessWideLog() throws {
        XCTAssertEqual(try AppSourceTree.filesContaining("DoorLog()"), [],
                       "an App-side file constructs its own DoorLog. Everything written to "
                           + "DoorLog.shared — the entire recorder surface — is invisible to "
                           + "it, and whichever instance got the sink is the only one that "
                           + "reaches the relay")
    }
}
