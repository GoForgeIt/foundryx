// DeviceManager — the Omi connect/pairing flow: scan for Omi devices, let the
// user pick one, connect, PERSIST the choice, and auto-reconnect on launch / when
// it returns in range. It is also the live AudioFrameSource for the connected
// device (emits Opus frames), so the capture pipeline depends only on
// AudioFrameSource — the app injects this, tests inject ReplaySource.
//
// Connection ≠ capture: this owns the BLE link + its lifecycle; CaptureManager
// turns the resulting `.streaming` state into an ambient capture session. Modeled
// on Omi's omi-lib FriendManager / OmiBleManager + firmware transport.c.

import Foundation

/// What the connect UI shows.
public enum DeviceConnectionState: Equatable, Sendable {
    case poweredOff          // Bluetooth unavailable/off/unauthorized
    case idle                // powered on, not scanning, nothing connected
    case scanning
    case connecting(String)  // device name
    case connected(String)   // device name — ambient capture runs here
    case disconnected        // was connected, link dropped (auto-reconnecting)
}

/// What a tap on the consolidated capture header's Omi icon should do, given its
/// current presentation (Feature 3). Pure so the SwiftUI button and a brine test agree
/// on the scan toggle.
public enum OmiScanTapAction: Equatable, Sendable { case startScan, stopScan, none }

/// The consolidated capture header's Omi control as a pure presentation over the
/// connection state (Feature 3). The control is a small CIRCULAR icon when collapsed
/// (idle / disconnected) and EXPANDS into a wider pill while scanning / connecting /
/// connected. Keeping this a pure value (no SwiftUI) lets a brine test assert the
/// collapsed-icon ↔ expanded-pill state machine and the scan toggle.
public enum OmiScanPresentation: Equatable, Sendable {
    case collapsed                 // idle / disconnected: a small icon; tap → start a scan
    case scanning                  // expanded "Scanning…" pill + a subtle activity indicator
    case connecting(String)        // expanded "Connecting…" pill + activity
    case connected(String)         // distinct connected style (the header itself switches to
                                   // the ambient layout on connect, so this rarely shows here)
    case off                       // Bluetooth off / unavailable: a non-interactive icon

    /// Map the live connection state onto the control's presentation.
    public static func from(_ state: DeviceConnectionState) -> OmiScanPresentation {
        switch state {
        case .idle, .disconnected: return .collapsed
        case .scanning: return .scanning
        case .connecting(let n): return .connecting(n)
        case .connected(let n): return .connected(n)
        case .poweredOff: return .off
        }
    }

    /// The control is a WIDE pill (vs a small circle) while scanning / connecting / connected.
    public var isExpanded: Bool {
        switch self {
        case .collapsed, .off: return false
        case .scanning, .connecting, .connected: return true
        }
    }

    /// A subtle activity indicator spins while actively scanning / connecting.
    public var showsActivity: Bool {
        switch self {
        case .scanning, .connecting: return true
        case .collapsed, .connected, .off: return false
        }
    }

    /// The short label inside the expanded pill (nil when collapsed / off → icon only).
    public var label: String? {
        switch self {
        case .collapsed, .off: return nil
        case .scanning: return "Scanning…"
        case .connecting: return "Connecting…"
        case .connected(let n): return n
        }
    }

    /// What a tap does: start a scan from the collapsed icon, stop it while scanning,
    /// otherwise nothing (connecting / connected are driven by the BLE lifecycle).
    public var tapAction: OmiScanTapAction {
        switch self {
        case .collapsed: return .startScan
        case .scanning: return .stopScan
        case .connecting, .connected, .off: return .none
        }
    }
}

/// Pure auto-connect decision, testable WITHOUT CoreBluetooth (so the "stuck on
/// scanning, won't auto-connect" regression has real coverage). During a scan we
/// auto-connect to a discovered peripheral ONLY when it is the device we've already
/// paired (saved). First-time pairing stays an explicit tap so we never silently grab
/// a stranger's nearby Omi.
public enum OmiAutoConnect {
    public static func shouldAutoConnect(discoveredId: UUID, savedId: UUID?) -> Bool {
        guard let savedId else { return false }
        return discoveredId == savedId
    }
}

/// A discovered, connectable Omi.
public struct DiscoveredDevice: Identifiable, Equatable, Sendable {
    public let id: UUID        // CBPeripheral.identifier
    public let name: String
    public let rssi: Int
}

/// The remembered Omi shown on the dedicated device page (req 7): what we
/// auto-reconnect to, plus when we last had it connected.
public struct SavedOmi: Equatable, Sendable {
    public let id: UUID
    public let name: String
    public let lastConnected: Date?
}

#if canImport(CoreBluetooth)
import CoreBluetooth

public final class DeviceManager: NSObject, ObservableObject, AccountAudioSourceExposure, @unchecked Sendable {
    // AudioFrameSource — the connected device's Opus stream.
    public var onFrame: ((Data) -> Void)?
    public var onState: ((AudioSourceState) -> Void)?
    /// Which conversation a drop interrupted, PUSHED by the owner of capture state.
    ///
    /// WHY A PUSHED SNAPSHOT AND NOT A CLOSURE. The first shape of this seam was a
    /// synchronous `(() -> String?)?` read at window open. It could not be wired: the fact
    /// lives on `CaptureManager`, which is `@MainActor`, while `beginGapSyncWindow()` runs
    /// on `bleQueue` — so every legal implementation either needed an `await` (destroying
    /// the tag-AT-OPEN property this seam exists for) or `assumeIsolated` from the wrong
    /// queue (a data race). The seam compiled only because nothing had wired it yet.
    ///
    /// TIMING SEMANTICS. The main actor pushes a `Sendable` value whenever the answer
    /// changes; `DeviceManager` reads the last pushed value synchronously, under a lock,
    /// at the moment a window opens. The tag is therefore AT OPEN with respect to what the
    /// main actor has published, and the snapshot lags the main actor by the push only —
    /// never by a queue hop taken while the window is opening.
    public func setInterruptedCapture(_ captureId: String?) {
        interruptedCaptureLock.lock()
        interruptedCaptureSnapshot = captureId
        interruptedCaptureLock.unlock()
    }

    private let interruptedCaptureLock = NSLock()
    private var interruptedCaptureSnapshot: String?

    /// The snapshot as of now. Read on `bleQueue` when a window opens.
    var interruptedCaptureAtOpen: String? {
        interruptedCaptureLock.lock()
        defer { interruptedCaptureLock.unlock() }
        return interruptedCaptureSnapshot
    }
    /// Published once per gap-recovery window that followed an interrupted conversation.
    /// T5 renders it; nothing else may invent one.
    ///
    /// IT CARRIES THE ACCOUNT, and that is load-bearing (hazard N7). This callback is NOT
    /// gated by the account-exposure close while `onState` IS — both are published from the
    /// same `didDisconnect` after the exposure has been claimed closed, and only the state is
    /// suppressed. A consumer handed a bare outcome cannot notice, and would render one
    /// account's recording history into whichever account is on screen. `GapRecoveryReport`
    /// makes the scope impossible to skip; `GapRecoveryRendering.decide` is what T5 does
    /// with it.
    public var onGapRecoveryOutcome: ((GapRecoveryReport) -> Void)?

    /// The account whose audio a gap window is about, PUSHED by the composition root — the
    /// same shape as `setInterruptedCapture`, and for the same two reasons.
    ///
    /// IT IS A SNAPSHOT AND NOT A LOOKUP. A window opens on `bleQueue`, and
    /// `CaptureAccountScope.currentAccountBinding()` takes a process-wide lock, reads the
    /// durable container, and consults the shared admission registry on disk. Calling that
    /// from the radio's queue makes the transport wait on account bookkeeping — measured, not
    /// feared: doing it here stalled the reconnect seam suite past its 60s precondition bound
    /// under concurrent load, while the same suite ran in 3.5s without it.
    ///
    /// AND `nil` IS FAIL-CLOSED, not a hole. An unset scope makes `GapRecoveryRendering`
    /// WITHHOLD the outcome with a stated reason rather than render it into whatever account
    /// is on screen. `DeviceCompositionRootGateTests` is what holds the production wiring in
    /// place, because `App/` is compiled by no test target.
    public func setAccountScopeForGapOutcomes(_ scope: String?) {
        accountScopeLock.lock()
        accountScopeSnapshot = scope
        accountScopeLock.unlock()
    }

