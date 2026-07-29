import XCTest
import Foundation
import SwiftUI
@testable import FoundryXKit

/// Structural gates T5 owns for the two boundaries T4 left standing
/// (track 20260725T2306_device_agnostic_recording_source, review round 9 findings L3 and L4).
///
/// WHY THESE ARE SOURCE-TEXT AND DATE CHECKS RATHER THAN BEHAVIOUR. Both findings are about
/// things that are true of the SHIPPED build and invisible to every behavioural probe:
///
///   * L4 — `App/RootView.swift` gave the deliberately non-defaulted `recording:` parameter a
///     default AT THE CALL SITE (`?? .externalStream`). It was dead — the closure is stored on
///     the manager it weakly captures — but the whole reason the parameter carries no default
///     is that this boundary must not be crossable by omission, and a call-site `??` is that
///     boundary given a default whose value is precisely the wrong answer. `swift test` cannot
///     compile `App/`, so the only way to hold it is to read the file.
///   * L3 — `CaptureDeviceSidecar.migrationEpoch` is pinned deliberately LATE, and the whole
///     safety argument for "late" collapses the instant the release slips past it. The
///     decision was recorded only as a doc comment on the constant it is about. This is the
///     gate that makes it durable: it goes RED when the epoch is in the past.
final class DeviceCompositionRootGateTests: XCTestCase {

    private static var repoRoot: URL {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { root.deleteLastPathComponent() }
        return root
    }

    // MARK: - L4: the non-defaulted boundary is not crossable by a call-site default

    func testTheCompositionRootNeverDefaultsWhatIsRecording() throws {
        let rootView = try String(contentsOf: Self.repoRoot.appendingPathComponent("App/RootView.swift"),
                                  encoding: .utf8)

        // Non-vacuity FIRST: if the composition site ever moves out of this file, this test
        // must say so rather than passing because it found nothing to check.
        XCTAssertTrue(rootView.contains("OmiRestorationComposition.resolveDeviceContext("),
                      "the composition root is no longer in App/RootView.swift — this gate is "
                          + "checking a file that no longer holds the boundary")

        // The mechanism, not just the absence of one spelling: the recording source must be
        // supplied BY the capture manager as a closure PARAMETER, so no call site has anything
        // to default. `captureDeviceContext` is `(CaptureRecordingSource) -> …`.
        XCTAssertTrue(rootView.contains("mgr.captureDeviceContext = { recording in"),
                      "the composition closure must RECEIVE what is recording from the manager "
                          + "— a closure that reaches back for it has to handle the manager "
                          + "being gone, and every way of handling that is a default")

        for banned in ["?? .externalStream", "?? .handsetMicrophone", "?? CaptureRecordingSource"] {
            XCTAssertFalse(rootView.contains(banned),
                           "App/RootView.swift defaults `recording:` with `\(banned)`. "
                               + "`resolveDeviceContext` declares that parameter WITHOUT a "
                               + "default precisely so this boundary cannot be crossed by "
                               + "omission; a call-site default crosses it, and `.externalStream` "
                               + "is the exact wrong answer (the remembered device) for the bug "
                               + "the parameter exists to prevent")
        }
    }

    // MARK: - N7: the gap-outcome renderer is wired, and it is wired with an account

