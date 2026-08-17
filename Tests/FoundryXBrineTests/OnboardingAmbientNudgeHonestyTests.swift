import XCTest
import Foundation
@testable import FoundryXKit

/// FX-4(a) — THE AMBIENT NUDGE MUST NOT LIE.
///
/// `App/OnboardingFlowView.swift`'s ambient step tapped "Turn it on", called
/// `AmbientNotifier.postPreview()`, and on the very next line announced
/// "We just sent a sample nudge so the first real one is never a surprise."
///
/// `postPreview` opened with
/// `guard let binding = CaptureAccountScope.currentAccountBinding() else { return }`.
/// During onboarding no account is bound, so it posted NOTHING and returned silently —
/// the same silent-guard shape as `CaptureWAL.performDurableMutation`, which discarded
/// every durable write and reported success. Worse, `requestAuthorizationIfNeeded` is
/// called from `RootView` and not from this step, so on a first run the authorization
/// status is `.notDetermined` and iOS would drop the notification even if one had been
/// posted.
///
/// This file holds two things a `View` body cannot hold:
///  1. the KIT invariant — no outcome other than `.scheduled` may claim a nudge was sent;
///  2. the APP-SIDE guards — read from source, because `swift test` cannot compile `App/`
///     (the same mechanism `ChatAlignmentRegressionGuardTests` and `AppSourceTree` use).
final class OnboardingAmbientNudgeHonestyTests: XCTestCase {

    // MARK: - The kit invariant

    /// The one that matters: the screen cannot claim a nudge was sent unless one was
    /// actually scheduled. Iterating `allCases` means a future outcome is covered the
    /// moment it is added, rather than defaulting into the claiming branch.
    func testOnlyAScheduledNudgeMayClaimANudgeWasSent() {
        for attempt in AmbientNudgeAttempt.allCases {
            let said = OnboardingAmbientStepCopy.confirmation(for: attempt)
            if attempt == .scheduled {
                XCTAssertTrue(said.claimsNudgeSent,
                              "a nudge really WAS scheduled but the step will not say so")
            } else {
                XCTAssertFalse(said.claimsNudgeSent,
                               "\(attempt.rawValue): the step claims a sample nudge was sent " +
                               "when none was scheduled — this is the FX-4(a) defect")
            }
        }
    }

    /// The flag and the WORDS must agree. A `claimsNudgeSent == false` outcome whose prose
    /// still reads "We just sent a sample nudge" would satisfy the flag check above while
    /// telling the user exactly the lie this fix exists to remove.
    func testTheWordsAgreeWithTheClaimFlagForEveryOutcome() {
        for attempt in AmbientNudgeAttempt.allCases {
            let said = OnboardingAmbientStepCopy.confirmation(for: attempt)
            XCTAssertEqual(
                OnboardingAmbientStepCopy.assertsANudgeWasSent(said.spokenText),
                said.claimsNudgeSent,
                "\(attempt.rawValue): the copy “\(said.spokenText)” does not match its own " +
                "claimsNudgeSent=\(said.claimsNudgeSent)")
        }
    }

    /// Falsification: the detector this file trusts is not vacuous — it fires on the exact
    /// sentence that shipped, and it does NOT fire on honest failure copy (otherwise the
    /// check above would be satisfiable only by saying nothing at all).
    func testTheDeliveryClaimDetectorIsNotVacuous() {
        XCTAssertTrue(OnboardingAmbientStepCopy.assertsANudgeWasSent(
            "We just sent a sample nudge so the first real one is never a surprise."),
            "the detector cannot recognise the very sentence that shipped the lie")
        XCTAssertTrue(OnboardingAmbientStepCopy.assertsANudgeWasSent(
            "On — check your lock screen"),
            "the detector cannot recognise “check your lock screen”, which asserts a delivery")
        XCTAssertFalse(OnboardingAmbientStepCopy.assertsANudgeWasSent(
            "The sample nudge couldn't be scheduled just now."),
            "the detector treats an admission of failure as a claim of delivery")
        XCTAssertFalse(OnboardingAmbientStepCopy.assertsANudgeWasSent(
            "Checking whether the sample nudge can go out."),
            "the detector treats a pending state as a claim of delivery")
        // The subject half. Without it this predicate is swept over ALL of App/ and would
        // redden for any unrelated sentence about having sent something — a gate saying
        // "your code is broken" when it means "I matched the wrong thing".
        XCTAssertFalse(OnboardingAmbientStepCopy.assertsANudgeWasSent(
            "We just sent your invite."),
            "the detector claims an unrelated 'we sent …' line is a nudge claim")
        XCTAssertFalse(OnboardingAmbientStepCopy.assertsANudgeWasSent(
            "A notification will arrive while you are taking a note."),
            "the detector treats naming a notification, with no delivery claim, as a claim")
    }