    /// KEEP THE SNAPSHOT CURRENT — push once now, and again on every identity transition.
    ///
    /// WHY A ONE-SHOT PUSH IS NOT ENOUGH (review round 11, M3). `setAccountScopeForGapOutcomes`
    /// is deliberately a snapshot, and `RootView` took it ONCE, in `init`, from a `let`. But
    /// `DeviceManager` is a PROCESS SINGLETON that outlives the view tree that built it:
    ///
    ///   * a launch while signed out pushes `nil`, and nothing pushes again when the person
    ///     signs in — so every gap outcome for the rest of the process names no account and is
    ///     withheld from its own owner, silently, because withholding is the fail-closed
    ///     default;
    ///   * a sign-out tears the tab tree down WITHOUT rebuilding it, so the previous owner's
    ///     scope stays on the manager and the next window opened — by nobody, or by the next
    ///     person — is stamped with the account that left.
    ///
    /// STILL A PUSH, NOT A LOOKUP. The reason the read is a snapshot is that resolving a
    /// binding takes a process-wide lock and consults the on-disk admission registry, and doing
    /// that from `bleQueue` when a window opens makes the transport wait on account
    /// bookkeeping (measured: it stalled the reconnect seam suite past its 60s bound). This
    /// resolves on the identity notification's own thread instead, which is never `bleQueue`.
    ///
    /// SELF-INSTALLED, not left to the composition root. An observer a root has to remember to
    /// install is exactly the shape of wiring this finding was about.
    ///
    /// IT TAKES NO RESOLVER, AND THAT IS THE POINT (review round 12, M12-1). This used to
    /// carry `resolve:` and `center:` defaults that no caller in the repo — production or
    /// test — ever supplied. A parameter nobody needs is a hole a regression walks through:
    /// `followAccountScopeChanges(resolve: { nil })` in the composition root satisfies every
    /// source-text search for this wiring while making every gap outcome nameless, and it
    /// SURVIVED the whole suite. There is now nothing to pass, so that mutation does not
    /// compile — which is the same enforcement `resolveDeviceContext(recording:)` uses, and
    /// the compile phase of `scripts/ci-gates.sh` is what runs it. Tests drive the real
    /// resolver through `CaptureAccountScope`'s own test seams, which is what the N7/M3
    /// scenarios in `device-rendered-surface.feature` already do.
    ///
    /// `startingFrom` IS A HANDOVER, NOT A CLAIM (review round 12, L12-3).
    /// `CaptureAccountScope.currentAccountBinding()` takes a process-wide lock, reads the
    /// durable container, consults the on-disk admission registry AND publishes the widget
    /// owner across processes. `MainTabs.init` — which runs on every body pass of the view
    /// that builds it, not once — had already paid for exactly that answer one `let` earlier
    /// and then made this method pay for it again. A caller that has the answer hands it
    /// over; a caller that does not passes nothing and this resolves it. `nil` therefore
    /// means "I have nothing for you", never "there is no account": it falls through to the
    /// real resolver, so no call site can make the scope vacuous by omission. Only the FIRST
    /// push can be handed over — every later one comes from the notification, on its own
    /// thread, freshly resolved.
    public func followAccountScopeChanges(startingFrom handedOver: String? = nil) {
        let center = NotificationCenter.default
        accountScopeLock.lock()
        if let existing = accountScopeObserver { center.removeObserver(existing) }
        accountScopeObserver = center.addObserver(
            forName: CaptureAccountScope.identityDidChangeNotification,
            object: nil,
            // `nil` queue: delivered synchronously on the poster's thread. The setter is
            // lock-guarded, and hopping to main would leave a window in which the manager
            // still answers for the account that just left.
            queue: nil
        ) { [weak self] _ in
            self?.setAccountScopeForGapOutcomes(Self.resolveAccountScope())
        }
        accountScopeLock.unlock()
        setAccountScopeForGapOutcomes(handedOver ?? Self.resolveAccountScope())
    }

    /// The one resolution of "which account is this", used for the first push and every
    /// notification-driven one after it.
    private static func resolveAccountScope() -> String? {
        CaptureAccountScope.currentAccountBinding()?.scope
    }

