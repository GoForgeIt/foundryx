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

enum AmbientNotifier {
    /// Ask once for notification permission (banner + sound). Best-effort — a denied
    /// user simply never sees ambient nudges; nothing else changes.
    static func requestAuthorizationIfNeeded() {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
    }

    /// Post a notification for a real gate candidate.
    static func post(candidate: AmbientCandidate) {
        deliver(
            title: "FoundryX",
            body: "\(candidate.summary.isEmpty ? "Something I can help with" : candidate.summary) — “\(candidate.utterance)”",
            preview: false)
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
