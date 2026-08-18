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

/// THE NOTIFICATION CENTRE, AS THE SIX THINGS THIS FILE DOES TO IT.
///
/// `UNUserNotificationCenter` is a final ObjC class with a private initialiser, so nothing
/// in a test can stand in for it. That is not a small inconvenience: it is why every guard
/// over this file was a `contains()` over its own source text, and why three separate
/// one-line mutations to the delivery path — including one that told a user who had just
/// tapped "Don't Allow" to go and check their lock screen — shipped 1536/1536 green.
///
/// This protocol is the seam. Production runs `LiveAmbientNotificationCentre`, a direct
/// forward to `UNUserNotificationCenter.current()` that holds no decisions at all;
/// `Tests/FoundryXAppScenarioTests` substitutes a scripted one and can then assert what the
/// phone was actually asked and actually handed — a count, not a spelling.
protocol AmbientNotificationCentre: Sendable {
    /// Install the foreground presenter and the confirm-card actions. PROMPTS FOR NOTHING.
    func installSurface(delegate: UNUserNotificationCenterDelegate,
                        categories: Set<UNNotificationCategory>)
    /// What iOS currently allows.
    func permission(_ completion: @escaping @Sendable (AmbientNudgePermission) -> Void)
    /// Raise the one OS permission prompt. `true` iff the user granted it.
    func ask(_ completion: @escaping @Sendable (Bool) -> Void)
    /// Hand a request to iOS. `true` iff iOS accepted it — the ONLY evidence that permits
    /// the word "sent".
    func hand(_ request: UNNotificationRequest,
              _ completion: @escaping @Sendable (Bool) -> Void)
    /// Withdraw specific requests (a scope that moved under an in-flight `add`).
    func withdraw(identifiers: [String])
    /// Withdraw everything — the identity transition.
    func withdrawEverything()
}

/// The production centre. Deliberately decision-free: every branch worth testing lives in
/// `AmbientNudgePlan`, so there is nothing here for a test to have missed.
struct LiveAmbientNotificationCentre: AmbientNotificationCentre {
    static let shared = LiveAmbientNotificationCentre()
    private var centre: UNUserNotificationCenter { .current() }

    func installSurface(delegate: UNUserNotificationCenterDelegate,
                        categories: Set<UNNotificationCategory>) {
        let c = centre
        c.delegate = delegate
        c.setNotificationCategories(categories)
    }

    func permission(_ completion: @escaping @Sendable (AmbientNudgePermission) -> Void) {
        centre.getNotificationSettings { completion(AmbientNudgePermission($0.authorizationStatus)) }
    }

    func ask(_ completion: @escaping @Sendable (Bool) -> Void) {
        centre.requestAuthorization(options: [.alert, .sound]) { granted, _ in completion(granted) }
    }

    func hand(_ request: UNNotificationRequest,
              _ completion: @escaping @Sendable (Bool) -> Void) {
        centre.add(request) { completion($0 == nil) }
    }

    func withdraw(identifiers: [String]) {
        let c = centre
        c.removePendingNotificationRequests(withIdentifiers: identifiers)
        c.removeDeliveredNotifications(withIdentifiers: identifiers)
    }

    func withdrawEverything() {
        let c = centre
        c.removeAllPendingNotificationRequests()
        c.removeAllDeliveredNotifications()
    }
}

extension AmbientNudgePermission {
    /// TOTAL by construction. `@unknown default` becomes `.denied` because the only safe
    /// assumption about a status this build does not understand is that iOS will not show
    /// the nudge, and claiming a send we cannot verify is the defect this lane exists for.
    init(_ status: UNAuthorizationStatus) {
        switch status {
        case .authorized:    self = .authorized
        case .provisional:   self = .provisional
        case .ephemeral:     self = .ephemeral
        case .notDetermined: self = .notDetermined
        case .denied:        self = .denied
        @unknown default:    self = .denied
        }
    }
}

enum AmbientNotifier {
    static let cardCategory = "AMBIENT_CARD"
    static let runAction = "AMBIENT_RUN"
    static let dismissAction = "AMBIENT_DISMISS"
    private static let ownerScopeKey = "accountScope"
    private static let ownerGenerationKey = "accountGeneration"

    #if DEBUG
    /// The scripted centre `Tests/FoundryXAppScenarioTests` installs. Same sanctioned shape
    /// as `PocketRecorderCheckModel.attachmentFactoryForScenarios` — `#if DEBUG`, so
    /// `scripts/ci-gates.sh phase_leak` compiles it out of Release entirely.
    nonisolated(unsafe) static var notificationCentreForScenarios: AmbientNotificationCentre?
    #endif

