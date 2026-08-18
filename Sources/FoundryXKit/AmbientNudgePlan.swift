// AmbientNudgePlan — the sample nudge's DECISIONS, in a type a test can execute.
//
// WHY THIS FILE EXISTS.
//
// `swift test` compiles the SPM package only; it cannot compile `App/`. So every decision
// written inside `App/AmbientNotifier.swift` was held by tests that read that file AS TEXT —
// `deliver.contains("report?(.refused)")` and friends. A `contains()` over source is
// satisfied by a string being PRESENT, which says nothing about which value the running
// program produces. That was measured, not suspected: three one-line mutations to the
// shipped fix all passed 1536/1536.
//
//   * reinstating `guard let binding = CaptureAccountScope.currentAccountBinding()
//     else { return }` at the top of `postPreview` — the exact original defect, where the
//     step announced "We just sent a sample nudge" and nothing had been sent — GREEN.
//   * changing the denial arm from `report?(.refused)` to `report?(.scheduled)`, so a user
//     who taps "Don't Allow" is told to check their lock screen — GREEN, because the
//     banned/required string was still present on an untouched `default:` line.
//   * inserting a silent `guard let bindingSnapshot = binding else { return }` into
//     `deliver` — GREEN, laundered by an exemption that matched any identifier beginning
//     "binding".
//
// The fix is not a better grep. Every branch below used to live in a closure inside
// `AmbientNotifier.deliver`, where nothing could run it. Here it is an ordinary function
// over ordinary values, so the honest answer for each situation is asserted by EXECUTING
// the decision — and any edit that changes an answer turns a test red no matter how it is
// spelled. `App/AmbientNotifier.swift` is now a translation layer: it turns
// `UNUserNotificationCenter`'s answers into these values, asks this type what to do, and
// does exactly that.

import Foundation

/// Notification permission as this app must reason about it.
///
/// `UNAuthorizationStatus` is a UserNotifications type and FoundryXKit stays OS-free, so
/// the App-side seam maps onto this. The mapping is deliberately TOTAL: an unrecognised
/// future status becomes `.denied`, because the only safe assumption about a status we do
/// not understand is that iOS will not show the nudge — and claiming a send we cannot
/// verify is the whole defect this lane exists for.
public enum AmbientNudgePermission: String, Sendable, Equatable, CaseIterable {
    /// The user has said yes.
    case authorized
    /// Quiet delivery, granted without a prompt. iOS will accept the request.
    case provisional
    /// App Clip-style temporary authorization. iOS will accept the request.
    case ephemeral
    /// Nobody has asked yet. On a first run this is the status at the ambient step.
    case notDetermined
    /// The user has said no, or the status is one this build does not recognise.
    case denied
}

/// What the delivery path must do next.
public enum AmbientNudgeStep: Sendable, Equatable {
    /// Raise the one OS permission prompt and come back with `afterAsking(granted:)`.
    case ask
    /// Hand a notification request to iOS and come back with
    /// `afterHandingToSystem(accepted:)`.
    case schedule
    /// Stop. Tell the caller exactly this, and never claim anything else.
    case report(AmbientNudgeAttempt)
}

/// The sample-nudge decisions, as values rather than as control flow inside a closure the
/// test suite cannot enter.
public enum AmbientNudgePlan {

    /// The decision taken once the notification settings have come back.
    ///
    /// - Parameters:
    ///   - permission: what iOS says the app is allowed to do.
    ///   - isPreview: the sample nudge, which carries no user content, no seed and no tap
    ///     payload — the one delivery that may legitimately go out with no account bound,
    ///     because the step that fires it runs BEFORE any account exists. That is not a
    ///     loosening: it is the reason the original guard was wrong.
    ///   - hasBinding: whether an account binding was supplied.
    ///   - bindingIsCurrent: whether that binding is still the current identity. A binding
    ///     that has moved out from under the request may not be used and may not be
    ///     reported as a send.
    public static func firstStep(permission: AmbientNudgePermission,
                                 isPreview: Bool,
                                 hasBinding: Bool,
                                 bindingIsCurrent: Bool) -> AmbientNudgeStep {
        // A REAL notification carries the user's own words and a tap payload that acts on
        // their account. It may not go out unbound. The sample may.
        guard isPreview || hasBinding else { return .report(.unavailable) }
        // The identity moved between the settings read and here. Nothing may be scheduled
        // against it, and nothing may be claimed.
        if hasBinding && !bindingIsCurrent { return .report(.unavailable) }
        switch permission {
        case .authorized, .provisional, .ephemeral:
            return .schedule
        case .notDetermined:
            // ASK HERE. Authorization used to be requested only from `RootView`, anonymously
            // at launch, which meant the step that PROMISES a notification was never the
            // step that asked — and on a first run the status here is `.notDetermined`, so
            // iOS dropped the nudge while the screen said one had gone out.
            return .ask
        case .denied:
            // Respect it, and SAY it. Never silence, and never a claimed send.
            return .report(.refused)
        }
    }

    /// The decision taken once the user has answered the OS prompt.
    ///
    /// A denial is `.refused` and NOTHING else. The mutation that made this `.scheduled`
    /// told a user who had just tapped "Don't Allow" to go and check their lock screen.
    public static func afterAsking(granted: Bool) -> AmbientNudgeStep {
        granted ? .schedule : .report(.refused)
    }

    /// The decision taken once the request has been handed to iOS.
    ///
    /// `.scheduled` is the ONLY outcome that may claim a nudge was sent, and it is reachable
    /// only from here — after iOS accepted a real request.
    public static func afterHandingToSystem(accepted: Bool) -> AmbientNudgeAttempt {
        accepted ? .scheduled : .unavailable
    }

    /// The outcome when the app cannot even reach the notification centre — the screen-proof
    /// harness, which must never raise an OS prompt over a screenshot. Nothing was scheduled,
    /// so say so rather than letting the caller claim a nudge it never got.
    public static let whenTheCentreIsUnreachable: AmbientNudgeAttempt = .unavailable

    /// Every outcome that is allowed to claim a delivery. Exactly one.
    public static var outcomesThatMayClaimASend: [AmbientNudgeAttempt] { [.scheduled] }
}
