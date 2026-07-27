// CaptureSourceRegistry — the extensible model behind the device page's capture
// sources. It generalises the old fixed `CaptureSourceKind { omi, phoneMic }` single
// pick into a REGISTRY of independently-toggleable sources, each described by a stable
// id, a category, a live connection state, and a persisted enabled flag.
//
// Design goals (track 20260628T1702):
//   • PER-SOURCE TOGGLE — each source is on/off independently (not mutually exclusive).
//   • EXTENSIBLE — adding a source is one `CaptureSourceCategory` case + one registry
//     entry; the capture PIPELINE never changes because every source still emits the
//     same 48 kHz/960 Opus frames through `AudioFrameSource` → `FrameRouter`. Apple
//     Watch + an arbitrary Bluetooth mic are modeled as first-class registry entries.
//   • ADD-SOURCE — Bluetooth mics are discovered for real via `AVAudioSession`
//     available inputs; Apple Watch is a scaffold entry with a clear TODO.
//
// Multi-source policy (v1): "enabled = available; ONE active at a time." The toggles
// control AVAILABILITY; the pipeline still produces a single serial Opus stream per
// conversation (mixing two live mics into one stream would corrupt the bitstream), so
// among the enabled+ready sources exactly one is ACTIVE, chosen by priority
// (Omi > Apple Watch > Bluetooth mic > Phone mic) and pushed onto the EXISTING
// `CaptureManager.selectCaptureSource(_:)`. Real multi-stream mixing is a future
// milestone, not v1.

import Foundation
#if canImport(Combine)
import Combine
#endif
#if canImport(AVFoundation)
import AVFoundation
#endif

// MARK: - Value types

/// The CATEGORY of a capture source — what KIND of device produces the audio. Open for
/// extension: a new kind of source is a new case here (+ a registry entry), never a
/// rework of the capture pipeline.
public enum CaptureSourceCategory: String, Sendable, Equatable, Codable, CaseIterable {
    case omi            // the Omi BLE wearable
    case phoneMic       // this phone's built-in microphone
    case appleWatch     // an Apple Watch mic over WatchConnectivity (scaffold)
    case bluetoothMic   // an arbitrary Bluetooth audio input route (AVAudioSession)

    /// SF Symbol for the source's row icon.
    public var symbolName: String {
        switch self {
        case .omi:          return "antenna.radiowaves.left.and.right"
        case .phoneMic:     return "iphone"
        case .appleWatch:   return "applewatch"
        case .bluetoothMic: return "headphones"
        }
    }

    /// Default human label when a discovered source supplies none.
    public var defaultDisplayName: String {
        switch self {
        case .omi:          return "Omi wearable"
        case .phoneMic:     return "Phone microphone"
        case .appleWatch:   return "Apple Watch"
        case .bluetoothMic: return "Bluetooth microphone"
        }
    }

    /// Active-source PRIORITY (lower wins). Among the enabled+ready sources the lowest
    /// priority becomes the single active capture source (see the v1 policy).
    public var activePriority: Int {
        switch self {
        case .omi:          return 0
        case .appleWatch:   return 1
        case .bluetoothMic: return 2
        case .phoneMic:     return 3
        }
    }

    /// The legacy single-pick kind this category drives in the existing capture
    /// lifecycle. Omi keeps its BLE path; every mic-class source records through the
    /// phone-mic path (a BT mic just selects a different AVAudioSession input route).
    /// `nil` ⇒ no capture path yet (the Apple Watch scaffold), so it never goes active.
    public var captureKind: CaptureSourceKind? {
        switch self {
        case .omi:                       return .omi
        case .phoneMic, .bluetoothMic:   return .phoneMic
        case .appleWatch:                return nil   // scaffold — no capture path yet
        }
    }
}

/// Liveness of a registered source, INDEPENDENT of whether the user has ENABLED it.
public enum CaptureSourceConnection: String, Sendable, Equatable {
    case builtIn        // always present (the phone's own mic)
    case connected      // discovered + linked, ready to capture now
    case available      // route/device present but not the active route
    case disconnected   // remembered but not currently reachable
    case scaffold       // recognized but capture not yet implemented (Apple Watch TODO)
    case unavailable

    /// Ready to be the ACTIVE capture source right now.
    public var isReady: Bool {
        switch self {
        case .builtIn, .connected, .available: return true
        case .disconnected, .scaffold, .unavailable: return false
        }
    }