    /// `GapRecoveryRendering.decide` fails CLOSED — an unscoped report is withheld. That makes
    /// a missing production wiring silent-by-design, so this is what makes it loud: both
    /// composition roots must push the scope, and the app-side one must render through the
    /// decision rather than straight from the outcome.
    ///
    /// WHAT THIS TEST NO LONGER CARRIES ALONE (review round 11, H3). It used to be the whole
    /// gate on N7's production wiring, and a source-text search for
    /// `setAccountScopeForGapOutcomes(` is satisfied by a `nil` argument — which is exactly
    /// the state in which every gap outcome is withheld from its own account forever. The
    /// PRODUCER is now driven behaviourally by `device-rendered-surface.feature` ("the outcome
    /// a recording device delivers names the account its window opened under", and the two
    /// account-change scenarios). This file holds only what `swift test` cannot compile: the
    /// `App/` call sites.
    ///
    /// WHY IT NO LONGER ENUMERATES SPELLINGS OF `nil` (review round 12, M12-1). It used to
    /// reject exactly two strings — `setAccountScopeForGapOutcomes(nil)` and
    /// `…(nil as String?)` — which is completeness-by-enumeration over an open set, and two
    /// mutations walked straight past it: `followAccountScopeChanges(resolve: { nil })` and
    /// `setAccountScopeForGapOutcomes(String?.none)`. Both left every gap outcome nameless
    /// and both SURVIVED. What is asserted now is the property instead, in three parts, and
    /// what each part EXCLUDES is stated:
    ///
    ///   1. **The manager resolves; the app may not supply a resolver.** The declaration
    ///      carries no `resolve:`/`center:` parameter at all, so there is nothing for a call
    ///      site to override — `resolve: { nil }` is a compile error, not a survival. That is
    ///      held below (`testTheScopeFollowerTakesNoResolverToOverride`) so re-adding the
    ///      parameter reds here rather than quietly reopening the hole.
    ///   2. **Nothing under `App/` sets the scope by hand.** Not "not these two spellings of
    ///      nil" — the call itself is banned, which excludes every argument that could ever
    ///      be written into it. The composition roots ask the manager to FOLLOW; the only
    ///      value they may contribute is the first one, handed over as `startingFrom:`, and
    ///      `nil` there falls through to the real resolver rather than becoming a claim.
    ///   3. **A root that already holds a resolved binding hands THAT over.** This is the one
    ///      part that names an expression rather than a shape, and its limit is exactly that:
    ///      it holds that the binding each root resolved is the value it passes. It cannot
    ///      hold that the binding itself is the right one — the N7/M3 scenarios in
    ///      `device-rendered-surface.feature`, which drive the real producer, hold that.
    ///
    /// ACCEPTED RESIDUAL (review round 13, L13-1). Part (3) pins the two EXISTING roots'
    /// expressions, so a THIRD composition root calling
    /// `followAccountScopeChanges(startingFrom: "")` is unconstrained and withholds every gap
    /// outcome from the first push (MUT-R13-P3, SURVIVED). It is materially weaker than the
    /// hole M12-1 closed and it self-heals: only the first push carries the vacuous scope, and
    /// the next identity notification pushes a freshly-resolved one. Named here rather than
    /// mechanised — a rule that enumerated permitted `startingFrom:` expressions would be
    /// completeness-by-enumeration over an open set again.
    func testBothCompositionRootsGiveGapOutcomesAnAccount() throws {
        for path in ["App/RootView.swift", "App/FoundryXAppDelegate.swift"] {
            let source = try String(contentsOf: Self.repoRoot.appendingPathComponent(path),
                                    encoding: .utf8)
            XCTAssertTrue(source.contains("followAccountScopeChanges("),
                          "\(path) never tells DeviceManager which account a gap window is "
                              + "about, so every gap outcome from it is withheld — silently, "
                              + "because withholding is the fail-closed default. It must use "
                              + "`followAccountScopeChanges()`, not a one-shot push: the "
                              + "manager is a process singleton that outlives this file's view "
                              + "tree, and a scope taken once goes stale at the next sign-in, "
                              + "sign-out or account switch")
        }

        // (2) The whole call, banned, everywhere under App/ — recursively, because a future
        // subdirectory is not a place this rule stops applying.
        let handSetters = try AppSourceTree.filesContaining("setAccountScopeForGapOutcomes(")
        XCTAssertEqual(
            handSetters, [],
            "\(handSetters.joined(separator: ", ")) sets the gap-outcome scope BY HAND. No "
                + "composition root may: the value is whatever was written last, so any "
                + "spelling of an empty one — `nil`, `nil as String?`, `String?.none`, a "
                + "stale local — withholds every outcome from its own account forever while "
                + "still satisfying every search for `followAccountScopeChanges(`. Ask the "
                + "manager to FOLLOW, and hand over the first value with `startingFrom:` if "
                + "you already have it")

        // (3) Each root hands over the binding it already resolved.
        let rootViewSource = try String(
            contentsOf: Self.repoRoot.appendingPathComponent("App/RootView.swift"),
            encoding: .utf8)
        XCTAssertTrue(
            rootViewSource.contains("followAccountScopeChanges(startingFrom: accountBinding?.scope)"),
            "App/RootView.swift resolves `accountBinding` in the same `init` and then makes "
                + "the manager resolve it a second time. That init runs on every body pass of "
                + "the view that builds MainTabs, and each resolution is a process-wide lock, "
                + "an on-disk admission-registry read and a cross-process widget publish — on "
                + "main. Hand over what you already have")
        let delegateSource = try String(
            contentsOf: Self.repoRoot.appendingPathComponent("App/FoundryXAppDelegate.swift"),
            encoding: .utf8)
        XCTAssertTrue(
            delegateSource.contains("followAccountScopeChanges(startingFrom: binding.scope)"),
            "App/FoundryXAppDelegate.swift is the HEADLESS BLE-restoration path — the one "
                + "where gap windows actually open — and it holds a PROVED-OWNER binding that "
                + "`CaptureAccountScope.currentAccountBinding()` may not be able to resolve at "
                + "all during a background relaunch. It must hand that binding's scope over as "
                + "the follower's first value; passing nothing falls back to a resolver that "
                + "can answer `nil` here, and a nil scope withholds every outcome")
        let rootView = try String(
            contentsOf: Self.repoRoot.appendingPathComponent("App/RootView.swift"),
            encoding: .utf8)
        XCTAssertTrue(rootView.contains("GapRecoveryRendering.decide("),
                      "the app renders gap outcomes without asking whether they belong to the "
                          + "account on screen — N7 is exactly that hole")
        XCTAssertFalse(rootView.contains("GapRecoveryCopy.line(for:"),
                       "a gap sentence was built directly from the outcome, bypassing the "
                           + "account decision that is the whole point of N7")
    }

