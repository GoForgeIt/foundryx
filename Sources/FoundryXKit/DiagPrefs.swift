// DiagPrefs — the diagnostics preference surface (track 20260717T0600 T3).
//
// Nick sees stacked "FoundryX 1820 ms" pills at the top of TestFlight builds. Those
// are iOS's SYSTEM Hang Detection developer banners (Settings → Developer), which no
// app code can suppress — this repo's perf system (App/PerfMetricsSubscriber.swift →
// PerfSink → POST /diag/log) is EMISSION-ONLY and has never had an in-app render path.
//
// This ships the implementable half: a first-class, user-controllable in-app
// performance overlay — compact perf-span/hang pills at the top of the screen — that
// renders ONLY when a real Settings toggle is on. DEFAULT OFF, no hidden env-var/launch
// knob. Telemetry emission is COMPLETELY unaffected in both toggle states: the overlay
// taps the already-formatted, already-shipped spans READ-ONLY (PerfSink.ship and every
// PerfDiag formatter stay byte-identical; the overlay never sits on the emission path).

import Foundation
import Combine

// MARK: - Preferences

/// Diagnostics preference keys. One place so the overlay model, the tap in
/// PerfMetricsSubscriber, and Settings agree. The master switch defaults OFF.
public enum DiagPrefs {
    /// The in-app performance overlay master switch. DEFAULT OFF.
    public static let perfOverlayKey = "foundryx.diag.perfOverlay"

    /// Honor an explicit user choice; until one exists the overlay is OFF (the
    /// `object(forKey:) != nil` unset-vs-explicit resolution, mirroring AmbientPrefs).
    public static func perfOverlayEnabled(defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: perfOverlayKey) != nil {
            return defaults.bool(forKey: perfOverlayKey)
        }
        return false
    }

    /// Persist the user's explicit choice.
    public static func setPerfOverlayEnabled(_ on: Bool, defaults: UserDefaults = .standard) {
        defaults.set(on, forKey: perfOverlayKey)
    }
}

// MARK: - Overlay pill

/// One perf line as a display pill — the span/hang name and its duration, e.g.
/// "capture-hydrate 820 ms". Carries NO wire-format tokens (build/dev/PII); it is a
/// human glance, not the shipped line.
public struct PerfPill: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let text: String
    public let createdAt: Date

    public init(id: UUID = UUID(), text: String, createdAt: Date) {
        self.id = id
        self.text = text
        self.createdAt = createdAt
    }
}

// MARK: - Overlay state (pure, testable core)

/// The overlay's ring buffer + expiry — a pure, non-isolated value so scenarios pin the
/// behavior (default-off drop, newest-first, cap, auto-expire) without any UI or clock.
/// `PerfOverlayModel` is a thin @MainActor wrapper over this.
public struct PerfOverlayState: Equatable, Sendable {
    /// Newest LAST (insertion order). `display` reverses for newest-on-top rendering.
    public private(set) var pills: [PerfPill] = []
    /// Keep at most this many pills on screen.
    public let maxPills: Int
    /// A pill lives this long before it auto-expires.
    public let ttl: TimeInterval

    public init(maxPills: Int = 4, ttl: TimeInterval = 4) {
        self.maxPills = maxPills
        self.ttl = ttl
    }

    /// Display format for a recorded span/hang: "<label> <ms> ms".
    public static func pillText(label: String, ms: Int) -> String { "\(label) \(ms) ms" }

    /// Record a span/hang. `enabled == false` ⇒ DROPPED (no accumulation while off) —
    /// the overlay is opt-in and never grows silently. Expired pills are swept first so
    /// the buffer stays fresh even when the toggle just flipped on.
    @discardableResult
    public mutating func record(label: String, ms: Int, enabled: Bool, now: Date) -> Bool {
        expire(now: now)
        guard enabled else { return false }
        pills.append(PerfPill(text: Self.pillText(label: label, ms: ms), createdAt: now))
        if pills.count > maxPills { pills.removeFirst(pills.count - maxPills) }
        return true
    }

    /// Drop pills older than `ttl`.
    public mutating func expire(now: Date) {
        let cutoff = now.addingTimeInterval(-ttl)
        pills.removeAll { $0.createdAt < cutoff }
    }

    /// Dismiss a single pill (tap-to-dismiss).
    public mutating func dismiss(_ id: UUID) { pills.removeAll { $0.id == id } }

    /// Clear everything (e.g. the toggle flips OFF).
    public mutating func clear() { pills.removeAll() }

    /// Newest-first for top-of-screen rendering.
    public var display: [PerfPill] { pills.reversed() }
}

// MARK: - Overlay model (observable wrapper)

/// The app-lifetime, observable overlay model. `PerfMetricsSubscriber` forwards each
/// already-shipped span/hang here READ-ONLY; the view observes `pills`. Gating lives in
/// the model (it reads the pref per line), so flipping the Settings toggle takes effect
/// without an app restart and an OFF toggle drops every incoming line.
@MainActor
public final class PerfOverlayModel: ObservableObject {
    /// The single instance the perf tap forwards to and the overlay view observes.
    public static let shared = PerfOverlayModel()

    @Published public private(set) var state: PerfOverlayState

    private let isEnabled: @Sendable () -> Bool
    private let now: @Sendable () -> Date

    /// Session-only enable override (review P3-1): lets the DEBUG `-PerfOverlayDemo`
    /// screenshot seam light the overlay up WITHOUT persisting the user's pref to
    /// UserDefaults. `nil` (always, outside the demo) defers to the Settings toggle.
    public var sessionOverrideEnabled: Bool?

    public init(
        isEnabled: @escaping @Sendable () -> Bool = { DiagPrefs.perfOverlayEnabled() },
        now: @escaping @Sendable () -> Date = { Date() },
        maxPills: Int = 4,
        ttl: TimeInterval = 4
    ) {
        self.isEnabled = isEnabled
        self.now = now
        self.state = PerfOverlayState(maxPills: maxPills, ttl: ttl)
    }

    /// Forward an already-measured, already-shipped span/hang. Dropped when the toggle
    /// is off. NEVER touches the sink — this is a pure read-only display side effect.
    public func record(label: String, ms: Int) {
        state.record(label: label, ms: ms, enabled: sessionOverrideEnabled ?? isEnabled(), now: now())
    }

    /// Sweep expired pills (drive on a ~1s UI tick so pills fade without new input).
    public func expireNow() { state.expire(now: now()) }

    public func dismiss(_ id: UUID) { state.dismiss(id) }

    /// Clear on demand (the toggle flipping OFF clears the screen immediately).
    public func clearAll() { state.clear() }

    /// Newest-first pills for the view.
    public var pills: [PerfPill] { state.display }
}