    /// Stop following. A `DeviceManager` is a process singleton in production, so this never
    /// runs there — but every test that constructs one used to leave a live block registered
    /// on `NotificationCenter.default` for the life of the test process (review round 12,
    /// L12-3). Harmless per block and unbounded in aggregate; a manager that is gone should
    /// not still be listening.
    private func stopFollowingAccountScopeChanges() {
        accountScopeLock.lock()
        let observer = accountScopeObserver
        accountScopeObserver = nil
        accountScopeLock.unlock()
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    deinit { stopFollowingAccountScopeChanges() }

    private let accountScopeLock = NSLock()
    private var accountScopeSnapshot: String?
    private var accountScopeObserver: NSObjectProtocol?

    /// The snapshot as of now. Read on `bleQueue` when a window opens.
    var accountScopeAtGapOpen: String? {
        accountScopeLock.lock()
        defer { accountScopeLock.unlock() }
        return accountScopeSnapshot
    }

    /// Fired when the Omi hardware button is DOUBLE-clicked (wired to pause/resume the
    /// current recording). Detected from the Omi button-trigger characteristic — see
    /// `OmiUUID.buttonService`. Only fires if the paired firmware exposes that service.
    public var onButtonDoubleClick: (() -> Void)?
    /// Timestamp of the last button press, for the two-presses-within-window fallback
    /// (used when the firmware emits per-press events rather than a typed DOUBLE_TAP).
    private var lastButtonPressAt: Date?

    // UI-facing state (published on main).
    @Published public private(set) var connectionState: DeviceConnectionState = .poweredOff
    @Published public private(set) var discovered: [DiscoveredDevice] = []
    /// The remembered Omi (device page). nil until the user first connects one.
    @Published public private(set) var saved: SavedOmi?
    /// The connected device's battery level (0…100) read from the standard BLE Battery
    /// Service. `nil` when disconnected OR the device doesn't expose a battery — the UI
    /// then shows no battery rather than a fake value.
    @Published public private(set) var batteryLevel: Int?

    /// True when the connected device's battery is low enough to warrant a warning tint.
    public var isBatteryLow: Bool { (batteryLevel ?? 100) < 20 }

    private func setBatteryLevel(_ level: Int?) {
        let clamped = level.map { max(0, min(100, $0)) }
        DispatchQueue.main.async {
            guard self.batteryLevel != clamped else { return }   // skip-equal: no redundant objectWillChange
            self.batteryLevel = clamped
        }
    }

    private let log: DoorLog?
    private let bleQueue = DispatchQueue(label: "foundryx.device-ble")
    /// How the central is obtained. The app never supplies one; the S04 acceptance proof
    /// supplies a fake that drives the SAME sink on the SAME queue, which is the only way
    /// the discovery half of the reconnect chain is drivable at all (`CBPeripheral`,
    /// `CBService` and `CBCharacteristic` are all `NS_UNAVAILABLE`-init).
    private let makeCentral: BLECentralFactory
    private var central: BLECentral?
    private var peripheral: BLEPeripheral?
    private let headerBytes = 3   // Omi packet header [seq:2][index:1]
    private var audioNotifs = 0   // diagnostics: raw audio-char notifications seen (bleQueue only)

    // MARK: state restoration + always-reconnect

    /// CBCentralManagerOptionRestoreIdentifierKey — with the bluetooth-central
    /// background mode, iOS RELAUNCHES the app in the background when a pending
    /// connect completes after the app was terminated, delivering the peripheral
    /// back through `willRestoreState`. The AppDelegate re-creates this manager
    /// (same identifier) on such a launch — see FoundryXAppDelegate.
    public static let restoreIdentifier = "foundryx.omi.central"

    /// A peripheral handed back by `willRestoreState`, held until the central
    /// reports poweredOn (nothing may be issued before that). bleQueue only.
    private var restoredPeripheral: BLEPeripheral?

    /// The last state handed to `onState` — so a late-attaching consumer (the real
    /// CaptureManager taking over from the restoration spool) can be replayed the
    /// current truth instead of waiting for the next transition. Lock-guarded:
    /// emissions come from BOTH the bleQueue (CB callbacks) and the main thread
    /// (suspend/forget/disconnect).
    private let lastStateLock = NSLock()
    private var lastSourceState: AudioSourceState?
    private let audioExposureLock = NSLock()
    private let audioExposureEmissions = DispatchGroup()
    private var audioExposureClosed = false

    private func emitSourceState(_ s: AudioSourceState, terminal: Bool = false) {
        audioExposureLock.lock()
        let closed = audioExposureClosed
        if terminal || !closed { audioExposureEmissions.enter() }
        audioExposureLock.unlock()
        guard terminal || !closed else { return }
        defer { audioExposureEmissions.leave() }
        lastStateLock.lock(); lastSourceState = s; lastStateLock.unlock()
        onState?(s)
    }

    private func emitAudioFrame(_ frame: Data) {
        audioExposureLock.lock()
        let closed = audioExposureClosed
        if !closed { audioExposureEmissions.enter() }
        audioExposureLock.unlock()
        guard !closed else { return }
        defer { audioExposureEmissions.leave() }
        onFrame?(frame)
    }

    /// Re-emit the current source state to the (possibly just-reassigned) `onState`
    /// consumer. Used at CaptureManager takeover after a background restoration
    /// launch: the Omi may ALREADY be streaming, and without a replay the new
    /// consumer would never see `.streaming` and never open a session.
    public func replayState() {
        bleQueue.async { [weak self] in
            guard let self else { return }
            self.lastStateLock.lock()
            let s = self.lastSourceState
            self.lastStateLock.unlock()
            if let s { self.emitSourceState(s) }
        }
    }

    // MARK: shared instance (restoration + app share ONE central)

    private static let sharedLock = NSLock()
    private nonisolated(unsafe) static var sharedInstance: DeviceManager?   // sharedLock-guarded

    /// The process-wide DeviceManager. Two creation paths must converge on ONE
    /// instance (two centrals with the same restore identifier are undefined):
    /// the AppDelegate's bluetooth-restoration bootstrap and the UI's MainTabs.
    /// First caller's log wins (both wire the same remote diag sink).
    public static func shared(log: DoorLog? = nil) -> DeviceManager {
        sharedLock.lock(); defer { sharedLock.unlock() }
        if let s = sharedInstance { return s }
        let s = DeviceManager(log: log)
        sharedInstance = s
        return s
    }

    /// The shared instance IF one was ever created — never creates. For lifecycle
    /// hooks (sign-out suspend) that must not conjure a central just to stop it.
    public static func sharedExisting() -> DeviceManager? {
        sharedLock.lock(); defer { sharedLock.unlock() }
        return sharedInstance
    }

    // MARK: offline-cache (ring) sync state — bleQueue only

    private var audioChar: BLECharacteristic?
    private var storageDataChar: BLECharacteristic?
    private var storageControlChar: BLECharacteristic?
    private var gapSync: OmiOfflineSyncEngine?
    /// The current gap-recovery window, tagged at open (track 20260725T2306, T3). bleQueue only.
    private var gapWindow: GapRecoveryWindow?
    /// True from connect until the storage-sync decision resolves (service absent,
    /// unsupported, finished, failed). While true, LIVE audio frames are held so
    /// recovered gap audio lands in the WAL first — recorded order.
    private var gapSyncHolding = false
    private var liveHold: [Data] = []
    /// ~5 min of Omi audio at ~100 pkts/s — beyond this, release order rather than memory.
    private let liveHoldMaxFrames = 30_000
    /// One-shot deadlines (NOT poll loops): sync must decide/progress or release.
    private let gapSyncDecisionTimeout: TimeInterval = 10
    private let gapSyncStallTimeout: TimeInterval = 8
    private let gapSyncOverallBudget: TimeInterval = 180
    /// Bumped whenever a sync window opens/closes so stale one-shot deadlines no-op.
    private var gapSyncGeneration: UInt64 = 0
    /// When false the link is USER-SUSPENDED (the Omi was toggled OFF on the device
    /// page): we drop it AND stop auto-reconnecting until re-enabled, so a disabled Omi
    /// truly leaves the capture surface instead of silently reconnecting itself. The
    /// saved pairing is kept so re-enabling reconnects hands-free.
    private var autoConnect = true

    // MARK: connect-intent + backoff (the "no Omi ⇒ dormant, absent Omi ⇒ backoff" state)

    /// Set by a USER pairing gesture (startScan/connectOrPair) that had to power the
    /// central first — consumed once on the next `.poweredOn` so the AUTOMATIC path stays
    /// dormant while an explicit pairing scan still runs. Cross-thread (set on main, read
    /// on bleQueue) under the same `@unchecked Sendable` convention as `autoConnect`.
    private var pendingUserScan = false
    /// Generation token bounding a pairing scan (main only) — a scan that finds nothing
    /// auto-stops after `scanWindow` so it never becomes a perpetual background scan (the
    /// standing scan that persisted CB restoration data and woke the app ~every 15–30s).
    private var scanGeneration: UInt64 = 0
    private let scanWindow: TimeInterval = 30
    /// Exponential backoff for the saved-but-uncached reacquire scan (bleQueue only).
    private var reacquireBackoff = OmiBackoff()
    private var reacquireScheduled = false          // bleQueue only
    private let reacquireScanWindow: TimeInterval = 6
    /// Consecutive failed-connect attempts (bleQueue only) → exponential retry backoff.
    private var failToConnectAttempts = 0

    // Internal, not private, so the account-scoped device store's LEGACY MIGRATION can
    // name the very same keys instead of re-typing the literals and drifting from them
    // (track 20260725T2306, T2).
    static let savedKey = "foundryx.omi.peripheral-id"
    static let savedNameKey = "foundryx.omi.peripheral-name"
    static let savedDateKey = "foundryx.omi.last-connected"

    public init(log: DoorLog? = nil,
                makeCentral: @escaping BLECentralFactory = CoreBluetoothCentral.make) {
        self.log = log
        self.makeCentral = makeCentral
        super.init()
        saved = Self.loadSaved()
    }

    /// AudioFrameSource.start() = power on + begin the connect flow (auto-reconnect
    /// the saved device, else scan). RE-ENTRANT: when the central is already powered on
    /// and we're not currently linked, this RE-INITIATES the connect flow. Previously
    /// start() only created the central and otherwise no-oped, so re-selecting /
    /// re-enabling the Omi after a stop never reconnected (the user had to manually
    /// scan) — a primary "zero frames / stuck" cause.
    public func start() {
        audioExposureLock.lock()
        let closed = audioExposureClosed
        audioExposureLock.unlock()
        guard !closed else { return }
        autoConnect = true
        // No saved device ⇒ nothing to reconnect to. Stay FULLY DORMANT: don't create a
        // central, don't scan. A central carrying our restore identifier plus a standing
        // scan / pending connect is exactly what persisted CB state-restoration data and
        // made iOS relaunch the app ~every 15–30s (the ~1s main-thread block the field
        // telemetry symbolicated to OmiRestorationSpool.attach) — for a device that will
        // never appear. First-time pairing is the explicit startScan()/connectOrPair()
        // gesture, which powers the central on demand. This method is called broadly and
        // AUTOMATICALLY (screen onAppear via CaptureManager.startSource, source-switch,
        // resume), so it must never itself arm a scan.
        guard Self.hasSavedDevice else { setState(.idle); return }
        guard let c = central else {
            ensureCentral()   // the connect flow resumes once the central reports .poweredOn
            return
        }
        guard c.managerState == .poweredOn else { return }
        switch connectionState {
        case .connected, .connecting: break          // already linked — nothing to do
        default: autoReconnect(userInitiated: false) // re-initiate the saved-device reconnect
        }
    }

    /// Create the shared central. Restore identifier ⇒ iOS relaunches us in the
    /// background when a pending connect completes even after the app was killed
    /// (willRestoreState path). iOS-only: macOS (the @ble-hardware test host) has no CB
    /// state restoration.
    private func ensureCentral() {
        guard central == nil else { return }
        #if os(iOS)
        central = makeCentral(self, bleQueue, Self.restoreIdentifier)
        #else
        // macOS has no CoreBluetooth state restoration — no restore identifier to give.
        central = makeCentral(self, bleQueue, nil)
        #endif
    }

    /// AudioFrameSource.stop() = drop the link (capture ends; we keep the saved id).
    public func stop() { disconnect() }

    /// Stop the BLE producer on its owning executor and acknowledge only after
    /// queued exposure work can no longer publish frames to the old consumer.
    public func closeAudioExposure() async -> AccountExposureCloseResult {
        guard claimAudioExposureClose() else { return .alreadyClosed }

        return await withCheckedContinuation { continuation in
            bleQueue.async {
                self.autoConnect = false
                self.gapSyncGeneration &+= 1
                self.gapSync = nil
                self.gapSyncHolding = false
                self.liveHold.removeAll()
                self.central?.stopScan()
                if let peripheral = self.peripheral {
                    self.central?.cancelPeripheralConnection(peripheral)
                }
                self.peripheral = nil
                self.audioExposureEmissions.wait()
                self.emitSourceState(.stopped, terminal: true)
                continuation.resume(returning: .closed)
            }
        }
    }

    private func claimAudioExposureClose() -> Bool {
        audioExposureLock.lock()
        defer { audioExposureLock.unlock() }
        guard !audioExposureClosed else { return false }
        audioExposureClosed = true
        return true
    }

    /// Enable/disable the Omi as a capture source (device-page toggle). Disabling drops
    /// the link AND stops auto-reconnect, so a toggled-off Omi leaves the capture
    /// surface; enabling resumes the hands-free connect flow. The saved pairing persists.
    public func setEnabled(_ on: Bool) { if on { start() } else { suspend() } }

    /// Whether a device has ever been paired (a saved Omi exists). Public so the
    /// AppDelegate's background-restoration bootstrap can bail BEFORE creating a central
    /// when there's nothing to reconnect to, and so the connect flow stays dormant with
    /// no Omi.
    public static var hasSavedDevice: Bool { loadSaved() != nil }

    /// The capture-page "Connect your Omi" affordance: reconnect a remembered device,
    /// else begin a bounded, user-initiated pairing scan. (`start()` alone is dormant
    /// with no saved device, so a first-time user needs this explicit scan.)
    public func connectOrPair() {
        if Self.hasSavedDevice { reconnect() } else { startScan() }
    }

    /// Stop a user-initiated pairing scan (ONLY while actually scanning) — call when the
    /// pairing UI is dismissed so an abandoned scan never keeps the radio (and CB
    /// restoration) armed. A no-op mid-connect / connected / dormant.
    public func stopScanIfScanning() {
        if case .scanning = connectionState { stopScan() }
    }

    /// User-suspend: drop the link, keep the saved device, and DON'T auto-reconnect
    /// (until `start()`/`setEnabled(true)`). Distinct from `disconnect()`, which keeps
    /// auto-reconnect armed for a transient drop.
    public func suspend() {
        autoConnect = false
        central?.stopScan()
        if let p = peripheral { central?.cancelPeripheralConnection(p) }
        peripheral = nil
        setDiscovered([])
        setState(.idle)
        emitSourceState(.stopped)
    }

    // MARK: connect UI API

    public func startScan() {
        // A USER pairing gesture. Ensure the central exists (a first-time pair can hit
        // this before anything else powered it on — start() is dormant with no saved
        // device), then scan once powered on.
        guard let c = central else { pendingUserScan = true; ensureCentral(); return }
        guard c.managerState == .poweredOn else { pendingUserScan = true; return }
        setDiscovered([])
        setState(.scanning)
        // NO SERVICE FILTER. THIS IS THE LINE THAT MADE THE BRAND-FREE LIST OMI-ONLY.
        //
        // The user-initiated pairing scan asked for `[OmiUUID.audioService]`, so a
        // CoreBluetooth scan only ever reported peripherals advertising ONE VENDOR'S audio
        // service. A stored-file recorder advertises no such service and therefore could not
        // answer — the "one list, no brand" connect sheet was Omi-only by construction, and
        // no amount of work further down the adoption chain could have put a Pocket in it.
        //
        // `nil` is what design §3.1 actually describes: *"the scan list below shows no class,
        // no battery, and no capabilities"* — whatever answered, named by what it broadcasts,
        // with the app admitting it cannot tell what any of them are until it connects.
        //
        // OMI PAIRING IS UNAFFECTED, and that is a property of the code below rather than a
        // hope: the auto-connect arm in `didDiscover` matches on the SAVED PERIPHERAL UUID
        // (`OmiAutoConnect.shouldAutoConnect`), never on the advertised service, so widening
        // the scan can only add candidates to it. `runReacquireScan()` — the AUTOMATIC,
        // background reacquire for an already-saved Omi — deliberately keeps its filter: it
        // is looking for one specific known device, and an unfiltered background scan is a
        // battery and privacy cost paid for nothing.
        c.scanForPeripherals(withServices: nil, options: nil)
        // BOUND it: a scan that finds nothing must NOT run forever — a perpetual scan is
        // what persisted CB restoration data and woke the app. Auto-stop after the window
        // (a later scan bumps the generation so this stale timeout no-ops).
        scanGeneration &+= 1
        let gen = scanGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + scanWindow) { [weak self] in
            guard let self, self.scanGeneration == gen else { return }
            if case .scanning = self.connectionState {
                self.central?.stopScan()
                self.setDiscovered([])
                self.setState(.idle)
                self.log?.info("Omi: pairing scan found nothing within \(Int(self.scanWindow))s — stopped")
            }
        }
    }

