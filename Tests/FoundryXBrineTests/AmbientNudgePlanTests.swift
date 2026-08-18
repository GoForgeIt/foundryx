import XCTest
@testable import FoundryXKit

/// THE SAMPLE NUDGE'S DECISIONS, EXECUTED.
///
/// Every assertion in this file used to be impossible. The branches it covers lived inside
/// a closure in `App/AmbientNotifier.deliver`, handed to `UNUserNotificationCenter`, and
/// `swift test` cannot compile `App/` — so the guards over them read that file as TEXT.
/// Three one-line mutations to the shipped fix passed 1536/1536 as a result, the worst of
/// them changing the permission-denied arm from `report?(.refused)` to `report?(.scheduled)`
/// so that a user who had just tapped "Don't Allow" was told "On — check your lock screen /
/// We just sent a sample nudge". The banned string was still on an untouched line, so the
/// `contains()` gate was satisfied.
///
/// A test here cannot be satisfied by a spelling. It asks the decision what it decides.
final class AmbientNudgePlanTests: XCTestCase {

    // MARK: - The one outcome that may claim a send

    /// `.scheduled` is reachable from EXACTLY ONE place: iOS having accepted a real
    /// request. No permission state, no binding state, no answer to the prompt may produce
    /// it on its own.
    ///
    /// MUTATION THIS ANSWERS TO: `afterAsking(granted:)` returning `.schedule` for a
    /// refusal, or `firstStep` returning `.schedule` for `.denied` — either of which puts
    /// "We just sent a sample nudge" on a screen where nothing was sent.
    func testNothingButAnAcceptedRequestCanEverProduceAScheduledClaim() {
        for permission in AmbientNudgePermission.allCases {
            for isPreview in [true, false] {
                for hasBinding in [true, false] {
                    for bindingIsCurrent in [true, false] {
                        let step = AmbientNudgePlan.firstStep(
                            permission: permission, isPreview: isPreview,
                            hasBinding: hasBinding, bindingIsCurrent: bindingIsCurrent)
                        XCTAssertNotEqual(
                            step, .report(.scheduled),
                            "firstStep(\(permission.rawValue), preview:\(isPreview), " +
                            "binding:\(hasBinding)/\(bindingIsCurrent)) claims a send " +
                            "before anything was handed to iOS")
                        XCTAssertNotEqual(
                            step, .report(.pending),
                            "firstStep(\(permission.rawValue)) settles on `.pending`, which " +
                            "leaves the step saying 'checking' with nothing still running")
                    }
                }
            }
        }
        for granted in [true, false] {
            XCTAssertNotEqual(AmbientNudgePlan.afterAsking(granted: granted), .report(.scheduled),
                              "answering the permission prompt cannot itself be a send")
        }
        XCTAssertEqual(AmbientNudgePlan.afterHandingToSystem(accepted: true), .scheduled)
        XCTAssertEqual(AmbientNudgePlan.afterHandingToSystem(accepted: false), .unavailable)
        XCTAssertEqual(AmbientNudgePlan.outcomesThatMayClaimASend, [.scheduled])
    }

    // MARK: - Refusal is refusal

    /// A user who says no is told they said no. THIS IS THE MUTATION THAT SHIPPED GREEN.
    func testRefusingThePromptIsReportedAsARefusalAndNeverAsASend() {
        XCTAssertEqual(AmbientNudgePlan.afterAsking(granted: false), .report(.refused),
                       "a user who tapped “Don't Allow” must be told so — telling them to " +
                       "check their lock screen sends them hunting for a nudge iOS dropped")
        XCTAssertEqual(AmbientNudgePlan.afterAsking(granted: true), .schedule)
        // …and the copy keyed on it must not claim a delivery. The two halves are asserted
        // together because either one alone can be right while the pair lies.
        XCTAssertFalse(OnboardingAmbientStepCopy.confirmation(for: .refused).claimsNudgeSent)
        XCTAssertTrue(OnboardingAmbientStepCopy.confirmation(for: .scheduled).claimsNudgeSent)
    }

    /// An already-denied phone is not asked again, and is not lied to.
    func testAnAlreadyDeniedPhoneIsReportedRefusedWithoutAsking() {
        for isPreview in [true, false] {
            XCTAssertEqual(
                AmbientNudgePlan.firstStep(permission: .denied, isPreview: isPreview,
                                           hasBinding: true, bindingIsCurrent: true),
                .report(.refused),
                "a denied phone (preview:\(isPreview)) must say so, not schedule and not ask")
        }
    }

    // MARK: - The step that promises the notification is the step that asks

