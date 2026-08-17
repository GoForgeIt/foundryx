import XCTest
import Foundation
import BrineSwiftCore
@testable import FoundryXKit

/// Brine driver for features/onboarding-ambient-nudge-honesty.feature.
///
/// The steps drive the REAL decision — `OnboardingAmbientStepCopy.confirmation(for:)`,
/// which is what `App/OnboardingFlowView.swift` renders — plus the real App source for the
/// two facts a package test cannot compile (`postPreview` asking for permission, and the
/// destination screen's declared alignment).
///
/// Deliberately NOT the shape of the existing `onboarding-ambient-preview.feature` step
/// "a sample notification is sent so the first real one is familiar", which increments a
/// counter in its own world object (`w.sampleNotificationCount += 1`) and would have gone
/// green all the way through the outage this feature describes.
final class OnboardingAmbientNudgeHonestyFeatureTests: XCTestCase {
    func testOnboardingAmbientNudgeHonestyFeature() async throws {
        try await BrineFeatureRunner.run(
            "onboarding-ambient-nudge-honesty",
            registry: StepRegistry(NudgeHonestySteps.make(world: NudgeHonestyWorld())))
    }
}

private final class NudgeHonestyWorld: @unchecked Sendable {
    /// What the notifier reported. `.pending` is the state the step is in between tapping
    /// "Turn it on" and hearing back — the window in which the old copy already claimed a
    /// send.
    var attempt: AmbientNudgeAttempt = .pending
    /// Ambient intelligence itself: the preference write happens on tap and is NOT undone
    /// by a failed sample. Held as the real flag the step sets.
    var ambientOn = false

    var said: OnboardingAmbientConfirmation {
        OnboardingAmbientStepCopy.confirmation(for: attempt)
    }
}