    /// Short status line for the source's row.
    public var label: String {
        switch self {
        case .builtIn:      return "Always available"
        case .connected:    return "Connected"
        case .available:    return "Available"
        case .disconnected: return "Not connected"
        case .scaffold:     return "Coming soon"
        case .unavailable:  return "Unavailable"
        }
    }
}

/// One capture source the device page lists. `id` is STABLE + persistable (so the
/// enabled toggle survives relaunch): built-ins use their category raw value; a
/// discovered BT mic uses `"bt:<route-uid>"`.
public struct CaptureSourceDescriptor: Identifiable, Equatable, Sendable {
    public let id: String
    public let category: CaptureSourceCategory
    public var displayName: String
    /// Optional sub-detail (e.g. the BT route's port name), shown under the title.
    public var detail: String?
    public var connection: CaptureSourceConnection
    public var enabled: Bool
    /// Whether the user may flip the enabled toggle (false for a scaffold source).
    public var canToggle: Bool
    /// True for the built-in Omi/phone-mic seeds (can't be removed); discovered sources
    /// (BT mics, watch) can be removed.
    public let isBuiltIn: Bool
    /// For a BT mic, the AVAudioSession input route uid to prefer when it's the active
    /// source. `nil` for non-routed sources.
    public var routeUID: String?

    public init(id: String, category: CaptureSourceCategory, displayName: String,
                detail: String? = nil, connection: CaptureSourceConnection,
                enabled: Bool, canToggle: Bool, isBuiltIn: Bool, routeUID: String? = nil) {
        self.id = id
        self.category = category
        self.displayName = displayName
        self.detail = detail
        self.connection = connection
        self.enabled = enabled
        self.canToggle = canToggle
        self.isBuiltIn = isBuiltIn
        self.routeUID = routeUID
    }

    /// Stable id for the Omi + phone-mic built-ins.
    public static let omiId = CaptureSourceCategory.omi.rawValue
    public static let phoneMicId = CaptureSourceCategory.phoneMic.rawValue
    public static let appleWatchId = CaptureSourceCategory.appleWatch.rawValue
    /// Stable id for a discovered Bluetooth mic route.
    public static func bluetoothId(routeUID: String) -> String { "bt:\(routeUID)" }
}

/// A discovered audio input route (the real ones come from `AVAudioSession`; tests
/// inject fakes). Only Bluetooth inputs are surfaced as add-able BT-mic sources.
public struct DiscoveredAudioInput: Equatable, Sendable {
    public let uid: String
    public let name: String
    public let isBluetooth: Bool
    public init(uid: String, name: String, isBluetooth: Bool) {
        self.uid = uid; self.name = name; self.isBluetooth = isBluetooth
    }
}

// MARK: - Persistence + discovery seams (injectable for hermetic tests)

/// Persisted per-source enabled overrides + the user-added (BT/watch) sources, so the
/// registry survives relaunch. Injectable so tests stay hermetic (no shared defaults).
public protocol CaptureSourceStore: AnyObject {
    /// id → enabled override. Absent id ⇒ the source's built-in default.
    var enabledOverrides: [String: Bool] { get set }
    /// User-added (discovered) sources to re-materialise on launch.
    var addedSources: [CaptureSourceRecord] { get set }
}

/// A persisted record of a user-added source (BT mic / watch), enough to recreate its
/// registry descriptor on the next launch.
public struct CaptureSourceRecord: Codable, Equatable, Sendable {
    public let id: String
    public let category: CaptureSourceCategory
    public let displayName: String
    public let routeUID: String?
    public init(id: String, category: CaptureSourceCategory, displayName: String, routeUID: String?) {
        self.id = id; self.category = category; self.displayName = displayName; self.routeUID = routeUID
    }
}

/// In-memory store for tests.
public final class InMemoryCaptureSourceStore: CaptureSourceStore {
    public var enabledOverrides: [String: Bool]
    public var addedSources: [CaptureSourceRecord]
    public init(enabledOverrides: [String: Bool] = [:], addedSources: [CaptureSourceRecord] = []) {
        self.enabledOverrides = enabledOverrides
        self.addedSources = addedSources
    }
}