    /// PART (1) OF THE PROPERTY ABOVE, held where it is decided: the follower has no seam a
    /// composition root can use to answer "which account" for it.
    ///
    /// `followAccountScopeChanges(resolve: { nil })` in `App/RootView.swift` made every gap
    /// outcome nameless and SURVIVED the whole suite (review round 12, MUT-R12-A) — the gate
    /// searched for `followAccountScopeChanges(`, and a vacuous resolver contains it. The fix
    /// was to delete the parameter: no caller in the repo, production or test, ever supplied
    /// one, and a parameter nobody needs is a hole with a default on it. Now that mutation
    /// does not compile, which `scripts/ci-gates.sh compile` is what runs — and this test is
    /// what stops the parameter quietly coming back and reopening it.
    func testTheScopeFollowerTakesNoResolverToOverride() throws {
        let manager = try String(
            contentsOf: Self.repoRoot.appendingPathComponent(
                "Sources/FoundryXKit/DeviceManager.swift"),
            encoding: .utf8)
        XCTAssertTrue(
            manager.contains("public func followAccountScopeChanges(startingFrom handedOver: String? = nil)"),
            "`followAccountScopeChanges` no longer has the signature the composition-root "
                + "gate is written against — re-read it before changing this line")
        for reopened in ["resolve: @escaping @Sendable () -> String?"] {
            XCTAssertFalse(
                manager.contains(reopened),
                "`followAccountScopeChanges` has been given back an injectable resolver or "
                    + "notification centre. Nothing in this repo passes one, and while it "
                    + "existed a composition root could answer \"which account\" with "
                    + "`{ nil }` — withholding every gap outcome from its own owner forever "
                    + "while still containing `followAccountScopeChanges(`. If a test truly "
                    + "needs to inject, give it a seam that is named as one; do not put a "
                    + "default on the production path")
        }
    }

    // MARK: - H12-1: the list does not read the archive off disk per row per body pass