    /// Stop an in-progress scan and collapse back to idle (the consolidated header's
    /// Omi icon returns to its small circle). Clears any discovered results.
    public func stopScan() {
        central?.stopScan()
        setDiscovered([])
        setState(.idle)
    }

    public func connect(_ device: DiscoveredDevice) {
        autoConnect = true
        // H1: THE RE-PAIR PATH IS THE ONE THAT MATTERS. `forget()` erases the three
        // device-global keys, so by the time the user pairs again `reconnect()` has no saved
        // identity to clear and `Self.loadSaved()` is nil — a re-paired device would stay
        // permanently excluded by `RecordingDeviceActivation`. Pairing THIS device is the
        // user gesture that revokes the earlier detach, so it is recorded here.
        //
        // Deliberately BEFORE the transport guard: the flag records USER INTENT, not radio
        // state. A pairing tap while the central is not yet ready is still the intent, and
        // leaving the store detached until the radio happens to be ready is exactly the
        // silent staleness this fixes.
        // T5: THE STORE GOES LIVE HERE. `recordUserReconnect` only ever cleared a detach on a
        // record that already existed, so a first-ever pair left the account-scoped store
        // empty — it remembered the devices a user had thrown away and none of the ones they
        // kept, and `RecordingDeviceActivation` therefore had nothing to choose from. Pairing
        // is the gesture that means "remember this one", so it upserts and selects.
        // A device that advertised no name is remembered under the brand-free name the scan
        // list showed it under, not under an empty string.
        let pairedName = device.name.isEmpty
            ? RecordingDeviceConnectPresentation.unnamedDeviceName
            : device.name
        logDetachOutcome(
            RecordingDeviceStore.recordUserPair(
                identity: RecordingDeviceIdentity(shape: .bleStream,
                                                  hardwareToken: device.id.uuidString),
                displayName: pairedName),
            gesture: "pair")
        guard let c = central,
              let p = c.retrievePeripherals(withIdentifiers: [device.id]).first
                  ?? discoveredPeripherals[device.id] else { return }
        c.stopScan()
        bind(p)
        setSaved(device.id, name: p.name ?? pairedName)
        setState(.connecting(p.name ?? pairedName))
        c.connect(p, options: nil)
    }

    /// Manual reconnect (device page, req 7): re-run the saved-device connect, or
    /// fall back to a scan when there's nothing saved / it's out of range.
    public func reconnect() {
        autoConnect = true
        // One of the two USER gestures that clear an explicit detach; the other is
        // `connect(_:)`, the re-pair path (track 20260725T2306, T2). No automatic path
        // reaches either. This arm covers a device that is still SAVED — after `forget()`
        // there is nothing saved here, which is why the re-pair arm exists.
        if let saved = Self.loadSaved() {
            logDetachOutcome(
                RecordingDeviceStore.recordUserReconnect(
                    identity: RecordingDeviceIdentity(shape: .bleStream,
                                                      hardwareToken: saved.id.uuidString)),
                gesture: "reconnect")
        }
        guard let c = central, c.managerState == .poweredOn else { start(); return }
        autoReconnect(userInitiated: true)
    }

    /// Drop the current link AND forget the saved device (user-initiated).
    public func forget() {
        autoConnect = false
        // Persist the EXPLICIT detach into the account-scoped store BEFORE the
        // device-global keys go, so a relaunch cannot re-arm a device the user detached
        // (track 20260725T2306, T2). The store returns a typed outcome and it is LOGGED —
        // `RecordingDeviceStore.current()` genuinely returns nil on the fail-closed paths
        // (blocked deletion admission, unresolvable durable container), and an explicit
        // user detach that could not be persisted must not vanish without a trace.
        if let saved = Self.loadSaved() {
            logDetachOutcome(
                RecordingDeviceStore.recordUserDetach(
                    identity: RecordingDeviceIdentity(shape: .bleStream,
                                                      hardwareToken: saved.id.uuidString),
                    displayName: saved.name),
                gesture: "forget")
        }
        central?.stopScan()
        if let p = peripheral { central?.cancelPeripheralConnection(p) }
        peripheral = nil
        UserDefaults.standard.removeObject(forKey: Self.savedKey)
        UserDefaults.standard.removeObject(forKey: Self.savedNameKey)
        UserDefaults.standard.removeObject(forKey: Self.savedDateKey)
        DispatchQueue.main.async { self.saved = nil }
        setState(.idle)
        emitSourceState(.stopped)
    }

    /// Report what the account-scoped device store actually did with a user gesture.
    /// A failure here is a LOST USER DECISION, so it logs at error level; a no-op reconnect
    /// (nothing remembered under this account) is ordinary and logs at info.
    ///
    /// THE SCOPE NEVER APPEARS HERE. `DoorLog` ships to a remote diagnostic sink in cleartext
    /// (see `RecordingDeviceLogRedaction`), and `acct-<hash>` is a stable per-account
    /// correlation token. M1's requirement is that a lost user decision be LOUD, which the
    /// error level provides on its own; naming the account buys nothing and costs the
    /// property `DeviceRefDerivation` was built to protect. The error arm is redacted rather
    /// than trusted, because a Cocoa failure names the containing folder by itself.
    private func logDetachOutcome(_ outcome: RecordingDeviceDetachOutcome, gesture: String) {
        switch outcome {
        case .recorded:
            log?.info("device \(gesture): recorded")
        case .noMatchingRecord:
            log?.info("device \(gesture): no remembered device to update")
        case .unavailable(let reason):
            log?.error("device \(gesture): NOT PERSISTED — "
                + RecordingDeviceLogRedaction.redactingAccountScopes(reason))
        }
    }

    /// Drop the current link but keep the saved device (so we auto-reconnect).
    public func disconnect() {
        if let p = peripheral { central?.cancelPeripheralConnection(p) }
        emitSourceState(.stopped)
    }

    // MARK: internals