    /// The one place this file reaches the OS. Every other function goes through here, so a
    /// scenario that installs a scripted centre sees EVERY call the app makes.
    static var centre: AmbientNotificationCentre {
        #if DEBUG
        if let scripted = notificationCentreForScenarios { return scripted }
        #endif
        return LiveAmbientNotificationCentre.shared
    }

    /// Withdraw every queued or already-visible account notification immediately.
    /// Any callback already in flight also rechecks its captured AccountBinding.
    static func clearForIdentityTransition() {
        centre.withdrawEverything()
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

    /// Install the foreground presenter and register the confirm-card category
    /// (Run/Dismiss). Idempotent, and it PROMPTS FOR NOTHING — the permission prompt
    /// belongs to whichever surface promises the user a notification, so it can report
    /// what the user answered instead of firing anonymously at launch.
    ///
    /// The presenter matters as much as the permission: without it iOS silently swallows
    /// a local notification while the app is foregrounded, which is exactly the situation
    /// during onboarding, with the phone in the user's hand.
    static func installNotificationSurface() {
        #if DEBUG
        // Screen-proof harness: never touch the notification centre (a prompt would cover
        // a screenshot). No effect on a normal launch.
        if isScreenProofHarness { return }
        #endif
        centre.installSurface(
            delegate: AmbientNotificationPresenter.shared,
            categories: [
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
    }

    // `requestAuthorizationIfNeeded` USED TO LIVE HERE, and `RootView` called it
    // unconditionally on every launch (`App/RootView.swift`, the `#else` shipping arm of a
    // `#if DEBUG || PERF_HARNESS`). RootView also HOSTS onboarding, as a `.fullScreenCover`,
    // so RootView ran first: the OS prompt appeared before the user had been told what a
    // notification from this app would even be for, and the ambient step's promise —
    // "and ask for notification permission HERE, at the step that promises one" — was dead
    // code in practice, because by the time the step ran the status was no longer
    // `.notDetermined`.
    //
    // It is DELETED rather than left unused. An unused function is one line away from being
    // called again, and the only permission prompt this app may raise is one raised by
    // `deliver`, which reports what the user answered to the surface that made the promise.
    // `installNotificationSurface` above is what launch calls now: it installs the presenter
    // and the card actions and touches authorization not at all.

    #if DEBUG
    /// The screen-proof harness (`-…Preview` launch arguments). Compiled out of Release.
    private static var isScreenProofHarness: Bool {
        ProcessInfo.processInfo.arguments.contains(where: { $0.hasSuffix("Preview") })
    }
    #endif

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
            title = "Solleva"
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
            title = "Solleva"
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
    /// real trigger (onboarding's ambient step, and Settings → "Preview a notification").
    /// Clearly marked PREVIEW.
    ///
    /// It REPORTS. This used to open with
    /// `guard let binding = CaptureAccountScope.currentAccountBinding() else { return }`,
    /// which during onboarding — when no account is bound — posted nothing and returned
    /// silently, while the caller announced "We just sent a sample nudge" on the very next
    /// line. That is the `CaptureWAL.performDurableMutation` shape: a guard that swallows
    /// the work and lets the caller claim it happened. Now every path ends in exactly one
    /// `report`, and the caller renders `OnboardingAmbientStepCopy.confirmation(for:)`.
    ///
    /// It also ASKS, here, at the step that promises the notification — and that is now
    /// true rather than merely intended. Authorization used to be requested by `RootView`
    /// on every launch, anonymously, and RootView is what HOSTS onboarding, so RootView ran
    /// first and the status here was no longer `.notDetermined` by the time the step that
    /// promised a notification got to ask. That launch prompt is deleted;
    /// `installNotificationSurface` puts the foreground presenter in place (without it iOS
    /// swallows the banner while the app is open, which is exactly the situation during
    /// onboarding) and `deliver` raises the single permission prompt and reports the
    /// user's answer.
    static func postPreview(
        report: @escaping @Sendable (AmbientNudgeAttempt) -> Void = { _ in }
    ) {
        installNotificationSurface()
        // A persona-relatable sample (family for individual, a client for the
        // expert, a team pattern for the firm) so the nudge lands for whoever
        // is here — not a generic placeholder.
        let ex = PersonaCopy.notificationExample(for: PersonaPrefs.persona())
        // The binding is OPTIONAL for the sample: it carries no user content, no seed and
        // no tap payload, so there is nothing for an account scope to protect — and the
        // step that fires it runs before any account exists.
        deliver(title: ex.title, body: ex.body, preview: true,
                binding: CaptureAccountScope.currentAccountBinding(),
                report: report)
    }

    /// `binding` is optional for ONE case only: the sample preview, which carries no user
    /// content, no seed and no tap payload. Every other caller passes a real binding and
    /// the account-scoped behaviour below is unchanged. `report`, when supplied, is called
    /// EXACTLY ONCE on every path — including the paths that used to `return` in silence.
    /// EVERY BRANCH BELOW IS `AmbientNudgePlan`'s, NOT THIS FUNCTION'S.
    ///
    /// This used to decide for itself, inside a closure handed to
    /// `UNUserNotificationCenter.getNotificationSettings` — a place no test in this
    /// repository can enter. So the guards over it read its own source text, and a
    /// one-character change from `report?(.refused)` to `report?(.scheduled)` on the
    /// permission-denied arm shipped green, because the banned string was still present on
    /// an untouched line. What is left here is translation and side effects: ask the plan,
    /// do what it says. Change an answer and `AmbientNudgePlanTests` goes red on `swift
    /// test`; change the wiring and the app-hosted scenario goes red on a simulator.
    private static func deliver(title: String, body: String, preview: Bool,
                                seed: String? = nil, answerText: String? = nil,
                                captureId: String? = nil,
                                binding: CaptureAccountScope.AccountBinding?,
                                report: (@Sendable (AmbientNudgeAttempt) -> Void)? = nil) {
        #if DEBUG
        if isScreenProofHarness {
            // Screen-proof harness: no OS prompts. Nothing was scheduled, so say so
            // rather than letting the caller claim a nudge it never got.
            report?(AmbientNudgePlan.whenTheCentreIsUnreachable)
            return
        }
        #endif
        let centre = self.centre
        let schedule: @Sendable (String?, UInt64?) -> Void = { ownerScope, ownerGeneration in
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            content.userInfo = ["ambient": true, "preview": preview]
            if let ownerScope, let ownerGeneration {
                content.userInfo[ownerScopeKey] = ownerScope
                content.userInfo[ownerGenerationKey] = NSNumber(value: ownerGeneration)
            }
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
            // `UNNotificationRequest` is not Sendable, so the completion carries the
            // IDENTIFIER rather than the request it belongs to.
            let identifier = req.identifier
            centre.hand(req) { accepted in
                report?(AmbientNudgePlan.afterHandingToSystem(accepted: accepted))
                guard accepted else { return }
                // `hand` is asynchronous. If a transition raced the request after
                // the transition's bulk clear, withdraw this exact stale request.
                guard let binding, !binding.isCurrent else { return }
                centre.withdraw(identifiers: [identifier])
            }
        }
        // NO BARE `return` BELOW, deliberately. The guard that every exit from this function
        // reports first reads the source, and it used to carry an exemption for
        // `guard let binding` — which matched any identifier beginning "binding" and
        // laundered a planted silent return straight through a green suite. The exemption is
        // gone, so this code owes it no special case.
        let fire: @Sendable () -> Void = {
            guard let binding else { return schedule(nil, nil) }   // unbound sample
            let ran = CaptureAccountScope.perform(as: binding) { captured in
                schedule(captured.scope, captured.generation)
            }
            // The identity moved out from under the request between the settings read and
            // here. Nothing was scheduled.
            if ran == nil { report?(.unavailable) }
        }
        // The plan asks at most once, so a `.ask` arriving here scheduled nothing — and a
        // path that scheduled nothing may not claim a send.
        let settle: @Sendable (AmbientNudgeStep) -> Void = { step in
            switch step {
            case .schedule: fire()
            case .report(let outcome): report?(outcome)
            case .ask: report?(.unavailable)
            }
        }
        centre.permission { permission in
            let step = AmbientNudgePlan.firstStep(
                permission: permission,
                isPreview: preview,
                hasBinding: binding != nil,
                bindingIsCurrent: binding.map {
                    CaptureAccountScope.perform(as: $0, { _ in true }) == true
                } ?? false)
            if step == .ask {
                centre.ask { granted in settle(AmbientNudgePlan.afterAsking(granted: granted)) }
            } else {
                settle(step)
            }
        }
    }
}
