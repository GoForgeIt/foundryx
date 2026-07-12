// AmbientNotifier — Tier-3 surface (first slice) for the ambient-intelligence lane
// (track 20260710T2030 v3). When the on-device gate surfaces a candidate, post a
// LOCAL notification so the user experiences the "I can help" moment while still
// recording (D4: v0 delivery is local, actively-recording only — no APNs yet).
//
// v0 is a NOTIFY-ONLY preview: tapping does not yet run anything (Tier 2 — owner
// check → FoundryX router → confirm card → kiln chat session — is the next slice).
// The `preview` path fires a sample so the user can feel the UX before a real
// trigger ever happens.
//
// App target (uses UserNotifications); FoundryXKit stays UI/OS-free.

import Foundation
import UserNotifications
// (FoundryXKit types are same-module — the App target compiles Sources/FoundryXKit directly)

/// Presents ambient notifications as BANNERS even while the app is foregrounded —
/// without this, iOS silently swallows local notifications when the app is open,
/// which is exactly the situation when the user is testing the lane with the app
/// in hand. Installed as the notification-center delegate at wiring time.
final class AmbientNotificationPresenter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = AmbientNotificationPresenter()

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}

enum AmbientNotifier {
    /// Ask once for notification permission (banner + sound) and install the
    /// foreground presenter. Best-effort — a denied user simply never sees ambient
    /// nudges; nothing else changes.
    static func requestAuthorizationIfNeeded() {
        let center = UNUserNotificationCenter.current()
        center.delegate = AmbientNotificationPresenter.shared
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
    }

    /// Post the ROUTED outcome of a real gate candidate — the notification carries
    /// the actual answer when the door found one in the user's memory.
    static func post(candidate: AmbientCandidate, outcome: AmbientRouteOutcome?) {
        let title: String
        let body: String
        switch (outcome?.route, outcome?.answer) {
        case ("lookup", .some(let answer)):
            title = "From your memory"
            body = answer
        case ("lookup", nil):
            title = "FoundryX"
            body = "You wanted to look something up — I checked your memory but didn't find it: “\(candidate.utterance)”"
        case ("agent", _):
            title = "You called your agent"
            body = candidate.summary.isEmpty ? candidate.utterance : candidate.summary
        case ("todo", _), ("workflow", _):
            title = "Noticed a to-do"
            body = candidate.summary.isEmpty ? candidate.utterance : candidate.summary
        default:
            // Door unreachable — still surface the raw moment honestly.
            title = "FoundryX"
            body = "\(candidate.summary.isEmpty ? "Something I can help with" : candidate.summary) — “\(candidate.utterance)”"
        }
        deliver(title: title, body: body, preview: false)
    }

    /// Fire a sample notification so the user can experience the surface before any
    /// real trigger (Settings → "Preview a notification"). Clearly marked PREVIEW.
    static func postPreview() {
        deliver(
            title: "FoundryX (preview)",
            body: "This is how I'll nudge you — e.g. when you say “I'll have to look that up,” I'll offer to find it from your memory.",
            preview: true)
    }

    private static func deliver(title: String, body: String, preview: Bool) {
        let center = UNUserNotificationCenter.current()
        let fire: () -> Void = {
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            content.userInfo = ["ambient": true, "preview": preview]
            let req = UNNotificationRequest(
                identifier: "ambient-\(UUID().uuidString)",
                content: content,
                trigger: UNTimeIntervalNotificationTrigger(timeInterval: 0.5, repeats: false))
            center.add(req)
        }
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                fire()
            case .notDetermined:
                center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                    if granted { fire() }
                }
            default:
                break   // denied — respect it
            }
        }
    }
}
