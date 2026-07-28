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
final class AmbientNotificationPresenter: NSObject, UNUserNotificationCenterDelegate, Sendable {
    static let shared = AmbientNotificationPresenter()

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    /// Card responses: RUN (or tapping the banner) seeds a kiln chat with the moment;
    /// DISMISS just logs the outcome (the council's labeled false positive).
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let info = response.notification.request.content.userInfo
        let ownerScope = info["accountScope"] as? String
        let ownerGeneration = (info["accountGeneration"] as? NSNumber)?.uint64Value
        guard let responseBinding = AmbientNotifier.currentBinding(
            scope: ownerScope, generation: ownerGeneration) else {
            completionHandler()
            return
        }
        let seed = info["seed"] as? String
        switch response.actionIdentifier {
        case AmbientNotifier.runAction, UNNotificationDefaultActionIdentifier:
            if let answerText = info["answerText"] as? String {
                // A delivered ANSWER: tapping opens the full answer surface
                // (features/ambient-answer-loop.feature), not a chat seed.
                let answer = AmbientAnswer(
                    title: info["answerTitle"] as? String ?? "From your memory",
                    text: answerText)
                Task { @MainActor in
                    CaptureAccountScope.perform(as: responseBinding) { _ in
                        AmbientCardBroker.shared.showAnswer(answer)
                    }
                }
            } else if let seed {
                // The payload carries the source conversation — the seeded
                // chat's provenance keeps it (EXT3).
                let captureId = info["captureId"] as? String
                Task { @MainActor in
                    AmbientCardBroker.shared.run(
                        seed: seed, captureId: captureId,
                        binding: responseBinding)
                }
            }
        case AmbientNotifier.dismissAction, UNNotificationDismissActionIdentifier:
            if let seed {
                AmbientCardBroker.dismissed(
                    seed: seed, binding: responseBinding)
            }
        default:
            break
        }
        completionHandler()
    }
}

enum AmbientNotifier {
    static let cardCategory = "AMBIENT_CARD"
    static let runAction = "AMBIENT_RUN"
    static let dismissAction = "AMBIENT_DISMISS"
    private static let ownerScopeKey = "accountScope"
    private static let ownerGenerationKey = "accountGeneration"

    /// Withdraw every queued or already-visible account notification immediately.
    /// Any callback already in flight also rechecks its captured AccountBinding.
    static func clearForIdentityTransition() {
        let center = UNUserNotificationCenter.current()
        center.removeAllPendingNotificationRequests()
        center.removeAllDeliveredNotifications()
    }

    static func isCurrentOwner(_ userInfo: [AnyHashable: Any]) -> Bool {
        isCurrentOwner(
            scope: userInfo[ownerScopeKey] as? String,
            generation: (userInfo[ownerGenerationKey] as? NSNumber)?.uint64Value)
    }

    static func isCurrentOwner(scope: String?, generation: UInt64?) -> Bool {
        currentBinding(scope: scope, generation: generation) != nil
    }

    static func currentBinding(
        scope: String?, generation: UInt64?
    ) -> CaptureAccountScope.AccountBinding? {
        guard let expectedScope = scope,
              let expectedGeneration = generation,
              let binding = CaptureAccountScope.currentAccountBinding() else {
            return nil
        }
        guard binding.scope == expectedScope
            && binding.generation == expectedGeneration
            && binding.isCurrent else { return nil }
        return binding
    }