    /// The refused copy sends the user to a row in iOS Settings — it must name the row that
    /// actually exists there. The app ships as `Solleva` (CFBundleDisplayName, project.yml),
    /// so naming the repo or the target would send them looking for something absent.
    func testTheRefusedCopyNamesTheAppAsTheUserSeesIt() throws {
        let refused = OnboardingAmbientStepCopy.confirmation(for: .refused)
        let displayName = try Self.bundleDisplayName()
        XCTAssertTrue(refused.detail.contains(displayName),
                      "the refused copy points at iOS Settings but never names “\(displayName)”, " +
                      "the row the user will be looking for: “\(refused.detail)”")
        for attempt in AmbientNudgeAttempt.allCases {
            let said = OnboardingAmbientStepCopy.confirmation(for: attempt)
            XCTAssertFalse(said.spokenText.contains("FoundryX"),
                           "\(attempt.rawValue) shows the user the build's name rather than " +
                           "“\(displayName)”: “\(said.spokenText)”")
        }
    }

    /// The app's user-visible name, read from `project.yml` rather than hardcoded here —
    /// a rename must move this test, not silently pass it.
    static func bundleDisplayName() throws -> String {
        let yml = try String(
            contentsOf: AppSourceTree.repoRoot.appendingPathComponent("project.yml"),
            encoding: .utf8)
        guard let line = yml.split(separator: "\n").first(where: {
            $0.contains("CFBundleDisplayName:") && !$0.contains("Test Host")
        }) else {
            throw BrineStepError("project.yml declares no CFBundleDisplayName")
        }
        return line.split(separator: ":", maxSplits: 1)[1]
            .trimmingCharacters(in: .whitespaces)
    }

    /// A refusal is the one outcome the user can fix, so it must say where.
    func testARefusedNudgePointsAtSystemSettings() {
        let refused = OnboardingAmbientStepCopy.confirmation(for: .refused)
        XCTAssertTrue(refused.pointsToSystemSettings,
                      "a denied notification permission is fixable, but the step does not say how")
        XCTAssertTrue(refused.detail.lowercased().contains("settings"),
                      "the refused copy never names Settings: “\(refused.detail)”")
        for attempt in AmbientNudgeAttempt.allCases where attempt != .refused {
            XCTAssertFalse(OnboardingAmbientStepCopy.confirmation(for: attempt).pointsToSystemSettings,
                           "\(attempt.rawValue) sends the user to Settings for something " +
                           "Settings cannot fix")
        }
    }

    /// Only a real send earns the badged bell. A slashed/plain bell for the rest means the
    /// glyph cannot contradict the words.
    func testOnlyAScheduledNudgeShowsTheBadgedBell() {
        for attempt in AmbientNudgeAttempt.allCases {
            let symbol = OnboardingAmbientStepCopy.confirmation(for: attempt).symbolName
            if attempt == .scheduled {
                XCTAssertEqual(symbol, "bell.badge.fill")
            } else {
                XCTAssertNotEqual(symbol, "bell.badge.fill",
                                  "\(attempt.rawValue) shows the delivered-notification glyph")
            }
        }
    }

    // MARK: - The App-side guards (read from source; `swift test` cannot compile `App/`)