/// UserDefaults-backed store (the app's real persistence).
public final class UserDefaultsCaptureSourceStore: CaptureSourceStore {
    private let defaults: UserDefaults
    private let explicitCompatibility: Bool
    private let addedKey = "foundryx.capture.sources.added"
    public init() {
        defaults = .standard
        explicitCompatibility = false
    }
    public init(defaults: UserDefaults) {
        self.defaults = defaults
        explicitCompatibility = true
    }

    public var enabledOverrides: [String: Bool] {
        get {
            if !explicitCompatibility {
                switch AccountPreferences.read(
                    AccountPreferenceCatalog.captureSourceEnabledOverrides) {
                case .value(let value): return value
                case .absent: return [:]
                }
            }
            switch AccountPreferenceCompatibilityStore(
                defaults: defaults
            ).read(AccountPreferenceCatalog.captureSourceEnabledOverrides) {
            case .value(let value): return value
            case .absent: return [:]
            }
        }
        set {
            if !explicitCompatibility {
                _ = AccountPreferences.write(
                    newValue,
                    for: AccountPreferenceCatalog.captureSourceEnabledOverrides)
                return
            }
            _ = AccountPreferenceCompatibilityStore(
                defaults: defaults
            ).write(
                newValue,
                for: AccountPreferenceCatalog.captureSourceEnabledOverrides)
        }
    }
    public var addedSources: [CaptureSourceRecord] {
        get {
            guard let data = defaults.data(forKey: addedKey),
                  let recs = try? JSONDecoder().decode([CaptureSourceRecord].self, from: data) else { return [] }
            return recs
        }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: addedKey) }
    }
}

/// Enumerates + selects the device's audio input routes. The real impl uses
/// `AVAudioSession`; tests inject a fake.
public protocol AudioInputDiscovering: AnyObject, Sendable {
    /// Currently-available input routes (built-in mic, wired, Bluetooth, …).
    func availableInputs() -> [DiscoveredAudioInput]
    /// Prefer a specific input route (by uid) for capture; `nil` clears the preference.
    func setPreferredInput(uid: String?)
}

/// No-op discovery (macOS / tests with no audio session). Reports nothing.
public final class NoAudioInputDiscovery: AudioInputDiscovering, @unchecked Sendable {
    public init() {}
    public func availableInputs() -> [DiscoveredAudioInput] { [] }
    public func setPreferredInput(uid: String?) {}
}

#if os(iOS)
/// Real `AVAudioSession`-backed discovery. Lists available inputs (flagging Bluetooth
/// routes) and sets the preferred input route so a chosen BT mic actually feeds the
/// phone-mic capture path.
public final class SystemAudioInputDiscovery: AudioInputDiscovering, @unchecked Sendable {
    public init() {}

    public func availableInputs() -> [DiscoveredAudioInput] {
        let session = AVAudioSession.sharedInstance()
        // Ensure the session can see Bluetooth inputs (HFP) before enumerating.
        try? session.setCategory(.playAndRecord, mode: .measurement, options: [.allowBluetooth])
        let inputs = session.availableInputs ?? []
        return inputs.map { port in
            DiscoveredAudioInput(uid: port.uid, name: port.portName,
                                 isBluetooth: Self.isBluetooth(port.portType))
        }
    }

    public func setPreferredInput(uid: String?) {
        let session = AVAudioSession.sharedInstance()
        guard let uid else { try? session.setPreferredInput(nil); return }
        if let port = (session.availableInputs ?? []).first(where: { $0.uid == uid }) {
            try? session.setPreferredInput(port)
        }
    }

    private static func isBluetooth(_ type: AVAudioSession.Port) -> Bool {
        type == .bluetoothHFP || type == .bluetoothLE || type == .bluetoothA2DP
    }
}
#endif

// MARK: - Registry

/// The device page's capture-source model. Owns the list of sources, their enabled
/// state (persisted), discovery of add-able Bluetooth mics, and the single ACTIVE
/// source chosen among the enabled+ready set.
@MainActor
public final class CaptureSourceRegistry: ObservableObject {
    /// All known sources, in stable display order (built-ins first, then added).
    @Published public private(set) var sources: [CaptureSourceDescriptor] = []
    /// Bluetooth inputs discovered by the most recent `discoverBluetoothMics()` that are
    /// NOT already in the registry — the "+ Add source" candidate list.
    @Published public private(set) var discoveredBluetoothInputs: [DiscoveredAudioInput] = []
    /// The single source currently selected as ACTIVE (highest-priority enabled+ready).
    @Published public private(set) var activeSourceId: String?