    /// On a first run this IS the status at the ambient step — nothing else in the app asks
    /// any more. If this stops being `.ask`, the sample is handed to an iOS that has never
    /// been asked, and iOS drops it.
    func testAFirstRunPhoneIsAskedAtTheStepThatPromisedTheNudge() {
        for hasBinding in [true, false] {
            XCTAssertEqual(
                AmbientNudgePlan.firstStep(permission: .notDetermined, isPreview: true,
                                           hasBinding: hasBinding,
                                           bindingIsCurrent: hasBinding),
                .ask,
                "the sample nudge does not raise the permission prompt (binding:\(hasBinding)), " +
                "so on a first run iOS silently drops the nudge the step just promised")
        }
    }

    // MARK: - The unbound sample — the original defect, as a value

    /// THE FX-4(a) DEFECT, ASSERTED DIRECTLY. `postPreview` opened with
    /// `guard let binding = CaptureAccountScope.currentAccountBinding() else { return }`,
    /// and during onboarding there is no account, so it returned in silence while the step
    /// announced a send. The sample carries no user content, no seed and no tap payload, so
    /// there is nothing an account scope protects — it MUST go out unbound.
    func testTheSampleGoesOutWithNoAccountBoundBecauseThereIsNoAccountYet() {
        XCTAssertEqual(
            AmbientNudgePlan.firstStep(permission: .authorized, isPreview: true,
                                       hasBinding: false, bindingIsCurrent: false),
            .schedule,
            "the sample nudge is refused for want of an account — during onboarding there " +
            "is no account, which is the exact defect this lane exists for")
        XCTAssertEqual(
            AmbientNudgePlan.firstStep(permission: .notDetermined, isPreview: true,
                                       hasBinding: false, bindingIsCurrent: false),
            .ask,
            "the sample nudge does not even ask without an account")
    }

    /// …and a REAL nudge, which carries the user's own words and a tap payload that acts on
    /// their account, may not. The two halves of the rule are asserted together, because
    /// loosening the sample is only safe while this stays tight.
    func testARealNudgeMayNotGoOutUnbound() {
        for permission in AmbientNudgePermission.allCases {
            XCTAssertEqual(
                AmbientNudgePlan.firstStep(permission: permission, isPreview: false,
                                           hasBinding: false, bindingIsCurrent: false),
                .report(.unavailable),
                "a real nudge with no account bound (\(permission.rawValue)) would carry the " +
                "user's own words to nobody's account")
        }
    }

    /// A binding that moved between the settings read and the decision may not be used and
    /// may not be reported as a send.
    func testAnIdentityThatMovedIsNeverScheduledAndNeverClaimed() {
        for permission in AmbientNudgePermission.allCases {
            for isPreview in [true, false] {
                XCTAssertEqual(
                    AmbientNudgePlan.firstStep(permission: permission, isPreview: isPreview,
                                               hasBinding: true, bindingIsCurrent: false),
                    .report(.unavailable),
                    "\(permission.rawValue)/preview:\(isPreview): the account moved out from " +
                    "under the request and the nudge went out against it anyway")
            }
        }
    }

    // MARK: - The permission mapping is total and safe

    /// The App-side seam maps `UNAuthorizationStatus` onto this. Anything it cannot
    /// recognise must land on `.denied`: the only safe assumption about a status we do not
    /// understand is that iOS will not show the nudge.
    func testEveryPermissionHasAnAnswerAndNoneOfThemIsSilence() {
        for permission in AmbientNudgePermission.allCases {
            let step = AmbientNudgePlan.firstStep(permission: permission, isPreview: true,
                                                  hasBinding: false, bindingIsCurrent: false)
            switch step {
            case .ask, .schedule:
                XCTAssertTrue(permission != .denied,
                              "\(permission.rawValue) is allowed to schedule or ask")
            case .report(let outcome):
                XCTAssertNotEqual(outcome, .scheduled)
                XCTAssertNotEqual(outcome, .pending,
                                  "\(permission.rawValue) leaves the step saying 'checking' " +
                                  "with nothing left to answer it")
            }
        }
        XCTAssertEqual(AmbientNudgePlan.whenTheCentreIsUnreachable, .unavailable,
                       "a path that never reached the notification centre must not claim a send")
    }

    // MARK: - Instrument check

    /// If `AmbientNudgePermission` grows a case, the cross-products above silently cover one
    /// more combination and nobody has decided what it means. Pin the population, the way
    /// the app-scenario suites pin `result.passed`.
    func testThePopulationOfPermissionsIsPinned() {
        XCTAssertEqual(AmbientNudgePermission.allCases.count, 5,
                       "a permission was added or removed — decide what `firstStep` does " +
                       "with it and update the cross-products above: " +
                       AmbientNudgePermission.allCases.map(\.rawValue).joined(separator: ", "))
        XCTAssertEqual(AmbientNudgeAttempt.allCases.count, 4,
                       "an outcome was added or removed: " +
                       AmbientNudgeAttempt.allCases.map(\.rawValue).joined(separator: ", "))
    }
}