    private var discoveredPeripherals: [UUID: BLEPeripheral] = [:]   // bleQueue only

    private func bind(_ p: BLEPeripheral) { peripheral = p; p.routeEventsToSink() }

    /// The auto-reconnect entry. `userInitiated` distinguishes an explicit "Connect"
    /// gesture (may pair-scan when nothing is saved) from the AUTOMATIC path (central
    /// powered on, BT toggled on, launch), which must stay DORMANT with no saved device —
    /// the whole point of the no-Omi fix. See `OmiReconnectPolicy.onAutoConnect`.
    private func autoReconnect(userInitiated: Bool) {
        // Already linked (or a pending connect is standing)? Leave it alone — a
        // second connect() on top of a restored pending connect is redundant.
        if let p = peripheral, p.linkState == .connected || p.linkState == .connecting { return }
        guard let c = central else { return }
        let savedId = UserDefaults.standard.string(forKey: Self.savedKey).flatMap(UUID.init(uuidString:))
        let cached = savedId.flatMap { c.retrievePeripherals(withIdentifiers: [$0]).first }
        switch OmiReconnectPolicy.onAutoConnect(hasSaved: savedId != nil,
                                                handleCached: cached != nil,
                                                userInitiated: userInitiated) {
        case .connectSaved:
            guard let p = cached else { setState(.idle); return }
            log?.info("Omi: auto-reconnecting saved device \(p.name ?? "?")")
            bind(p)
            setState(.connecting(p.name ?? "Omi"))
            c.connect(p, options: nil)   // event-driven pending connect — no scan, no poll
        case .reacquireBackoff:
            // Saved, but the OS handle isn't cached yet — a bounded, exponentially-backed-
            // off reacquire scan OFF the main thread, NOT a tight loop.
            setState(.idle)
            scheduleReacquireScan()
        case .pairingScan:
            // A user gesture with nothing saved — a bounded pairing scan.
            setState(.idle)
            startScan()
        case .dormant:
            // No saved device on the automatic path — do NOTHING (the no-Omi fix). No
            // scan, no pending connect, so no CB restoration data, so no relaunch churn.
            setState(.idle)
        }
    }

    // MARK: reacquire backoff — saved device, OS handle not yet cached (bleQueue only)

    /// Schedule a bounded, exponentially-backed-off reacquire scan for a SAVED device
    /// whose OS peripheral handle CoreBluetooth hasn't cached yet. All on the bleQueue —
    /// never main-thread, never a tight loop. No-op unless a device is saved and enabled.
    private func scheduleReacquireScan() {
        bleQueue.async { [weak self] in
            guard let self, self.autoConnect, Self.hasSavedDevice, !self.reacquireScheduled else { return }
            self.reacquireScheduled = true
            let delay = self.reacquireBackoff.nextDelay()
            self.log?.info("Omi: saved device handle uncached — reacquire scan in \(Int(delay))s")
            self.bleQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.runReacquireScan()
            }
        }
    }

    private func runReacquireScan() {   // bleQueue only
        reacquireScheduled = false
        guard autoConnect, Self.hasSavedDevice, let c = central, c.managerState == .poweredOn else { return }
        if let p = peripheral, p.linkState == .connected || p.linkState == .connecting { reacquireBackoff.reset(); return }
        // Handle may have appeared → prefer a direct (event-driven) pending connect.
        if let idStr = UserDefaults.standard.string(forKey: Self.savedKey),
           let id = UUID(uuidString: idStr),
           let p = c.retrievePeripherals(withIdentifiers: [id]).first {
            reacquireBackoff.reset()
            bind(p); setState(.connecting(p.name ?? "Omi")); c.connect(p, options: nil)
            return
        }
        // Still uncached: a BOUNDED scan window; didDiscover auto-connects the saved id
        // (OmiAutoConnect). Stop after the window; if still not connected, back off again.
        setState(.scanning)
        c.scanForPeripherals(withServices: [OmiUUID.audioService], options: nil)
        let attemptAtScan = reacquireBackoff.attempt
        bleQueue.asyncAfter(deadline: .now() + reacquireScanWindow) { [weak self] in
            guard let self, self.reacquireBackoff.attempt == attemptAtScan else { return }
            if let p = self.peripheral, p.linkState == .connected || p.linkState == .connecting { return }
            self.central?.stopScan()
            self.setState(.idle)
            self.scheduleReacquireScan()   // back off further and retry
        }
    }

    // MARK: offline-cache (ring) sync plumbing — bleQueue only

    /// Open the live-audio order hold. Runs from didConnect (and the restored-
    /// connected path) BEFORE service discovery, so no live frame can slip ahead of
    /// recovered gap audio. A one-shot decision deadline releases the hold if the
    /// storage service / subscription never materializes.
    func beginGapSyncWindow() {
        // The window state is bleQueue-confined. Asserting it here is what makes the test
        // seam's queue hop load-bearing instead of decorative.
        dispatchPrecondition(condition: .onQueue(bleQueue))
        gapSyncHolding = true
        liveHold.removeAll()
        // Tag AT OPEN. Asking later would ask after the reconnect has already changed the
        // capture state the question is about.
        gapWindow = GapRecoveryWindow(interruptedCaptureId: interruptedCaptureAtOpen,
                                      accountScopeAtOpen: accountScopeAtGapOpen)
        let generationAtStart = gapSyncGeneration
        bleQueue.asyncAfter(deadline: .now() + gapSyncDecisionTimeout) { [weak self] in
            guard let self, self.gapSyncGeneration == generationAtStart, self.gapSyncHolding,
                  self.gapSync == nil else { return }
            self.log?.warn("Omi: storage sync never started within \(Int(self.gapSyncDecisionTimeout))s — releasing live audio")
            self.closeGapWindow(.decisionDeadlinePassed)
            self.endGapSyncWindow(flush: true)
        }
    }

    /// The ONE place a gap-recovery outcome reaches anybody. Every close path calls this
    /// with its cause; the window itself decides whether there is anything to say, so no
    /// call site can invent an outcome and a second close is a no-op by construction.
    func closeGapWindow(_ cause: GapRecoveryWindow.Close) {
        guard var window = gapWindow else { return }
        let outcome = window.close(cause)
        gapWindow = window
        guard let outcome else { return }
        onGapRecoveryOutcome?(GapRecoveryReport(outcome: outcome,
                                                accountScope: window.accountScopeAtOpen))
    }

    /// Close the hold: optionally flush the held live frames (in arrival order)
    /// into the normal frame path, and drop the engine.
    func endGapSyncWindow(flush: Bool) {
        // A teardown that reached no engine still owes the user an answer when it
        // interrupted a conversation. If an engine already finished, its outcome was
        // published first and this is a no-op.
        closeGapWindow(.closedWithoutEngine(reason: "the window closed before it was collected"))
        gapWindow = nil
        gapSyncGeneration &+= 1
        gapSync = nil
        gapSyncHolding = false
        guard flush, !liveHold.isEmpty else { liveHold.removeAll(); return }
        let held = liveHold
        liveHold.removeAll()
        for f in held { emitAudioFrame(f) }
    }

    /// Begin the ring sync once BOTH storage characteristics are known AND the data
    /// characteristic's subscription is live. Idempotent.
    private func maybeBeginGapSync(_ p: BLEPeripheral) {
        guard gapSyncHolding, gapSync == nil,
              let dataChar = storageDataChar, dataChar.isNotifying,
              storageControlChar != nil else { return }
        let engine = OmiOfflineSyncEngine()
        gapSync = engine
        engine.emit = { [weak self, weak p] cmd in
            guard let self, let p else { return }
            self.executeGapSyncCommand(cmd, on: p)
        }
        engine.emitFrame = { [weak self] frame in self?.emitAudioFrame(frame) }
        engine.finished = { [weak self] outcome in self?.gapSyncFinished(outcome) }
        log?.info("Omi: storage service live — checking offline cache")
        engine.begin()
        scheduleGapSyncStallCheck()
        // Overall budget: past this, release live audio regardless (one-shot).
        let generationAtStart = gapSyncGeneration
        bleQueue.asyncAfter(deadline: .now() + gapSyncOverallBudget) { [weak self] in
            guard let self, self.gapSyncGeneration == generationAtStart else { return }
            self.gapSync?.budgetExhausted()
        }
    }

    private func executeGapSyncCommand(_ cmd: OmiOfflineSyncEngine.Command, on p: BLEPeripheral) {
        switch cmd {
        case .readStatus:
            guard let ch = storageControlChar else { gapSync?.statusResult(nil); return }
            p.readValue(for: ch)
        case .requestInfo:
            writeStorage(OmiRingProtocol.infoCommand, to: p)
        case .read(let startSeq):
            log?.info("Omi: pulling offline cache from seq \(startSeq)")
            writeStorage(OmiRingProtocol.readCommand(startSeq: startSeq), to: p)
        case .advance(let seq):
            log?.info("Omi: advancing device read pointer to \(seq)")
            writeStorage(OmiRingProtocol.advanceCommand(newReadSeq: seq), to: p)
        case .stopTransfer:
            writeStorage(OmiRingProtocol.stopCommand, to: p)
        }
    }

    private func writeStorage(_ data: Data, to p: BLEPeripheral) {
        guard let ch = storageDataChar else { return }
        p.writeValue(data, for: ch, type: .withResponse)
    }

    private func gapSyncFinished(_ outcome: OmiOfflineSyncEngine.Outcome) {
        switch outcome {
        case .nothingToSync:
            log?.info("Omi: offline cache empty — nothing to sync")
        case .unsupportedProtocol(let why):
            log?.info("Omi: offline cache protocol unsupported (\(why)) — skipping sync")
        case .synced(let records, let frames):
            log?.info("Omi: offline cache synced — \(records) records, \(frames) frames recovered")
        case .aborted(let records, let frames, let reason):
            log?.warn("Omi: offline sync aborted (\(reason)) — kept \(records) records / \(frames) frames; advanced only over consumed")
        case .failed(let why):
            log?.warn("Omi: offline sync failed (\(why)) — device keeps its unread cache for next reconnect")
        }
        closeGapWindow(.engineFinished(outcome))
        endGapSyncWindow(flush: true)
    }

    /// Bump-and-check stall watchdog — COALESCED: at most one deferred check is in
    /// flight at a time (a large sync delivers ~100 notifications/s; scheduling one
    /// per event would pile up hundreds of pending no-op closures). When the check
    /// fires: activity moved → re-arm; no activity → stalled.
    private var stallCheckPending = false   // bleQueue only

    private func scheduleGapSyncStallCheck() {
        guard let engine = gapSync, engine.isActive, !stallCheckPending else { return }
        stallCheckPending = true
        let seen = engine.activityGeneration
        bleQueue.asyncAfter(deadline: .now() + gapSyncStallTimeout) { [weak self] in
            guard let self else { return }
            self.stallCheckPending = false
            guard let g = self.gapSync, g === engine, g.isActive else { return }
            if g.activityGeneration == seen { g.stalled() } else { self.scheduleGapSyncStallCheck() }
        }
    }

    // main-thread published mutations — skip-equal so a churning state machine (e.g. a
    // reacquire scan cycling scanning→idle→scanning) publishes only on ACTUAL change, one
    // coalesced objectWillChange per real transition rather than a burst of redundant
    // SwiftUI invalidations (the same discipline as the capture-status-warm fix).
    private func setState(_ s: DeviceConnectionState) {
        DispatchQueue.main.async {
            guard self.connectionState != s else { return }
            self.connectionState = s
        }
    }

    #if DEBUG || PERF_HARNESS
    /// Test seam: force the reported connection state so the `-SyntheticOmi` harness — a
    /// synthetic ambient frame source with no real BLE radio — can exercise the AMBIENT
    /// capture UI, whose live-tile gate (`isShowingCapture` → `sourcePresentation`) reads
    /// `device.connectionState`. Leak-gated; the symbol cannot exist in a shipping build.
    public func forceConnectionStateForTests(_ s: DeviceConnectionState) { setState(s) }

    /// Test seam: run the gap-window funnel on ITS OWNING QUEUE, synchronously, so a test
    /// drives the real functions with their real threading instead of a copy of them.
    /// Leak-gated; the symbol cannot exist in a shipping build.
    func runOnBleQueueForTests(_ body: () -> Void) { bleQueue.sync(execute: body) }
    #endif
    private func setDiscovered(_ d: [DiscoveredDevice]) {
        DispatchQueue.main.async {
            guard self.discovered != d else { return }
            self.discovered = d
        }
    }

    private func setSaved(_ id: UUID, name: String) {
        let d = UserDefaults.standard
        d.set(id.uuidString, forKey: Self.savedKey)
        d.set(name, forKey: Self.savedNameKey)
        publishSaved()
    }

    /// Record a successful connection (updates "last connected" on the device page).
    private func markConnected(_ id: UUID, name: String) {
        let d = UserDefaults.standard
        d.set(id.uuidString, forKey: Self.savedKey)
        d.set(name, forKey: Self.savedNameKey)
        d.set(Date().timeIntervalSinceReferenceDate, forKey: Self.savedDateKey)
        publishSaved()
    }

    private func publishSaved() {
        let s = Self.loadSaved()
        DispatchQueue.main.async { self.saved = s }
    }

    static func loadSaved() -> SavedOmi? {
        let d = UserDefaults.standard
        guard let idStr = d.string(forKey: Self.savedKey), let id = UUID(uuidString: idStr) else { return nil }
        let name = d.string(forKey: Self.savedNameKey) ?? "Omi"
        let ts = d.double(forKey: Self.savedDateKey)
        let last = ts > 0 ? Date(timeIntervalSinceReferenceDate: ts) : nil
        return SavedOmi(id: id, name: name, lastConnected: last)
    }
}