    private let store: CaptureSourceStore
    private let discovery: AudioInputDiscovering
    private var accountBinding: CaptureAccountScope.AccountBinding?
    private weak var deviceManager: DeviceManager?
    private var capturePreferenceSnapshotInstalled = false
    private var accountExposureClosed = false
    private var accountExposureRegistration:
        AccountExposureRegistration?

    /// Fired whenever the active source changes — wired by the app to the EXISTING
    /// `CaptureManager.selectCaptureSource(_:)` so the capture lifecycle is unchanged.
    /// `@MainActor` since the registry (and `CaptureManager`) live on the main actor.
    public var onActiveSourceChanged: (@MainActor (CaptureSourceKind) -> Void)?

    /// Fired whenever a source's ENABLED flag flips (device-page toggle). Wired by the
    /// app to the source's lifecycle owner — e.g. the Omi's `DeviceManager.setEnabled`,
    /// so toggling the Omi off truly drops + un-arms its BLE link (and toggling it on
    /// resumes the connect flow), independent of the active-capture-kind switch.
    /// `@MainActor` since the registry + DeviceManager live on the main actor.
    public var onSourceEnabledChanged: (@MainActor (CaptureSourceCategory, Bool) -> Void)?

    public init(store: CaptureSourceStore = UserDefaultsCaptureSourceStore(),
                discovery: AudioInputDiscovering? = nil,
                phoneMicAvailable: Bool = true,
                accountBinding: CaptureAccountScope.AccountBinding? = nil,
                deviceManager: DeviceManager? = nil) {
        self.store = store
        self.accountBinding = accountBinding
        self.deviceManager = deviceManager
        #if os(iOS)
        self.discovery = discovery ?? SystemAudioInputDiscovery()
        #else
        self.discovery = discovery ?? NoAudioInputDiscovery()
        #endif
        seed(phoneMicAvailable: phoneMicAvailable)
        recomputeActive(notify: false)   // initial active without firing the callback
    }

    /// One-time dormant install. It updates only the in-memory descriptors and
    /// never writes the compatibility store.
    @discardableResult
    public func installCapturePreferenceSnapshot(
        _ snapshot: CaptureAccountPreferenceSnapshot
    ) -> Bool {
        guard !capturePreferenceSnapshotInstalled,
              snapshot.binding.isCurrent,
              accountBinding == nil || accountBinding == snapshot.binding else {
            return false
        }
        accountBinding = snapshot.binding
        capturePreferenceSnapshotInstalled = true
        applyCapturePreferenceSnapshot(snapshot)
        return true
    }

    /// Explicit refresh only; no identity observer selects this path in Task 3.
    @discardableResult
    public func refreshCapturePreferences(
        compatibility: AccountPreferenceCompatibilityStore,
        binding: CaptureAccountScope.AccountBinding
    ) -> Bool {
        guard binding.isCurrent,
              accountBinding == nil || accountBinding == binding else {
            return false
        }
        accountBinding = binding
        applyCapturePreferenceSnapshot(
            CaptureSettings.snapshot(
                compatibility: compatibility,
                binding: binding))
        return true
    }

    private func applyCapturePreferenceSnapshot(
        _ snapshot: CaptureAccountPreferenceSnapshot
    ) {
        let overrides = snapshot.sourceEnabledOverrides
        for index in sources.indices {
            let source = sources[index]
            let defaultEnabled = source.isBuiltIn
                ? true
                : source.category != .appleWatch
            sources[index].enabled = overrides[source.id] ?? defaultEnabled
        }
        recomputeActive(notify: false)
    }

    /// Terminal account exposure close. This intentionally does not route through
    /// `setEnabled`, so user preferences and saved hardware remain untouched.
    public func closeAccountExposure(
        expected: CaptureAccountScope.AccountBinding
    ) async -> AccountExposureCloseResult {
        guard let accountBinding else { return .unavailable }
        guard expected == accountBinding else { return .ownerMismatch }
        guard !accountExposureClosed else { return .alreadyClosed }
        guard let deviceManager else {
            accountExposureClosed = true
            return .closed
        }
        let result = await deviceManager.closeAudioExposure()
        if result == .closed || result == .alreadyClosed {
            accountExposureClosed = true
        }
        return result
    }

