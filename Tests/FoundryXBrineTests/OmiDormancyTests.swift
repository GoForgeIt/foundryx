import XCTest
@testable import FoundryXKit

/// The "no Omi ⇒ dormant, absent Omi ⇒ off-main exponential backoff" contract.
///
/// Root cause it guards (build 271, field telemetry + wired-device syslog): with NO Omi
/// paired, the app still armed a CoreBluetooth SCAN via the AUTOMATIC auto-reconnect
/// path. A standing scan under our restore identifier made `bluetoothd` persist
/// "Central restoration data … servicesToScan" and let iOS relaunch the app ~every
/// 15–30s to service it; each relaunch re-ran the DeviceManager/spool setup on the main
/// thread — the ~1s block symbolicated to `OmiRestorationSpool.attach` (which is itself
/// trivial: the specialized `attach` at the crash offset is only the two inlined
/// `onState`/`onFrame` closure stores — the real cost was the didFinishLaunching setup
/// chain the sampler pinned to the nearest labeled frame).
///
/// These drive the PURE decision the DeviceManager now maps every CB callback onto
/// (`OmiReconnectPolicy.onAutoConnect` + `OmiBackoff` + exponential `onFailToConnect`),
/// with no CoreBluetooth — the same hostless-policy discipline as `OmiReconnectTests`.
/// The BLE wire itself stays on the `@ble-hardware` lane + the on-device plan.
final class OmiDormancyTests: XCTestCase {

    // MARK: - What each auto-connect action actually DOES (the oracle for "no work")

    /// Whether an action starts a BLE scan (the perpetual-scan waste we are killing).
    private func performsScan(_ a: OmiReconnectPolicy.AutoConnectAction) -> Bool {
        switch a {
        case .reacquireBackoff, .pairingScan: return true
        case .connectSaved, .dormant: return false
        }
    }
    /// Whether an action does ANY BLE work at all (scan or a pending connect). `.dormant`
    /// is the ONLY action that touches nothing — no scan, no connect, no restoration data.
    private func performsBLEWork(_ a: OmiReconnectPolicy.AutoConnectAction) -> Bool {
        a != .dormant
    }

    // MARK: - The core no-Omi decision

    func testNoSavedDeviceOnAutomaticPathIsDormant() {
        // THE fix: no saved device + automatic entry ⇒ do nothing. No scan, no connect,
        // so CoreBluetooth persists no restoration data and iOS never relaunches us.
        let action = OmiReconnectPolicy.onAutoConnect(hasSaved: false, handleCached: false,
                                                      userInitiated: false)
        XCTAssertEqual(action, .dormant)
        XCTAssertFalse(performsScan(action), "no-Omi automatic path must NOT scan")
        XCTAssertFalse(performsBLEWork(action), "no-Omi automatic path must do zero BLE work")
    }

    func testNoSavedDeviceUserGestureMayPairScan() {
        // A person tapping "Connect/Pair your Omi" DOES get a scan — but that is a
        // foreground, user-initiated, bounded gesture, not the automatic background loop.
        let action = OmiReconnectPolicy.onAutoConnect(hasSaved: false, handleCached: false,
                                                      userInitiated: true)
        XCTAssertEqual(action, .pairingScan)
    }

    func testSavedCachedHandleConnectsWithoutScanning() {
        // Paired + the OS handle is cached ⇒ an event-driven pending connect, NO scan.
        let action = OmiReconnectPolicy.onAutoConnect(hasSaved: true, handleCached: true,
                                                      userInitiated: false)
        XCTAssertEqual(action, .connectSaved)
        XCTAssertFalse(performsScan(action), "a cached saved device reconnects via pending connect, not a scan")
    }

    func testSavedButUncachedHandleBacksOff() {
        // Paired but the OS handle isn't cached ⇒ the backed-off reacquire scan (off-main,
        // bounded) — never a fixed tight loop.
        for userInitiated in [false, true] {
            let action = OmiReconnectPolicy.onAutoConnect(hasSaved: true, handleCached: false,
                                                          userInitiated: userInitiated)
            XCTAssertEqual(action, .reacquireBackoff)
        }
    }