/// The BLE event sink — every one of these was a `CBCentralManagerDelegate` /
/// `CBPeripheralDelegate` method verbatim before the seam. The bodies are unchanged; only
/// the CoreBluetooth types they name moved behind the protocols.
extension DeviceManager: BLEEventSink {
    /// CB state restoration: iOS relaunched us (in the background) because an event
    /// fired for this central — typically the standing pending connect completing as
    /// the Omi came back into range. Reclaim the peripheral NOW; act on it only once
    /// the central reports poweredOn (nothing may be issued before that).
    public func bleCentral(_ c: BLECentral, willRestore restored: [BLEPeripheral]) {
        let savedId = Self.loadSaved()?.id
        guard let p = restored.first(where: { $0.identifier == savedId }) ?? restored.first else { return }
        log?.info("Omi: willRestoreState — reclaimed \(p.name ?? "?") (state \(p.linkState.rawValue))")
        p.routeEventsToSink()
        restoredPeripheral = p
    }

    public func bleCentralDidUpdateState(_ c: BLECentral) {
        switch c.managerState {
        case .poweredOn:
            if let p = restoredPeripheral {
                restoredPeripheral = nil
                handleRestoredPeripheral(p, central: c)
            } else if pendingUserScan {
                // An explicit pairing gesture powered the central — run the (bounded)
                // scan on the main queue where its generation bookkeeping lives.
                pendingUserScan = false
                DispatchQueue.main.async { [weak self] in self?.startScan() }
            } else if autoConnect {
                autoReconnect(userInitiated: false)   // automatic: dormant when no saved device
            }
        case .unauthorized, .poweredOff, .unsupported:
            setState(.poweredOff); emitSourceState(.failed("bluetooth unavailable"))
        default: break
        }
    }

    /// Act on the peripheral `willRestoreState` handed back, per the pure policy.
    private func handleRestoredPeripheral(_ p: BLEPeripheral, central c: BLECentral) {
        let restoredState: OmiReconnectPolicy.RestoredPeripheralState
        switch p.linkState {
        case .connected: restoredState = .connected
        case .connecting: restoredState = .connecting
        default: restoredState = .disconnected
        }
        switch OmiReconnectPolicy.onRestore(state: restoredState, autoConnect: autoConnect) {
        case .discoverServices:
            log?.info("Omi: restored CONNECTED \(p.name ?? "?") — rediscovering services")
            bind(p)
            setState(.connecting(p.name ?? "Omi"))
            beginGapSyncWindow()
            p.discoverServices([OmiUUID.audioService, OmiUUID.batteryService, OmiUUID.storageService])
        case .waitForPendingConnect:
            log?.info("Omi: restored PENDING connect to \(p.name ?? "?") — waiting for it to complete")
            bind(p)
            setState(.connecting(p.name ?? "Omi"))
        case .reissuePendingConnect:
            log?.info("Omi: restored DISCONNECTED \(p.name ?? "?") — re-arming pending connect")
            bind(p)
            setState(.disconnected)
            c.connect(p, options: nil)
        case .stayDown:
            setState(.idle)
        }
    }

    public func bleCentral(_ c: BLECentral, didDiscover p: BLEPeripheral, rssi: Int) {
        discoveredPeripherals[p.identifier] = p
        // A SCAN ROW SHOWS THE NAME THE DEVICE BROADCASTS, AND NOTHING ELSE. Defaulting an
        // un-named peripheral to a VENDOR name put a brand on a row about a device the app
        // knows nothing about — and it made the view's brand-free `unnamedDeviceName` branch
        // unreachable. Empty here; the scan list names it (design §3.1, T3 req 8).
        let dev = DiscoveredDevice(id: p.identifier, name: p.name ?? "", rssi: rssi)
        DispatchQueue.main.async {
            var list = self.discovered.filter { $0.id != dev.id }
            list.append(dev)
            self.discovered = list.sorted { $0.rssi > $1.rssi }
        }
        // Hands-free reconnect: when a scan turns up the device we've already paired,
        // connect to it AUTOMATICALLY instead of waiting for a manual tap. This is the
        // "stuck on scanning — sees the Omi but won't auto-connect" fix: autoReconnect's
        // retrievePeripherals() can come up empty (the OS handle isn't cached yet), so it
        // falls back to a scan that previously just listed the device and waited. First-
        // time pairing stays an explicit tap (no saved id ⇒ shouldAutoConnect == false).
        let savedId = UserDefaults.standard.string(forKey: Self.savedKey).flatMap(UUID.init(uuidString:))
        if autoConnect, OmiAutoConnect.shouldAutoConnect(discoveredId: p.identifier, savedId: savedId) {
            log?.info("Omi: saved device in range during scan — auto-connecting \(p.name ?? "?")")
            c.stopScan()
            bind(p)
            markConnectingName(p.name ?? "Omi")
            c.connect(p, options: nil)
        }
    }