private enum NudgeHonestySteps {
    static func make(world w: NudgeHonestyWorld) -> [StepDefinition] {
        [
            defineStep("I have just turned ambient intelligence on during onboarding") { ctx, _, _ in
                w.ambientOn = true
                w.attempt = .pending
                return ctx
            },
            defineStep("the phone accepts the sample nudge") { ctx, _, _ in
                w.attempt = .scheduled
                return ctx
            },
            defineStep("I refuse permission to send me notifications") { ctx, _, _ in
                w.attempt = .refused
                return ctx
            },
            defineStep("the sample nudge cannot be scheduled") { ctx, _, _ in
                w.attempt = .unavailable
                return ctx
            },
            defineStep("the screen that asks where my notes live is showing") { ctx, _, _ in
                ctx
            },

            defineCheck("the step tells me a sample nudge was sent") { _, _, _ in
                guard w.said.claimsNudgeSent,
                      OnboardingAmbientStepCopy.assertsANudgeWasSent(w.said.spokenText) else {
                    throw BrineStepError(
                        "a nudge WAS scheduled but the step does not say so: “\(w.said.spokenText)”")
                }
            },
            defineCheck("the step points me at my lock screen") { _, _, _ in
                guard w.said.headline.lowercased().contains("lock screen") else {
                    throw BrineStepError(
                        "the step never says where to look: “\(w.said.headline)”")
                }
            },
            defineCheck("the step does not claim a sample nudge was sent") { _, _, _ in
                guard !w.said.claimsNudgeSent else {
                    throw BrineStepError(
                        "\(w.attempt.rawValue): the step claims a send that never happened")
                }
                guard !OnboardingAmbientStepCopy.assertsANudgeWasSent(w.said.spokenText) else {
                    throw BrineStepError(
                        "\(w.attempt.rawValue): the step's words still assert a delivery: " +
                        "“\(w.said.spokenText)”")
                }
            },
            defineCheck("the step tells me how to turn notifications on") { _, _, _ in
                guard w.said.pointsToSystemSettings,
                      w.said.detail.lowercased().contains("settings") else {
                    throw BrineStepError(
                        "a refusal is fixable but the step does not say where: “\(w.said.detail)”")
                }
            },
            defineCheck("ambient intelligence is still on") { _, _, _ in
                guard w.ambientOn else {
                    throw BrineStepError("a failed sample nudge turned ambient intelligence off")
                }
                guard w.said.headline.hasPrefix("On") else {
                    throw BrineStepError(
                        "the step reads as if the whole feature failed: “\(w.said.headline)”")
                }
            },
            defineCheck("only a scheduled nudge claims a nudge was sent") { _, _, _ in
                for attempt in AmbientNudgeAttempt.allCases {
                    let said = OnboardingAmbientStepCopy.confirmation(for: attempt)
                    let claims = said.claimsNudgeSent
                    guard claims == (attempt == .scheduled) else {
                        throw BrineStepError(
                            "\(attempt.rawValue) claimsNudgeSent=\(claims)")
                    }
                    guard OnboardingAmbientStepCopy.assertsANudgeWasSent(said.spokenText) == claims
                    else {
                        throw BrineStepError(
                            "\(attempt.rawValue): words and claim disagree: “\(said.spokenText)”")
                    }
                }
            },
            defineCheck("no wording in the app claims a nudge the app cannot have verified") { _, _, _ in
                var offenders: [String] = []
                for file in try AppSourceTree.appSideSwiftFiles() {
                    guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
                    let source = AppSourceTree.withoutComments(of: text)
                    for line in source.split(separator: "\n", omittingEmptySubsequences: false)
                    where OnboardingAmbientStepCopy.assertsANudgeWasSent(String(line)) {
                        offenders.append(
                            "\(AppSourceTree.relativePath(file)): " +
                            line.trimmingCharacters(in: .whitespaces))
                    }
                }
                guard offenders.isEmpty else {
                    throw BrineStepError(
                        "App-side literals assert a delivery they cannot have verified:\n" +
                        offenders.joined(separator: "\n"))
                }
            },
            defineCheck("the sample nudge asks me for notification permission") { _, _, _ in
                let deliver = try OnboardingAmbientNudgeHonestyTests.functionBody(
                    named: "deliver", inAppFile: "App/AmbientNotifier.swift")
                guard deliver.contains("requestAuthorization(") else {
                    throw BrineStepError(
                        "the sample-nudge delivery path never asks for permission, so a " +
                        "first-run notification is dropped by iOS")
                }
            },
            defineCheck("the sample nudge can be shown while the app is open") { _, _, _ in
                let preview = try OnboardingAmbientNudgeHonestyTests.functionBody(
                    named: "postPreview", inAppFile: "App/AmbientNotifier.swift")
                guard preview.contains("installNotificationSurface") else {
                    throw BrineStepError(
                        "postPreview does not install the foreground presenter, so iOS " +
                        "swallows the banner while onboarding is on screen")
                }
            },
            defineCheck("the choice buttons are aligned the same way as the screen") { _, _, _ in
                let source = try OnboardingDestinationLayoutGuardTests.destinationStepSource()
                let (screen, buttons) =
                    try OnboardingDestinationLayoutGuardTests.screenAndButtonStacks(in: source)
                guard let declared = buttons.alignment else {
                    throw BrineStepError(
                        "the button stack declares no alignment, so SwiftUI centres the " +
                        "buttons inside a box pinned to the screen's leading edge")
                }
                guard declared == screen.alignment else {
                    throw BrineStepError(
                        "buttons aligned .\(declared) inside a screen aligned " +
                        ".\(screen.alignment ?? "center")")
                }
            },
            defineCheck("the choice buttons span the column rather than a box of their own") { _, _, _ in
                let source = try OnboardingDestinationLayoutGuardTests.destinationStepSource()
                let (_, buttons) =
                    try OnboardingDestinationLayoutGuardTests.screenAndButtonStacks(in: source)
                guard let end = source.range(of: buttons.body)?.upperBound else {
                    throw BrineStepError("could not read the button stack's modifiers")
                }
                guard String(source[end...].prefix(220)).contains("maxWidth: .infinity") else {
                    throw BrineStepError(
                        "the button stack shrink-wraps to its widest button, so its declared " +
                        "alignment is invisible")
                }
            },
        ]
    }
}
