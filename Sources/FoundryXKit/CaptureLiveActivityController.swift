// CaptureLiveActivityController — owns the lifecycle of the capture Live Activity from
// the APP side: request it when capture starts, update it on state changes (recording /
// level / source switch), and end it (→ a brief idle "last conversation" state) on
// stop/finalize. Lives in the app target (not the widget extension) — it calls
// `Activity.request/update/end`; the widget extension only RENDERS the attributes.
//
// v1 is IN-APP, NO PUSH: updates are driven locally while the app is in the foreground
// or its audio/BLE background session is alive. That is enough for the common capture
// session. Two hard iOS constraints are handled here:
//   1. Live Activities are gated by the user — every call is guarded by
//      `ActivityAuthorizationInfo().areActivitiesEnabled`.
//   2. A locally-updated Live Activity goes STALE after ~8 hours, and the system caps
//      how long it stays on screen. We set a `staleDate` so the UI can show a "tap to
//      refresh" affordance, and we DEFENSIVELY re-request if a still-recording session
//      outlives the activity. TODO(>8h all-day freshness): true multi-hour/all-day
//      freshness while backgrounded needs ActivityKit PUSH tokens delivered via the
//      relay/APNs (out of scope for v1) — the push-token seam is left below.

import Foundation

// `ActivityKit` is importable on macOS but its runtime types (`Activity`,
// `ActivityAuthorizationInfo`, `ActivityContent`) are iOS-only — so gate on `os(iOS)`,
// not just `canImport`, or the SwiftPM macOS build (tests/CI) fails to resolve them.
#if canImport(ActivityKit) && os(iOS)
import ActivityKit

@available(iOS 16.2, *)
@MainActor
public final class CaptureLiveActivityController {
    private var activity: Activity<CaptureActivityAttributes>?

    /// How long after the last update before the system treats the activity as stale.
    /// Picked below the ~8h ActivityKit ceiling so a long session gets a visible
    /// "refresh" cue (and our defensive re-request) before it silently freezes.
    private static let staleAfter: TimeInterval = 8 * 60 * 60 - 5 * 60   // ~7h55m

    public init() {}

    /// Whether the user has Live Activities enabled for this app. Cheap; call before
    /// every request/update so a disabled setting is a clean no-op (never a crash).
    public var areActivitiesEnabled: Bool {
        ActivityAuthorizationInfo().areActivitiesEnabled
    }

    /// Start (or, if one is somehow already live, refresh) the capture Live Activity.
    /// No-op when the user has Live Activities disabled.
    public func start(_ state: CaptureActivityAttributes.ContentState) {
        guard areActivitiesEnabled else { return }
        // If we lost our handle but one is still around (relaunch / defensive restart),
        // adopt it rather than stacking a second activity.
        if activity == nil, let existing = Activity<CaptureActivityAttributes>.activities.first {
            activity = existing
        }
        if let activity {
            update(state)   // already running — just push the new state
            _ = activity
            return
        }
        do {
            activity = try Activity.request(
                attributes: CaptureActivityAttributes(),
                content: .init(state: state, staleDate: Date().addingTimeInterval(Self.staleAfter)),
                // v1: no push token. Leaving `pushType: nil` keeps it local-update only.
                // TODO(push): pass `.token` here and forward the awaited
                // `activity.pushTokenUpdates` to the relay/APNs for >8h background
                // freshness.
                pushType: nil)
        } catch {
            // A request failure (disabled mid-flight, too many activities) must never
            // affect capture — just leave the activity unstarted.
            activity = nil
        }
    }

    /// Push a new content state to the live activity. If the session is still recording
    /// but the activity has gone (ended/stale-expired), defensively re-request so a long
    /// session keeps a visible indicator.
    public func update(_ state: CaptureActivityAttributes.ContentState) {
        guard areActivitiesEnabled else { return }
        guard let activity else {
            if state.isRecording { start(state) }   // resurrect a dropped activity
            return
        }
        Task {
            await activity.update(
                .init(state: state, staleDate: Date().addingTimeInterval(Self.staleAfter)))
        }
    }

    /// End the Live Activity, optionally leaving a final "last conversation" state on
    /// screen briefly (the system dismisses it per `dismissalPolicy`). Call on capture
    /// stop / finalize.
    public func end(final state: CaptureActivityAttributes.ContentState,
                    dismissAfter: TimeInterval = 30) {
        guard let activity else { return }
        let handle = activity
        self.activity = nil
        Task {
            await handle.end(
                .init(state: state, staleDate: nil),
                dismissalPolicy: .after(Date().addingTimeInterval(dismissAfter)))
        }
    }

    /// Immediately tear down any live activity (e.g. on hard reset). Idempotent.
    public func endImmediately() {
        guard let activity else { return }
        let handle = activity
        self.activity = nil
        Task { await handle.end(nil, dismissalPolicy: .immediate) }
    }
}
#endif