    /// Set the connecting state for a name (used by the scan auto-connect path).
    private func markConnectingName(_ name: String) { setState(.connecting(name)) }

    public func bleCentral(_ c: BLECentral, didConnect p: BLEPeripheral) {
        // A real connection clears the retry backoffs so the NEXT outage starts from the
        // base delay, not the capped ceiling (bleQueue-only state, set here on bleQueue).
        failToConnectAttempts = 0
        reacquireBackoff.reset()
        log?.info("Omi: connected \(p.name ?? "?") — discovering audio + storage services")
        // Discover the audio service, the standard battery service (best-effort), and
        // the Omi STORAGE service — if present, gap audio recorded while disconnected
        // is pulled BEFORE live audio is released (recorded order). The gap-sync hold
        // opens now so no live frame can slip ahead of recovered audio.
        beginGapSyncWindow()
        p.discoverServices([OmiUUID.audioService, OmiUUID.batteryService, OmiUUID.storageService])
    }

    public func bleCentral(_ c: BLECentral, didFailToConnect p: BLEPeripheral, error: Error?) {
        emitSourceState(.failed("connect failed: \(error?.localizedDescription ?? "?")"))
        // A failed ATTEMPT is not a dead end (previously it was: one failed handshake
        // and the Omi never came back until the app was foregrounded). Retry with
        // EXPONENTIAL BACKOFF — failure implies the device is in range, so this is rare
        // and event-driven, but a flapping device must not become a fixed tight loop.
        switch OmiReconnectPolicy.onFailToConnect(autoConnect: autoConnect, attempt: failToConnectAttempts) {
        case .stayDown:
            failToConnectAttempts = 0
            setState(.idle)
        case .retryAfterDelay(let delay):
            failToConnectAttempts += 1
            setState(.disconnected)
            log?.warn("Omi: connect attempt failed (\(error?.localizedDescription ?? "?")) — retrying in \(Int(delay))s (attempt \(self.failToConnectAttempts))")
            bleQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.autoConnect, let c = self.central, c.managerState == .poweredOn else { return }
                guard p.linkState != .connected && p.linkState != .connecting else { return }
                self.bind(p)
                c.connect(p, options: nil)
            }
        }
    }

    public func bleCentral(_ c: BLECentral, didDisconnect p: BLEPeripheral, error: Error?) {
        setBatteryLevel(nil)          // the level is stale once the link drops
        // Settle any in-flight gap sync FIRST so held live audio is released (in
        // order) into the session before `.stopped` ends it.
        gapSync?.linkDropped()   // settles synchronously through gapSyncFinished
        applyLinkDrop()
        audioChar = nil; storageDataChar = nil; storageControlChar = nil
        emitSourceState(.stopped)            // ends the ambient capture session
        // A USER-suspended link (Omi toggled off) must stay down — don't fight the
        // toggle with an auto-reconnect. A transient drop (in/out of range) re-arms it.
        switch OmiReconnectPolicy.onDisconnect(autoConnect: autoConnect) {
        case .stayDown:
            setState(.idle)
        case .reissuePendingConnect:
            // THE iOS-correct always-reconnect: re-issue connect() on the SAME
            // peripheral object. A pending connect has NO timeout — it completes
            // whenever the Omi returns to range, including in the background, and
            // (with state restoration) even if iOS kills the app meanwhile. No scan
            // loop, no polling — CB wakes us.
            log?.warn("Omi: disconnected (\(error?.localizedDescription ?? "clean")) — pending reconnect armed")
            setState(.disconnected)
            bind(p)
            c.connect(p, options: nil)
        }
    }

    public func blePeripheral(_ p: BLEPeripheral, didDiscoverServices error: Error?) {
        var hasStorage = false
        for svc in p.discoveredServices ?? [] {
            if svc.uuid == OmiUUID.audioService {
                p.discoverCharacteristics([OmiUUID.audioDataChar, OmiUUID.codecChar], for: svc)
            } else if svc.uuid == OmiUUID.batteryService {
                p.discoverCharacteristics([OmiUUID.batteryLevelChar], for: svc)
            } else if svc.uuid == OmiUUID.buttonService {
                p.discoverCharacteristics([OmiUUID.buttonTriggerChar], for: svc)
            } else if svc.uuid == OmiUUID.storageService {
                hasStorage = true
                p.discoverCharacteristics([OmiUUID.storageDataChar, OmiUUID.storageControlChar], for: svc)
            }
        }
        applyServiceDiscovery(errorDescription: error?.localizedDescription,
                              sawStorageService: hasStorage)
    }

    /// The gap-window consequences of a service-discovery result, CB-free so the funnel is
    /// drivable without a radio.
    func applyServiceDiscovery(errorDescription: String?, sawStorageService: Bool) {
        guard let cause = GapWindowTrigger.closeCause(discoveryError: errorDescription,
                                                      sawStorageService: sawStorageService) else { return }
        if case .deviceHasNoStorage = cause {
            log?.info("Omi: no storage service — offline cache sync unavailable, live only")
        } else {
            log?.warn("Omi: service discovery failed (\(errorDescription ?? "?")) — "
                + "offline cache unavailable this time; the device keeps it")
        }
        closeGapWindow(cause)
        endGapSyncWindow(flush: true)
    }

    /// The gap-window consequences of a link drop, CB-free for the same reason.
    ///
    /// The caller settles the engine FIRST. `linkDropped()` publishes synchronously, so if
    /// an engine was running the window is already closed and this close is a no-op by the
    /// at-most-one rule; if there was no engine, the span was never requested and is still
    /// on the device.
    func applyLinkDrop() {
        closeGapWindow(.linkDroppedBeforeEngine)
        endGapSyncWindow(flush: true)
    }

    public func blePeripheral(_ p: BLEPeripheral, didDiscoverCharacteristicsFor service: BLEService, error: Error?) {
        for ch in service.discoveredCharacteristics ?? [] {
            if ch.uuid == OmiUUID.codecChar { p.readValue(for: ch) }
            if ch.uuid == OmiUUID.batteryLevelChar {
                p.readValue(for: ch)              // initial level
                p.setNotifyValue(true, for: ch)   // updates as it drains/charges
                log?.info("Omi: battery service found — reading level")
            }
            if ch.uuid == OmiUUID.audioDataChar {
                audioChar = ch
                p.setNotifyValue(true, for: ch)
                markConnected(p.identifier, name: p.name ?? "Omi")
                setState(.connected(p.name ?? "Omi"))
                emitSourceState(.streaming)   // triggers ambient capture
                log?.info("Omi: subscribed to audio — ambient capture live")
            }
            if ch.uuid == OmiUUID.buttonTriggerChar {
                p.setNotifyValue(true, for: ch)   // hardware button → double-click pauses
                log?.info("Omi: button service found — subscribed for double-click pause")
            }
            if ch.uuid == OmiUUID.storageControlChar { storageControlChar = ch }
            if ch.uuid == OmiUUID.storageDataChar {
                storageDataChar = ch
                p.setNotifyValue(true, for: ch)   // ring notifications (info/data/done/ack)
            }
        }
        maybeBeginGapSync(p)
    }

    /// Storage-char notify state settles here — begin the ring sync once the data
    /// characteristic is actually subscribed (writes before that are dropped by CB).
    public func blePeripheral(_ p: BLEPeripheral, didUpdateNotificationStateFor ch: BLECharacteristic, error: Error?) {
        if ch.uuid == OmiUUID.storageDataChar {
            if let error {
                log?.warn("Omi: storage subscribe failed (\(error.localizedDescription)) — skipping offline sync")
                // The device HAS storage; we could not reach it this time, so it keeps the span.
                closeGapWindow(.storageUnavailable(reason: error.localizedDescription))
                endGapSyncWindow(flush: true)
                return
            }
            maybeBeginGapSync(p)
        }
    }

    public func blePeripheral(_ p: BLEPeripheral, didUpdateValueFor ch: BLECharacteristic, error: Error?) {
        if let error { log?.warn("Omi: didUpdateValue error: \(error.localizedDescription)") }
        // Storage CONTROL char: the ring-status read result (or a read failure).
        if ch.uuid == OmiUUID.storageControlChar {
            gapSync?.statusResult(error == nil ? ch.value : nil)
            scheduleGapSyncStallCheck()
            return
        }
        // Storage DATA char: ring notifications (info / read-begin / data / done / ack).
        if ch.uuid == OmiUUID.storageDataChar {
            if let data = ch.value, error == nil { gapSync?.notification(data) }
            scheduleGapSyncStallCheck()
            return
        }
        guard let data = ch.value else { log?.warn("Omi: notify with nil value"); return }
        if ch.uuid == OmiUUID.batteryLevelChar {
            // Battery Level is a single byte, 0…100 (Bluetooth SIG 0x2A19).
            if let pct = data.first { setBatteryLevel(Int(pct)); log?.info("Omi: battery \(pct)%") }
            return
        }
        if ch.uuid == OmiUUID.codecChar { log?.info("Omi: codec=\(data.map { String($0) }.joined(separator: ","))"); return }
        if ch.uuid == OmiUUID.buttonTriggerChar { handleButtonNotify(data); return }
        guard ch.uuid == OmiUUID.audioDataChar else { return }
        // Diagnostics: count RAW notifications (before the header filter) so a
        // "connected but silent" device is unambiguous in the logs — log the first
        // one, then every 200th, plus any runt packet ≤ the 3-byte header.
        audioNotifs += 1
        if audioNotifs == 1 || audioNotifs % 200 == 0 {
            log?.info("Omi: audio notif #\(audioNotifs), \(data.count) bytes raw (mtu \(p.maximumWriteValueLength(for: .withoutResponse)))")
        }
        guard data.count > headerBytes else {
            if audioNotifs <= 5 { log?.warn("Omi: runt audio notif \(data.count)B (≤ header) — dropped") }
            return
        }
        let frame = data.subdata(in: headerBytes..<data.count)   // strip header → Opus frame
        if gapSyncHolding {
            // Recovered gap audio must land FIRST (recorded order): hold live frames
            // until the offline sync settles, bounded so memory can't run away.
            liveHold.append(frame)
            if liveHold.count >= liveHoldMaxFrames {
                log?.warn("Omi: live-hold cap reached during offline sync — releasing order hold")
                if let g = gapSync, g.isActive { g.budgetExhausted() } else { endGapSyncWindow(flush: true) }
            }
            return
        }
        emitAudioFrame(frame)
    }

    /// Decode an Omi button-trigger notification into a double-click → `onButtonDoubleClick`.
    /// The firmware's event encoding is UNCONFIRMED here, so this is deliberately tolerant of
    /// both known shapes and logs the RAW payload so an on-device test reveals the real one:
    ///  (a) a typed event byte where 2 == DOUBLE_TAP (Omi/Friend devkit `button.c`) → fire directly;
    ///  (b) a stream of per-press events → two presses within 400 ms is a double-click.
    /// A firmware that never sends this characteristic simply never calls this.
    private func handleButtonNotify(_ data: Data) {
        log?.info("Omi: button notify raw=[\(data.map { String($0) }.joined(separator: ","))]")
        let now = Date()
        // (a) explicit double-tap code.
        if data.first == 2 {
            lastButtonPressAt = nil
            onButtonDoubleClick?()
            return
        }
        // (b) press-stream fallback (single/long codes 1/3, or a bare press with no code).
        if let last = lastButtonPressAt, now.timeIntervalSince(last) <= 0.4 {
            lastButtonPressAt = nil
            onButtonDoubleClick?()
        } else {
            lastButtonPressAt = now
        }
    }
}