    /// No literal ANYWHERE in the App target may assert that a nudge was delivered. A
    /// literal cannot know whether one was — that is precisely how the false claim shipped.
    /// The confirmation copy lives in `Sources/FoundryXKit`, which this walk does not read,
    /// so the honest wording is unaffected.
    func testNoAppSideLiteralAssertsANudgeWasSent() throws {
        var offenders: [String] = []
        for file in try AppSourceTree.appSideSwiftFiles() {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            // Comments removed, string literals KEPT — the literal is the thing being held.
            let source = AppSourceTree.withoutComments(of: text)
            for line in source.split(separator: "\n", omittingEmptySubsequences: false)
            where OnboardingAmbientStepCopy.assertsANudgeWasSent(String(line)) {
                offenders.append("\(AppSourceTree.relativePath(file)): \(line.trimmingCharacters(in: .whitespaces))")
            }
        }
        XCTAssertTrue(offenders.isEmpty,
                      "App-side source asserts a notification was delivered in a literal it " +
                      "cannot possibly have verified — render OnboardingAmbientStepCopy." +
                      "confirmation(for:) instead:\n" + offenders.joined(separator: "\n"))
    }

    /// The step that PROMISES a notification must be the step that ASKS for permission,
    /// and it must install the foreground presenter. Authorization was only ever requested
    /// from `RootView`, so on a first run the status at this step is `.notDetermined` and
    /// iOS drops the nudge; and without the presenter iOS swallows the banner while the app
    /// is foregrounded — which is exactly the situation during onboarding.
    ///
    /// Held in two halves because the sample path is two hops: `postPreview` installs the
    /// surface, and the `deliver` it calls raises the one prompt and reports the answer.
    func testTheSampleNudgePathAsksForPermissionAndPresentsInTheForeground() throws {
        let preview = try Self.functionBody(named: "postPreview",
                                            inAppFile: "App/AmbientNotifier.swift")
        // Instrument check first: a reader that stopped at the default argument's `{ _ in }`
        // would hand back " _ in " and every assertion below would be about nothing.
        XCTAssertTrue(preview.contains("deliver("),
                      "the reader did not return postPreview's real body — it returned " +
                      "“\(preview)”, so nothing below is measuring the function")
        XCTAssertTrue(preview.contains("installNotificationSurface"),
                      "AmbientNotifier.postPreview does not install the foreground presenter, " +
                      "so iOS would swallow the banner it promises while the app is open. " +
                      "Body was:\n\(preview)")
        let deliver = try Self.functionBody(named: "deliver",
                                            inAppFile: "App/AmbientNotifier.swift")
        XCTAssertTrue(deliver.contains("requestAuthorization("),
                      "the delivery path never asks for notification permission, so a first-run " +
                      "`.notDetermined` nudge would simply be dropped by iOS")
        XCTAssertTrue(deliver.contains("report?(.refused)"),
                      "the delivery path does not report a refusal, so a user who says no would " +
                      "still be told a nudge was sent")
    }

    /// Every exit from `deliver` must report. A `return` with no `report?` before it is the
    /// silent-guard shape this fix exists to remove — and it is how the original
    /// `postPreview` swallowed the whole thing.
    func testEveryEarlyReturnInTheDeliveryPathReportsFirst() throws {
        let deliver = try Self.functionBody(named: "deliver",
                                            inAppFile: "App/AmbientNotifier.swift")
        var silent: [String] = []
        let lines = deliver.split(separator: "\n", omittingEmptySubsequences: false)
        for (i, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed == "return" else { continue }
            // The report belongs in the lines immediately above: `report?(…)` then
            // `return`. Three are read rather than one because comment stripping leaves
            // blank lines behind. The `guard let binding` escape covers the ONE exit that
            // legitimately reports nothing itself — it falls through to `schedule`, which
            // reports from `center.add`'s completion.
            let window = lines[max(0, i - 3)..<i].joined(separator: " ")
            if !window.contains("report?(") && !window.contains("guard let binding") {
                silent.append("line \(i + 1): …\(window) / return")
            }
        }
        XCTAssertTrue(silent.isEmpty,
                      "AmbientNotifier.deliver returns without reporting — the caller cannot " +
                      "tell a delivered nudge from a swallowed one:\n" +
                      silent.joined(separator: "\n"))
    }

