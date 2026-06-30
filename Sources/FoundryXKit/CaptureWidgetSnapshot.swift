// CaptureWidgetSnapshot — the tiny, App-Group-shared capture-state snapshot the
// home/lock-screen WidgetKit widget reads. SHARED source: compiled into BOTH the app
// target (which WRITES it on capture transitions via `CaptureWidgetSnapshotStore`) and
// the widget extension (whose `TimelineProvider` READS it). The app and widget do not
// share memory, only this App-Group container, so the contract is a small Codable
// value persisted to `UserDefaults(suiteName:)`.
//
// Keep it minimal: current capture status + the last finished conversation. NO audio
// levels arrays, NO transcripts — the widget refresh budget is tight and the timeline
// only renders a status tile.

import Foundation

/// The minimal capture status the home-screen widget shows.
public struct CaptureWidgetSnapshot: Codable, Equatable, Sendable {
    /// True while a conversation is actively being captured (and not paused).
    public var isRecording: Bool
    /// True while capture is open but paused.
    public var isPaused: Bool
    /// Human source label ("Omi" / "Phone").
    public var sourceLabel: String
    /// SF Symbol for the active source.
    public var sourceSymbol: String
    /// When the active conversation started (for an elapsed display). nil when idle.
    public var startedAt: Date?
    /// The most-recently finished conversation's display title (shown when idle).
    public var lastFinishedTitle: String?
    /// When that last conversation finished.
    public var lastFinishedAt: Date?
    /// When this snapshot was written — lets the widget show staleness / pick a freshness.
    public var updatedAt: Date

    public init(isRecording: Bool = false,
                isPaused: Bool = false,
                sourceLabel: String = "Phone",
                sourceSymbol: String = "mic.fill",
                startedAt: Date? = nil,
                lastFinishedTitle: String? = nil,
                lastFinishedAt: Date? = nil,
                updatedAt: Date = Date()) {
        self.isRecording = isRecording
        self.isPaused = isPaused
        self.sourceLabel = sourceLabel
        self.sourceSymbol = sourceSymbol
        self.startedAt = startedAt
        self.lastFinishedTitle = lastFinishedTitle
        self.lastFinishedAt = lastFinishedAt
        self.updatedAt = updatedAt
    }

    /// The idle placeholder shown before any capture has happened.
    public static let idle = CaptureWidgetSnapshot()
}

/// Read/write the snapshot through the shared App Group container. Both the app and
/// the widget extension MUST be members of this App Group (entitlement) for the handoff
/// to work; if the group is missing (mis-provisioned), reads/writes silently no-op and
/// the widget shows its placeholder rather than crashing.
public enum CaptureWidgetSnapshotStore {
    /// The App Group identifier shared by the app + widget extension. Must match the
    /// `com.apple.security.application-groups` entitlement in BOTH targets.
    public static let appGroupID = "group.com.goforgeit.foundryx"

    private static let key = "foundryx.capture.widget-snapshot"

    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: appGroupID)
    }

    /// Persist the latest snapshot for the widget to read. Cheap (one small JSON blob).
    public static func write(_ snapshot: CaptureWidgetSnapshot) {
        guard let defaults, let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: key)
    }

    /// The last snapshot the app wrote, or `.idle` when none exists yet / the group is
    /// unavailable.
    public static func read() -> CaptureWidgetSnapshot {
        guard let defaults,
              let data = defaults.data(forKey: key),
              let snap = try? JSONDecoder().decode(CaptureWidgetSnapshot.self, from: data)
        else { return .idle }
        return snap
    }
}