/// Omi BLE UUIDs (firmware transport.c). Shared by DeviceManager + OmiBleSource.
public enum OmiUUID {
    public nonisolated(unsafe) static let audioService = CBUUID(string: "19B10000-E8F2-537E-4F6C-D104768A1214")
    public nonisolated(unsafe) static let audioDataChar = CBUUID(string: "19B10001-E8F2-537E-4F6C-D104768A1214")
    public nonisolated(unsafe) static let codecChar = CBUUID(string: "19B10002-E8F2-537E-4F6C-D104768A1214")
    /// The STANDARD Bluetooth Battery Service (0x180F) + Battery Level characteristic
    /// (0x2A19) — a single byte 0…100. The Omi exposes these; any device that does not
    /// simply never fires the read, and the level stays nil (no fake value).
    public nonisolated(unsafe) static let batteryService = CBUUID(string: "180F")
    public nonisolated(unsafe) static let batteryLevelChar = CBUUID(string: "2A19")
    /// Omi hardware BUTTON service (Omi/Friend devkit firmware `button.c`). The button-
    /// trigger characteristic notifies a small event byte on tap. UUIDs + the exact event
    /// encoding are FIRMWARE-DEPENDENT and NOT confirmed in this repo — a device whose
    /// firmware lacks this service simply never discovers it (the notify never fires and
    /// nothing happens). The raw payload of every button notify is logged so an on-device
    /// test reveals the real encoding, which the double-click detector can then be tuned to.
    public nonisolated(unsafe) static let buttonService = CBUUID(string: "23BA7924-0000-1000-7450-346EAC492E92")
    public nonisolated(unsafe) static let buttonTriggerChar = CBUUID(string: "23BA7925-0000-1000-7450-346EAC492E92")
    /// Omi onboard-STORAGE service (firmware storage.c; UUIDs verified against the
    /// vendored omi repo — app models.dart + desktop DeviceUUIDs.swift). The DATA
    /// characteristic (…81) takes ring COMMANDS (write) and notifies ring
    /// info/data/done/ack; the CONTROL characteristic (…82) is the plain status
    /// read (16B LE on ring firmware 3.0.20+). A device without the service simply
    /// never syncs its offline cache — live streaming is unaffected.
    public nonisolated(unsafe) static let storageService = CBUUID(string: "30295780-4301-EABD-2904-2849ADFEAE43")
    public nonisolated(unsafe) static let storageDataChar = CBUUID(string: "30295781-4301-EABD-2904-2849ADFEAE43")
    public nonisolated(unsafe) static let storageControlChar = CBUUID(string: "30295782-4301-EABD-2904-2849ADFEAE43")
}

#else
// Non-CoreBluetooth host (macOS test runner): a no-op manager so the app + tests compile.
public final class DeviceManager: ObservableObject, AccountAudioSourceExposure, @unchecked Sendable {
    public static let restoreIdentifier = "foundryx.omi.central"
    private static let sharedLock = NSLock()
    private nonisolated(unsafe) static var sharedInstance: DeviceManager?   // sharedLock-guarded
    public static func shared(log: DoorLog? = nil) -> DeviceManager {
        sharedLock.lock(); defer { sharedLock.unlock() }
        if let s = sharedInstance { return s }
        let s = DeviceManager(log: log)
        sharedInstance = s
        return s
    }
    public static func sharedExisting() -> DeviceManager? {
        sharedLock.lock(); defer { sharedLock.unlock() }
        return sharedInstance
    }
    public var onFrame: ((Data) -> Void)?
    public var onState: ((AudioSourceState) -> Void)?
    private let exposureLock = NSLock()
    private let exposureEmissions = DispatchGroup()
    private var exposureClosed = false
    private var lastSourceState: AudioSourceState?
    public func replayState() {
        exposureLock.lock()
        let state = lastSourceState
        exposureLock.unlock()
        if let state { emitState(state) }
    }
    @Published public private(set) var connectionState: DeviceConnectionState = .poweredOff
    @Published public private(set) var discovered: [DiscoveredDevice] = []
    @Published public private(set) var saved: SavedOmi?
    @Published public private(set) var batteryLevel: Int?
    public var isBatteryLow: Bool { (batteryLevel ?? 100) < 20 }
    public init(log: DoorLog? = nil) { _ = log }
    public static var hasSavedDevice: Bool { false }
    public func start() {
        exposureLock.lock()
        let closed = exposureClosed
        exposureLock.unlock()
        guard !closed else { return }
        emitState(.failed("CoreBluetooth unavailable"))
    }
    public func stop() { emitState(.stopped) }
    public func setEnabled(_ on: Bool) {}
    public func suspend() { emitState(.stopped) }
    public func startScan() {}
    public func stopScan() {}
    public func stopScanIfScanning() {}
    public func connect(_ device: DiscoveredDevice) {}
    public func connectOrPair() {}
    public func reconnect() {}
    public func forget() {}
    public func disconnect() { emitState(.stopped) }
    public func closeAudioExposure() async -> AccountExposureCloseResult {
        guard claimExposureClose() else { return .alreadyClosed }
        await withCheckedContinuation { continuation in
            exposureEmissions.notify(queue: .global()) {
                continuation.resume()
            }
        }
        emitState(.stopped, terminal: true)
        return .closed
    }

    private func claimExposureClose() -> Bool {
        exposureLock.lock()
        defer { exposureLock.unlock() }
        guard !exposureClosed else { return false }
        exposureClosed = true
        return true
    }

    private func emitState(
        _ state: AudioSourceState,
        terminal: Bool = false
    ) {
        exposureLock.lock()
        let closed = exposureClosed
        if terminal || !closed {
            lastSourceState = state
            exposureEmissions.enter()
        }
        exposureLock.unlock()
        guard terminal || !closed else { return }
        defer { exposureEmissions.leave() }
        onState?(state)
    }
}
#endif