    /// `postPreview` must REPORT. A `-> Void` with no reporting seam is a function whose
    /// failure is unobservable, which is what let the caller claim success.
    func testPostPreviewReportsWhatActuallyHappened() throws {
        let source = try Self.appSource("App/AmbientNotifier.swift")
        guard let decl = source.range(of: "static func postPreview") else {
            XCTFail("AmbientNotifier.postPreview no longer exists under that name")
            return
        }
        let signature = String(source[decl.lowerBound...].prefix(300))
        XCTAssertTrue(signature.contains("AmbientNudgeAttempt"),
                      "postPreview does not hand back an AmbientNudgeAttempt, so no caller " +
                      "can tell a delivered nudge from a swallowed one. Signature was:\n\(signature)")
    }

    /// …and the ambient step must actually USE the report rather than calling `postPreview`
    /// bare and asserting success on the next line.
    func testTheAmbientStepUsesTheReportedOutcome() throws {
        let source = try Self.appSource("App/OnboardingFlowView.swift")
        XCTAssertTrue(source.contains("OnboardingAmbientStepCopy"),
                      "the ambient step does not render OnboardingAmbientStepCopy — its words " +
                      "are still a literal that cannot know what happened")
        guard let call = source.range(of: "AmbientNotifier.postPreview") else {
            XCTFail("the ambient step no longer fires the sample nudge at all")
            return
        }
        let afterCall = String(source[call.upperBound...].prefix(120))
        XCTAssertFalse(afterCall.hasPrefix("()"),
                       "the ambient step calls AmbientNotifier.postPreview() bare and discards " +
                       "the outcome — the FX-4(a) defect. Found: postPreview\(afterCall)")
    }

    // MARK: - Source helpers

    static func appSource(_ relativePath: String) throws -> String {
        let url = AppSourceTree.repoRoot.appendingPathComponent(relativePath)
        let text = try String(contentsOf: url, encoding: .utf8)
        // Comments stripped, literals kept: prose in a doc comment must not satisfy a gate
        // about code, but a literal IS the thing several of these gates hold.
        return AppSourceTree.withoutComments(of: text)
    }

    /// The brace-matched body of `func <name>` in an App-side file. Fails loud (throws)
    /// rather than returning "" — an empty body silently satisfying a `contains` check in
    /// the wrong direction is exactly the instrument failure to avoid, so callers get a
    /// body they can print.
    ///
    /// The parameter list is skipped by PAREN matching before the body brace is looked
    /// for. Taking "the first `{` after the name" is wrong and was wrong here: a default
    /// argument (`report: @escaping @Sendable (…) -> Void = { _ in }`) opens a brace inside
    /// the parameter list, and the naive reader returned `" _ in "` as the whole body —
    /// a guard that would then have gone green for every possible implementation.
    static func functionBody(named name: String, inAppFile relativePath: String) throws -> String {
        let source = try appSource(relativePath)
        guard let decl = source.range(of: "func \(name)") else {
            throw BrineStepError("\(relativePath) has no `func \(name)`")
        }
        guard let paren = source[decl.upperBound...].firstIndex(of: "(") else {
            throw BrineStepError("\(relativePath): `func \(name)` has no parameter list")
        }
        var parens = 0
        var afterSignature = paren
        while afterSignature < source.endIndex {
            if source[afterSignature] == "(" { parens += 1 }
            if source[afterSignature] == ")" {
                parens -= 1
                if parens == 0 { break }
            }
            afterSignature = source.index(after: afterSignature)
        }
        guard parens == 0, afterSignature < source.endIndex else {
            throw BrineStepError("\(relativePath): `func \(name)`'s parameter list is unbalanced")
        }
        guard let open = source[source.index(after: afterSignature)...].firstIndex(of: "{") else {
            throw BrineStepError("\(relativePath): `func \(name)` has no body")
        }
        var depth = 0
        var i = open
        while i < source.endIndex {
            if source[i] == "{" { depth += 1 }
            if source[i] == "}" {
                depth -= 1
                if depth == 0 { return String(source[source.index(after: open)..<i]) }
            }
            i = source.index(after: i)
        }
        throw BrineStepError("\(relativePath): `func \(name)`'s body is not brace-balanced")
    }
}