    /// `NavigationLink`'s `destination:` is a `@ViewBuilder` evaluated WITH the link, so an
    /// unwrapped destination is constructed on every body pass of the screen carrying the
    /// link — once per row. `conversationDetail(_:)` evaluates
    /// `CaptureAttributionPresentation.attribution(captureId:baseDir:)` as an eager argument,
    /// which is an uncached `fileExists` + two `Data(contentsOf:)` + a JSON decode, on the
    /// MAIN ACTOR (review round 12, H12-1). `ResidualMainActorWorkTests` is the suite this
    /// pathology belongs to and it cannot see this instance of it: it instruments the Kit,
    /// and `swift test` cannot compile `App/`. So it is held here, where the other
    /// uncompilable App facts are.
    ///
    /// WHAT THIS EXCLUDES: it holds that the conversation row's destination is deferred, not
    /// that every expensive destination in the app is. `LazyView` is the repo's own answer
    /// (declared in `Sources/FoundryXKit/LazyView.swift` with the rationale, used for
    /// `StatsView` too).
    ///
    /// AND IT HOLDS A SPELLING, NOT A BEHAVIOUR (review round 13, M13-2). `code.contains(…)`
    /// asks what the call site is NAMED. An eager type wearing the same name passed it — and
    /// through the shared `StatsView` call site, restored the pathology more broadly than
    /// before. What `LazyView` IS is now held next door, by construction and invocation, in
    /// `testLazyViewDoesNotBuildItsContentUntilItsBodyIsAsked`; the two together are the gate.
    func testTheConversationRowDefersBuildingItsDetail() throws {
        let captureScreen = try String(
            contentsOf: Self.repoRoot.appendingPathComponent("App/CaptureScreen.swift"),
            encoding: .utf8)
        let code = AppSourceTree.withoutComments(of: captureScreen)

        // Non-vacuity: the row must still push the detail at all.
        XCTAssertTrue(code.contains("conversationDetail(wal)"),
                      "the conversation row no longer opens the three-face detail — this gate "
                          + "is checking a navigation that no longer exists")
        XCTAssertTrue(
            code.contains("LazyView { conversationDetail(wal) }"),
            "App/CaptureScreen.swift builds the conversation detail EAGERLY inside its "
                + "`NavigationLink`. The destination is a @ViewBuilder evaluated with the "
                + "link, so `conversationDetail(_:)` — which reads the device record and the "
                + "legacy source marker off disk as an eager argument, uncached — runs once "
                + "per row on every body pass of the list, on the main actor. Wrap it: "
                + "`LazyView { conversationDetail(wal) }`")

        // The name at the call site must be THE deferring type — not a second declaration
        // under `App/` shadowing it. Same module, so this is also a compile error; the check
        // is here because `swift test` is what runs on every commit.
        let declarations = try AppSourceTree.filesContaining("struct LazyView")
        XCTAssertEqual(
            declarations, [],
            "\(declarations.joined(separator: ", ")) declares its own `LazyView`. The type the "
                + "call site above names must be the one `testLazyViewDoesNotBuildItsContentUntilItsBodyIsAsked` "
                + "constructs — otherwise the deferral is held by a name again")
    }

    /// WHAT `LazyView` IS, held by construction rather than by spelling (review round 13,
    /// M13-2).
    ///
    /// The gate above searches `App/` for `LazyView { conversationDetail(wal) }`. An eager
    /// type of the same name —
    /// `init(@ViewBuilder _ build: @escaping () -> Content) { self.built = build() }` —
    /// satisfies it exactly, at both of the type's call sites, and reinstates the per-row
    /// main-actor disk read H12-1 was about while every gate stays green (MUT-R13-P5).
    ///
    /// This is the property, driven: a closure that records its own invocations must not be
    /// invoked by `init`, and must be invoked when `body` is asked for. The type is in the Kit
    /// precisely so this test can exist — `swift test` cannot compile `App/`, so while it was
    /// declared there, nothing could name it.
    @MainActor
    func testLazyViewDoesNotBuildItsContentUntilItsBodyIsAsked() {
        final class Invocations { var count = 0 }
        let invocations = Invocations()

        let view = LazyView { () -> Text in
            invocations.count += 1
            return Text("the destination")
        }
        XCTAssertEqual(
            invocations.count, 0,
            "`LazyView` built its content at INIT. That is the eager impostor: the wrapper is "
                + "constructed with the `NavigationLink` on every body pass of the screen "
                + "carrying it, so building at init means the conversation row reads each "
                + "capture's device record off disk, uncached, on the main actor, once per row "
                + "per pass — the pathology the wrapper exists to prevent")

        _ = view.body
        XCTAssertEqual(
            invocations.count, 1,
            "`LazyView.body` did not build its content — a destination that is never "
                + "constructed renders nothing, so a wrapper that defers forever is not "
                + "deferral either")
    }