    /// The behavioral proof: over a simulated interval of many AUTOMATIC wake events
    /// (central powered on, Bluetooth toggled off→on, a relaunch) with NO Omi paired, the
    /// reconnect path performs ZERO scans and ZERO BLE work every time — no periodic
    /// retry, nothing to hop the main actor about. (Against the pre-fix logic — which fell
    /// through to `startScan()` when nothing was saved — this loop would scan on every
    /// cycle, so this assertion is the red→green boundary.)
    func testManyAutomaticCyclesWithNoOmiDoZeroWork() {
        var scans = 0
        var bleWork = 0
        for _ in 0..<50 {   // ~50 wake cycles — a long idle stretch with no device present
            let action = OmiReconnectPolicy.onAutoConnect(hasSaved: false, handleCached: false,
                                                          userInitiated: false)
            if performsScan(action) { scans += 1 }
            if performsBLEWork(action) { bleWork += 1 }
        }
        XCTAssertEqual(scans, 0, "no-Omi idle must NEVER scan")
        XCTAssertEqual(bleWork, 0, "no-Omi idle must do zero BLE work over the whole interval")
    }

    // MARK: - Exponential backoff (paired but absent)

    func testReacquireBackoffIsExponentialAndCapped() {
        var b = OmiBackoff(base: 4, multiplier: 2, cap: 120)
        XCTAssertEqual(b.nextDelay(), 4)
        XCTAssertEqual(b.nextDelay(), 8)
        XCTAssertEqual(b.nextDelay(), 16)
        XCTAssertEqual(b.nextDelay(), 32)
        XCTAssertEqual(b.nextDelay(), 64)
        XCTAssertEqual(b.nextDelay(), 120, "capped at the ceiling")
        XCTAssertEqual(b.nextDelay(), 120, "stays capped, never runs away")
    }

    func testReacquireBackoffResetsAfterSuccess() {
        var b = OmiBackoff(base: 4, multiplier: 2, cap: 120)
        _ = b.nextDelay(); _ = b.nextDelay(); _ = b.nextDelay()
        XCTAssertEqual(b.attempt, 3)
        b.reset()
        XCTAssertEqual(b.attempt, 0)
        XCTAssertEqual(b.nextDelay(), 4, "a real connection restarts backoff from the base delay")
    }

    func testBackoffIsMonotonicNonDecreasing() {
        var b = OmiBackoff()
        var last: TimeInterval = -1
        for _ in 0..<20 {
            let d = b.nextDelay()
            XCTAssertGreaterThanOrEqual(d, last, "backoff must never shrink between attempts")
            last = d
        }
    }

    // MARK: - Failed-connect retry is now exponential (was a fixed 3s)

    func testFailedConnectFirstRetryPreservesLegacyTiming() {
        // Back-compat: attempt 0 (and the old no-attempt call) still yields the 3s first
        // retry the existing OmiReconnectTests assert — so the suite stays green.
        XCTAssertEqual(OmiReconnectPolicy.onFailToConnect(autoConnect: true),
                       .retryAfterDelay(OmiReconnectPolicy.failedConnectRetryDelay))
        XCTAssertEqual(OmiReconnectPolicy.onFailToConnect(autoConnect: true, attempt: 0),
                       .retryAfterDelay(3))
    }

    func testFailedConnectRetryGrowsExponentially() {
        XCTAssertEqual(OmiReconnectPolicy.onFailToConnect(autoConnect: true, attempt: 1), .retryAfterDelay(6))
        XCTAssertEqual(OmiReconnectPolicy.onFailToConnect(autoConnect: true, attempt: 2), .retryAfterDelay(12))
        XCTAssertEqual(OmiReconnectPolicy.onFailToConnect(autoConnect: true, attempt: 3), .retryAfterDelay(24))
    }

    func testFailedConnectRetryIsCapped() {
        // A flapping device must not push the delay to absurd values.
        XCTAssertEqual(OmiReconnectPolicy.onFailToConnect(autoConnect: true, attempt: 100),
                       .retryAfterDelay(OmiReconnectPolicy.failedConnectRetryCap))
    }

    func testFailedConnectStaysDownWhenSuspendedRegardlessOfAttempt() {
        for attempt in [0, 1, 5, 100] {
            XCTAssertEqual(OmiReconnectPolicy.onFailToConnect(autoConnect: false, attempt: attempt), .stayDown)
        }
    }
}
