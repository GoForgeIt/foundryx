// EveningRecapScheduler — a quiet, opt-in nightly local notification that surfaces the
// day's recap ("Your day, distilled — 4 conversations, 47 min"). THIN CLIENT: the copy is
// built purely from `TodayRecap.load()` (count + format of on-disk data), never analysis.
//
// v1 shape:
//   • A single repeating daily `UNCalendarNotificationTrigger` at the user's set time
//     (default 20:00), keyed by one stable identifier so a reschedule replaces in place.
//   • Substance-gated: we NEVER schedule for zero captures — a day with nothing captured
//     stays silent rather than firing an empty "your day" nudge.
//   • Content reflects the recap AT SCHEDULE TIME; `reschedule()` runs from InsightsView's
//     .task/.onAppear, so opening the app refreshes the pending notification with the
//     current day's numbers. (A truly per-day-fresh body is backend/notification-service
//     work; this is the honest local v1.)
//   • Permission is requested only on the FIRST toggle-on (via requestAuthorizationAnd
//     Reschedule); routine reschedules never prompt and no-op unless already authorized.
//
// Tapping the notification just opens the app (v1 — no deep userInfo routing yet).
//
// Not actor-isolated: UNUserNotificationCenter + UserDefaults are thread-safe and
// TodayRecap.load() is a pure nonisolated loader, so these entry points are safe to call
// from InsightsView's main-actor .task/.onAppear (nonisolated is always callable there).

import Foundation
import UserNotifications

enum EveningRecapScheduler {
    // MARK: settings (UserDefaults-backed; the InsightsView toggle/time-picker bind these)

    /// Whether the nightly recap is on. Default OFF — it's opt-in so we only ask for
    /// notification permission when the user turns it on.
    static let enabledKey = "foundryx.eveningRecap.enabled"
    /// The fire time as minutes-since-local-midnight (so it survives a plist round-trip
    /// cleanly). Default 1200 = 20:00.
    static let minutesKey = "foundryx.eveningRecap.minutesSinceMidnight"
    static let defaultMinutes = 20 * 60

    /// The single pending-request identifier — one reschedule replaces the prior one.
    private static let requestId = "foundryx.eveningRecap.daily"

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

    static var minutesSinceMidnight: Int {
        (UserDefaults.standard.object(forKey: minutesKey) as? Int) ?? defaultMinutes
    }

    // MARK: scheduling

    /// First toggle-on path: request notification permission if still undetermined, then
    /// schedule. Called ONLY from the toggle's flip-to-on so a routine appear never prompts.
    static func requestAuthorizationAndReschedule() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        if settings.authorizationStatus == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
        }
        await reschedule()
    }

    /// Idempotent: clear the pending recap, then re-add it IF it's enabled, we're
    /// authorized, and today actually has captures (the substance gate). Safe to call from
    /// every InsightsView appear.
    static func reschedule() async {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [requestId])

        guard isEnabled else { return }
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .provisional else { return }

        // Substance gate — build today's recap off the main actor; never schedule for zero.
        let recap = await Task.detached { TodayRecap.load() }.value
        guard recap.conversationCount > 0 else { return }

        let content = UNMutableNotificationContent()
        content.title = "Your day, distilled"
        content.body = recapBody(recap)
        content.sound = .default

        let mins = minutesSinceMidnight
        var when = DateComponents()
        when.hour = mins / 60
        when.minute = mins % 60
        let trigger = UNCalendarNotificationTrigger(dateMatching: when, repeats: true)
        let request = UNNotificationRequest(identifier: requestId, content: content, trigger: trigger)
        // Completion-handler form (not `await add`): keeps the freshly-built request on the
        // main actor so strict concurrency has nothing to send; delivery errors are advisory.
        center.add(request) { _ in }
    }

    /// Turn the recap off — drop the pending notification. Called on toggle-off.
    static func cancel() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [requestId])
    }

    // MARK: copy

    /// "4 conversations, 47 min" — the calm, plainspoken recap line. Minutes are dropped
    /// when the day has no derivable duration (honest degradation).
    static func recapBody(_ recap: TodayRecap) -> String {
        let n = recap.conversationCount
        let convo = "\(n) conversation\(n == 1 ? "" : "s")"
        if let m = recap.totalMinutes { return "\(convo), \(m) min" }
        return convo
    }
}