    /// Inert, idempotent registration retained by the registry StateObject
    /// itself rather than a transient SwiftUI view initialization.
    public func registerAccountExposure(
        with coordinator: AccountExposureCoordinator = .process
    ) {
        guard accountExposureRegistration == nil else { return }
        let registration = AccountExposureRegistration(
            participantID: "capture-source-registry",
            kind: .live,
            binding: accountBinding,
            owner: self,
            close: { registry, expected in
                await registry.closeAccountExposure(expected: expected)
            })
        accountExposureRegistration = registration
        coordinator.register(registration)
    }

    // MARK: seeding + persistence

    /// Build the initial source list: the Omi + phone-mic built-ins, then any
    /// user-added (BT/watch) sources from the store, applying persisted enabled overrides.
    private func seed(phoneMicAvailable: Bool) {
        var list: [CaptureSourceDescriptor] = []
        list.append(CaptureSourceDescriptor(
            id: CaptureSourceDescriptor.omiId, category: .omi,
            displayName: CaptureSourceCategory.omi.defaultDisplayName,
            connection: .disconnected, enabled: enabled(CaptureSourceDescriptor.omiId, default: true),
            canToggle: true, isBuiltIn: true))
        if phoneMicAvailable {
            list.append(CaptureSourceDescriptor(
                id: CaptureSourceDescriptor.phoneMicId, category: .phoneMic,
                displayName: CaptureSourceCategory.phoneMic.defaultDisplayName,
                connection: .builtIn, enabled: enabled(CaptureSourceDescriptor.phoneMicId, default: true),
                canToggle: true, isBuiltIn: true))
        }
        for rec in store.addedSources {
            list.append(descriptor(from: rec))
        }
        sources = list
    }

    private func descriptor(from rec: CaptureSourceRecord) -> CaptureSourceDescriptor {
        let scaffold = rec.category == .appleWatch
        return CaptureSourceDescriptor(
            id: rec.id, category: rec.category, displayName: rec.displayName,
            detail: nil,
            connection: scaffold ? .scaffold : .available,
            enabled: enabled(rec.id, default: !scaffold),
            canToggle: !scaffold,
            isBuiltIn: false,
            routeUID: rec.routeUID)
    }

    private func enabled(_ id: String, default def: Bool) -> Bool {
        store.enabledOverrides[id] ?? def
    }

    // MARK: per-source enabled toggle (persisted)

    public func isEnabled(_ id: String) -> Bool {
        sources.first(where: { $0.id == id })?.enabled ?? false
    }

    /// Flip a source on/off. Persists the override and recomputes the active source
    /// (disabling the active one hands off to the next-priority enabled source).
    public func setEnabled(_ id: String, _ on: Bool) {
        guard let idx = sources.firstIndex(where: { $0.id == id }) else { return }
        guard sources[idx].canToggle else { return }
        guard sources[idx].enabled != on else { return }
        sources[idx].enabled = on
        let category = sources[idx].category
        var overrides = store.enabledOverrides
        overrides[id] = on
        store.enabledOverrides = overrides
        // Drive the source's lifecycle owner FIRST (e.g. suspend/resume the Omi link)
        // so a toggled-off source is actually torn down, THEN recompute which enabled+
        // ready source captures.
        onSourceEnabledChanged?(category, on)
        recomputeActive(notify: true)
    }

    /// The sources VISIBLE as usable capture options on the capture surface: the ones the
    /// user has left ENABLED. A toggled-off source is removed from this set (the capture
    /// page must not keep offering / showing a source the user switched off).
    public var captureVisibleSources: [CaptureSourceDescriptor] {
        sources.filter { $0.enabled }
    }

    /// Whether a source is currently capture-visible (enabled) — the capture page uses
    /// this to hide a toggled-off source.
    public func isCaptureVisible(_ id: String) -> Bool {
        sources.first(where: { $0.id == id })?.enabled ?? false
    }

    // MARK: live connection updates

    /// Update a source's live connection state (e.g. the Omi from `DeviceManager`).
    public func setConnection(_ id: String, _ connection: CaptureSourceConnection) {
        guard let idx = sources.firstIndex(where: { $0.id == id }) else { return }
        guard sources[idx].connection != connection else { return }
        sources[idx].connection = connection
        recomputeActive(notify: true)
    }

    /// Convenience: reflect the Omi's connected/disconnected liveness.
    public func setOmiConnected(_ connected: Bool) {
        setConnection(CaptureSourceDescriptor.omiId, connected ? .connected : .disconnected)
    }