    /// The same boundary from the other side: no production or test call site may omit
    /// `recording:`, and the type system is what enforces it. This asserts the enforcement
    /// still EXISTS — a default added to the declaration would silently retire it.
    func testResolveDeviceContextDeclaresNoDefaultForWhatIsRecording() throws {
        let composition = try String(
            contentsOf: Self.repoRoot.appendingPathComponent(
                "Sources/FoundryXKit/OmiRestorationComposition.swift"),
            encoding: .utf8)
        XCTAssertTrue(composition.contains("recording: CaptureRecordingSource\n"),
                      "`recording:` must stay undefaulted — a default makes every call site "
                          + "able to skip the one question the archive depends on")
        XCTAssertFalse(composition.contains("recording: CaptureRecordingSource ="),
                       "`recording:` was given a default in the declaration")
    }

    // MARK: - L3: the migration epoch's decision, made durable

    /// The ship-checklist entry, as a gate.
    ///
    /// `migrationEpoch` classifies a capture that carries NO device record: at-or-after it,
    /// "its record went missing"; before it, "recorded before the upgrade". Late is the safe
    /// direction (it understates what is known); early ACCUSES correct captures of a fault.
    /// The constant is pinned late on purpose — and stays safe only while it is in the future.
    ///
    /// THIS TEST IS A DELIBERATE TIME BOMB. When it reds, the answer is not to move the
    /// assertion: it is to move `migrationEpoch` to the timestamp of the release that first
    /// writes device records (see TESTFLIGHT.md), or — if that release has already shipped —
    /// to leave it where the release put it and retire this gate in the same commit that
    /// records which build it shipped in.
    func testTheMigrationEpochHasNotSilentlyBecomeEarly() {
        let epoch = CaptureDeviceSidecar.migrationEpoch
        let now = UInt64(Date().timeIntervalSince1970)
        XCTAssertGreaterThan(
            epoch, now,
            "CaptureDeviceSidecar.migrationEpoch (\(epoch), "
                + "\(Date(timeIntervalSince1970: TimeInterval(epoch)))) is in the PAST. It is "
                + "pinned deliberately LATE as a placeholder and is only safe while it is in "
                + "the future: once it is behind us, every capture recorded before it that has "
                + "no device record reads `unknownPostMigration` — 'this recording's device "
                + "record went missing' — about conversations that never owed one. Move it to "
                + "the release timestamp (TESTFLIGHT.md, 'Device-record migration epoch').")
    }

    /// The decision is written where the person cutting a release will meet it, not only in a
    /// doc comment on the constant it is about.
    func testTheEpochIsOnTheShippingChecklist() throws {
        let testflight = try String(
            contentsOf: Self.repoRoot.appendingPathComponent("TESTFLIGHT.md"), encoding: .utf8)
        XCTAssertTrue(testflight.contains("migrationEpoch"),
                      "TESTFLIGHT.md — the repo's actual shipping document — does not mention "
                          + "`migrationEpoch`, so the ship-checklist entry the decision depends "
                          + "on exists only inside the constant it is about")
        XCTAssertTrue(testflight.contains("CaptureDeviceSidecar"),
                      "the checklist entry must name the file the constant lives in, or it "
                          + "cannot be acted on")
    }
}