    /// Ask once for notification permission (banner + sound), install the foreground
    /// presenter, and register the confirm-card category (Run/Dismiss). Best-effort —
    /// a denied user simply never sees ambient nudges; nothing else changes.
    static func requestAuthorizationIfNeeded() {
        #if DEBUG
        // Screen-proof harness: never raise the OS permission prompt (it would cover a
        // screenshot). No effect on a normal launch.
        if ProcessInfo.processInfo.arguments.contains(where: { $0.hasSuffix("Preview") }) { return }
        #endif
        let center = UNUserNotificationCenter.current()
        center.delegate = AmbientNotificationPresenter.shared
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: cardCategory,
                actions: [
                    UNNotificationAction(identifier: runAction, title: "Run",
                                         options: [.foreground]),
                    UNNotificationAction(identifier: dismissAction, title: "Dismiss",
                                         options: []),
                ],
                intentIdentifiers: [], options: [.customDismissAction]),
        ])
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
    }

    /// Post the ROUTED outcome of a real gate candidate. Lookups notify with the
    /// actual answer from the user's memory (informational). todo/playbook/workflow/agent
    /// become CONFIRM CARDS — "Want me to X?" with Run/Dismiss; Run seeds a kiln
    /// chat with the moment (nothing executes without it).
    static func post(candidate: AmbientCandidate, outcome: AmbientRouteOutcome?,
                     captureId: String? = nil,
                     binding: CaptureAccountScope.AccountBinding) {
        guard binding.isCurrent else { return }
        let title: String
        let body: String
        var seed: String?
        var answerPayload: String?
        let ask = candidate.summary.isEmpty ? candidate.utterance : candidate.summary
        switch (outcome?.route, outcome?.answer) {
        case ("lookup", .some(let answer)):
            title = "From your memory"
            body = answer
            answerPayload = answer
            // The delivery is a real event: remember it in the activity ledger
            // (features/ambient-answer-loop.feature).
            logAnswerDelivered(answer: answer, utterance: candidate.utterance,
                               captureId: captureId, binding: binding)
        case ("lookup", nil):
            title = "FoundryX"
            body = "You wanted to look something up — I checked your memory but didn't find it: “\(candidate.utterance)”"
        case ("agent", _):
            // OWNER GATE: an agent command whose voice did NOT match the enrolled
            // owner is offered to NO ONE (a bystander/TV saying the agent's name
            // commands nothing). Suppressed silently, logged for the council.
            guard outcome?.ownerVerified == true else {
                AmbientCardBroker.dismissed(
                    seed: "owner-unverified: \(candidate.utterance)",
                    binding: binding)
                return
            }
            title = "You called your agent"
            body = "Want me to: \(ask)?"
            seed = chatSeed(candidate)
        case ("playbook", _):
            title = "Noticed a to-do"
            if let pick = outcome?.playbook {
                body = "Run the “\(pick.kind)” playbook?"
                seed = playbookSeed(candidate, pick)
            } else {
                // No specific pick means a plain confirm card. Never ask the chat
                // to execute a playbook the door could not name.
                body = "Want me to: \(ask)?"
                seed = chatSeed(candidate)
            }
        // The door routes a repeatable moment as `playbook` (renamed from the
        // retired `workflow` term). Match `workflow` as a transitional generic
        // alias during rollout; it carries no selected playbook.
        case ("todo", _), ("workflow", _):
            title = "Noticed a to-do"
            body = "Want me to: \(ask)?"
            seed = chatSeed(candidate)
        default:
            // Door unreachable — still surface the raw moment honestly, and let a
            // tap seed a chat (the chat itself will fail honestly if the door is down).
            title = "FoundryX"
            body = "\(candidate.summary.isEmpty ? "Something I can help with" : candidate.summary) — “\(candidate.utterance)”"
            seed = chatSeed(candidate)
        }
        guard binding.isCurrent else { return }
        deliver(title: title, body: body, preview: false, seed: seed,
                answerText: answerPayload, captureId: captureId, binding: binding)
    }

    /// One JSONL line per delivered answer — what the activity ledger reads
    /// (ActivityStore.answersLogURL; same append pattern as the other logs).
    private static func logAnswerDelivered(answer: String, utterance: String,
                                           captureId: String?,
                                           binding: CaptureAccountScope.AccountBinding) {
        var obj: [String: Any] = [
            "ts": Int(Date().timeIntervalSince1970),
            "kind": "answer",
            "answer": String(answer.prefix(500)),
            "utterance": String(utterance.prefix(300)),
        ]
        if let captureId, !captureId.isEmpty { obj["captureId"] = captureId }
        guard let line = try? JSONSerialization.data(withJSONObject: obj) else { return }
        var out = line
        out.append(UInt8(ascii: "\n"))
        CaptureAccountScope.perform(as: binding) { captured in
            let url = captured.root.appendingPathComponent("ambient-answers.jsonl")
            if let h = try? FileHandle(forWritingTo: url) {
                defer { try? h.close() }
                _ = try? h.seekToEnd()
                try? h.write(contentsOf: out)
            } else {
                try? out.write(to: url)
            }
        }
    }

    /// The first chat turn an accepted card sends — the moment + the ask, so the
    /// agent has the context the user's own ears had.
    private static func chatSeed(_ c: AmbientCandidate) -> String {
        "While I was taking a note, this came up: “\(c.utterance)”\n\nPlease \(c.summary.isEmpty ? "help with that" : c.summary)."
    }

    private static func playbookSeed(_ c: AmbientCandidate,
                                     _ pick: AmbientPlaybookPick) -> String {
        "While I was taking a note, this came up: “\(c.utterance)”.\n\nThis looks like the “\(pick.kind)” playbook — \(pick.reason).\n\nPlease run it, and tell me which playbook you're running and why as you go."
    }

    /// Fire a sample notification so the user can experience the surface before any
    /// real trigger (Settings → "Preview a notification"). Clearly marked PREVIEW.
    static func postPreview() {
        // A persona-relatable sample (family for individual, a client for the
        // expert, a team pattern for the firm) so the nudge lands for whoever
        // is here — not a generic placeholder.
        guard let binding = CaptureAccountScope.currentAccountBinding() else { return }
        let ex = PersonaCopy.notificationExample(for: PersonaPrefs.persona())
        deliver(title: ex.title, body: ex.body, preview: true, binding: binding)
    }

    private static func deliver(title: String, body: String, preview: Bool,
                                seed: String? = nil, answerText: String? = nil,
                                captureId: String? = nil,
                                binding: CaptureAccountScope.AccountBinding) {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains(where: { $0.hasSuffix("Preview") }) { return }   // screen-proof: no OS prompts
        #endif
        let center = UNUserNotificationCenter.current()
        let fire: () -> Void = {
            CaptureAccountScope.perform(as: binding) { captured in
                let content = UNMutableNotificationContent()
                content.title = title
                content.body = body
                content.sound = .default
                content.userInfo = [
                    "ambient": true,
                    "preview": preview,
                    ownerScopeKey: captured.scope,
                    ownerGenerationKey: NSNumber(value: captured.generation),
                ]
                if let captureId, !captureId.isEmpty {
                    content.userInfo["captureId"] = captureId
                }
                if let seed {
                    content.categoryIdentifier = cardCategory
                    content.userInfo["seed"] = seed
                }
                if let answerText {
                    content.userInfo["answerText"] = answerText
                    content.userInfo["answerTitle"] = title
                }
                let req = UNNotificationRequest(
                    identifier: "ambient-\(UUID().uuidString)",
                    content: content,
                    trigger: UNTimeIntervalNotificationTrigger(
                        timeInterval: 0.5, repeats: false))
                center.add(req) { _ in
                    // `add` is asynchronous. If a transition raced the request after
                    // the transition's bulk clear, withdraw this exact stale request.
                    guard !binding.isCurrent else { return }
                    center.removePendingNotificationRequests(
                        withIdentifiers: [req.identifier])
                    center.removeDeliveredNotifications(
                        withIdentifiers: [req.identifier])
                }
            }
        }
        center.getNotificationSettings { settings in
            guard CaptureAccountScope.perform(
                as: binding, { _ in true }) == true else { return }
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