    // MARK: add-source (discover + register)

    /// Discover connected Bluetooth mics not already in the registry → the add-source
    /// candidate list. Real on iOS via `AVAudioSession.availableInputs`.
    public func discoverBluetoothMics() {
        let existing = Set(sources.compactMap { $0.routeUID })
        discoveredBluetoothInputs = discovery.availableInputs()
            .filter { $0.isBluetooth && !existing.contains($0.uid) }
    }

    /// Add a discovered Bluetooth mic as a registry entry (enabled by default), persist
    /// it, and recompute the active source.
    @discardableResult
    public func addBluetoothMic(_ input: DiscoveredAudioInput) -> CaptureSourceDescriptor {
        let id = CaptureSourceDescriptor.bluetoothId(routeUID: input.uid)
        if let existing = sources.first(where: { $0.id == id }) { return existing }
        let name = input.name.isEmpty ? CaptureSourceCategory.bluetoothMic.defaultDisplayName : input.name
        let desc = CaptureSourceDescriptor(
            id: id, category: .bluetoothMic, displayName: name,
            detail: "Bluetooth", connection: .available, enabled: true,
            canToggle: true, isBuiltIn: false, routeUID: input.uid)
        sources.append(desc)
        persistAdded(CaptureSourceRecord(id: id, category: .bluetoothMic,
                                         displayName: name, routeUID: input.uid))
        var overrides = store.enabledOverrides; overrides[id] = true; store.enabledOverrides = overrides
        discoveredBluetoothInputs.removeAll { $0.uid == input.uid }
        recomputeActive(notify: true)
        return desc
    }

    /// Register the Apple Watch SCAFFOLD entry. TODO(track 20260628T1702): wire a real
    /// WatchConnectivity / watch-mic `AudioFrameSource` and flip `.scaffold` → live
    /// connection + `canToggle`. There is no watchOS target yet, so this only models the
    /// source in the registry + UI; it never becomes the active capture source.
    @discardableResult
    public func addAppleWatchScaffold() -> CaptureSourceDescriptor {
        let id = CaptureSourceDescriptor.appleWatchId
        if let existing = sources.first(where: { $0.id == id }) { return existing }
        let desc = CaptureSourceDescriptor(
            id: id, category: .appleWatch,
            displayName: CaptureSourceCategory.appleWatch.defaultDisplayName,
            detail: "Not yet supported", connection: .scaffold, enabled: false,
            canToggle: false, isBuiltIn: false)
        sources.append(desc)
        persistAdded(CaptureSourceRecord(id: id, category: .appleWatch,
                                         displayName: desc.displayName, routeUID: nil))
        return desc
    }

    /// Remove a user-added source (built-ins can't be removed).
    public func removeSource(_ id: String) {
        guard let idx = sources.firstIndex(where: { $0.id == id }), !sources[idx].isBuiltIn else { return }
        sources.remove(at: idx)
        store.addedSources = store.addedSources.filter { $0.id != id }
        var overrides = store.enabledOverrides; overrides[id] = nil; store.enabledOverrides = overrides
        recomputeActive(notify: true)
    }

    private func persistAdded(_ rec: CaptureSourceRecord) {
        var added = store.addedSources
        if !added.contains(where: { $0.id == rec.id }) { added.append(rec); store.addedSources = added }
    }

    // MARK: active-source policy (one active among enabled + ready)

    /// Recompute the single ACTIVE capture source: the highest-priority source that is
    /// both ENABLED and READY (and has a capture path). On change, set the BT input
    /// route (if any) and notify the app to drive the existing capture lifecycle.
    private func recomputeActive(notify: Bool) {
        let candidate = sources
            .filter { $0.enabled && $0.connection.isReady && $0.category.captureKind != nil }
            .min(by: { $0.category.activePriority < $1.category.activePriority })
        let newId = candidate?.id
        guard newId != activeSourceId else { return }
        activeSourceId = newId
        // Route a chosen BT mic's input; clear the preference otherwise.
        discovery.setPreferredInput(uid: candidate?.routeUID)
        if notify, let kind = candidate?.category.captureKind {
            onActiveSourceChanged?(kind)
        }
    }

    /// The active source's descriptor, if any.
    public var activeSource: CaptureSourceDescriptor? {
        sources.first(where: { $0.id == activeSourceId })
    }
}
