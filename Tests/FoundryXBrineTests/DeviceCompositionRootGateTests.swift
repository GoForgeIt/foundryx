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

    // MARK: - A remembered recorder has a way back to it, and it is not the Omi's

    /// WHAT THIS HOLDS THAT NO BEHAVIOURAL PROBE CAN. `RecordingDevicePage.resolve` appends
    /// connect/disconnect only `if canConnect`, and every Brine scenario calls `resolve(input)`
    /// — which DEFAULTS `canConnect` to `true`. So the kit suite has always drawn a Pocket page
    /// with a connect action on it, while the shipped screen passed `canConnect: isSavedOmi`,
    /// an expression that is false for every `.filePull` identity by construction. A remembered
    /// Pocket's page therefore carried no connect action at all, and `swift test` cannot
    /// compile `App/` to notice. This is that argument, read off the file.
    func testARememberedRecorderCanBeReachedFromItsOwnPage() throws {
        // BOTH FILES THE PAGE IS MADE OF, NAMED — never a glob over `App/`. The connect gate
        // moved into `RecorderPageModel.canReach` when the page's decisions were lifted out of
        // the SwiftUI body; the body that renders the result stayed here. A gate that read only
        // one of the two would pass over the half it can no longer see.
        let screen = try ["App/DeviceScreen.swift", "App/RecorderPageModel.swift"]
            .map { try String(contentsOf: Self.repoRoot.appendingPathComponent($0),
                              encoding: .utf8) }
            .joined(separator: "\n")

        // Non-vacuity FIRST: if the page moves out of this file, say so rather than pass for
        // having found nothing to check.
        // THE ANCHOR IS THE RENDER, NOT THE COMPOSITION, AND THAT IS A DELIBERATE MOVE.
        //
        // It was `screen.contains("RecordingDevicePage.resolve(")`. The composition is in
        // `App/RecorderPageModel.swift` now — a `@MainActor ObservableObject` the app-hosted
        // lane can construct and EXECUTE, which is the whole point of moving it: two mutations
        // to the page's re-read shipped green through this file's `contains()` assertions on
        // 2026-08-17. What is still here, and what these gates are about, is the body that
        // renders what that model decided.
        XCTAssertTrue(screen.contains("model.page(pushed: input)"),
                      "the device page is no longer rendered in App/DeviceScreen.swift — this "
                          + "gate is checking a file that no longer holds the boundary")

        XCTAssertFalse(
            screen.contains("RecordingDevicePage.resolve(input, canConnect: isSavedOmi)"),
            "the device page is resolved with `canConnect: isSavedOmi`. `isSavedOmi` compares "
                + "against a `.bleStream` identity, so it is false for every stored-file "
                + "recorder — which means a remembered Pocket's page offers no way to reach it "
                + "at all, and the scan sheet is the only surface left that can")
        XCTAssertTrue(
            screen.contains("input.deviceClass == .recordThenSync && input.isRemembered"),
            "the page's connect gate no longer admits a remembered record-then-sync recorder. "
                + "It must be reachable from its own page, or the only entry point to a device "
                + "the account already remembers is the pairing scan")
    }

    /// The check action is WIRED, and it is wired to the check — not to the Omi's connect arm
    /// it used to share a `case` with.
    ///
    /// `connectAndCheckAction` and `connectAction` were one branch that enabled the OMI capture
    /// source. That was harmless only because the action could never be offered for anything
    /// but an Omi; the line above makes it reachable for a Pocket, and a Pocket page whose
    /// connect button turns on a different device's live capture is a worse bug than the
    /// absence it replaced.
    func testTheCheckActionRunsTheCheckAndNotTheOmiCaptureToggle() throws {
        let screen = try String(
            contentsOf: Self.repoRoot.appendingPathComponent("App/DeviceScreen.swift"),
            encoding: .utf8)

        XCTAssertFalse(
            screen.contains("case RecordingDevicePage.connectAction, "
                            + "RecordingDevicePage.connectAndCheckAction:"),
            "\"Connect and check now\" shares its branch with the Omi's \"Connect\", which "
                + "enables `CaptureSourceDescriptor.omiId` — so tapping it on a stored-file "
                + "recorder's page turns on a DIFFERENT device's live capture")
        XCTAssertTrue(
            screen.contains("case RecordingDevicePage.connectAndCheckAction:"),
            "the check action has no branch of its own")
        XCTAssertTrue(
            screen.contains("check.run(hardwareToken:"),
            "nothing in App/ calls the check. `PocketRecorderCheck`, "
                + "`PocketInventoryReader`, `PocketBLEClient.listDates` and "
                + "`listRecordings(on:)` would then all be reachable-in-principle and called "
                + "by nobody, which is the exact state this work exists to leave behind")
        XCTAssertTrue(
            screen.contains("PocketRecorderCheck.run(peripheralIdentifier:"),
            "the app-side model no longer runs the shipped check")

        // AND THE ANSWER IS RENDERED. A check whose result reaches no surface is a Bluetooth
        // session opened for nothing.
        for rendered in ["PocketRecorderCheckPresentation.sectionTitle",
                         "PocketRecorderCheckPresentation.emptyLine",
                         "PocketRecorderCheckPresentation.sectionNote",
                         "detail.manifest.rows"] {
            XCTAssertTrue(screen.contains(rendered),
                          "App/DeviceScreen.swift does not render `\(rendered)`, so the check's "
                              + "answer never reaches a person")
        }
    }

    /// THE READINGS REACH A PERSON, AND THE UNASKED ONES OFFER TO BE ASKED.
    ///
    /// WHY THIS CANNOT BE A BRINE SCENARIO. `RecordingDevicePagePresentation.readings` is
    /// asserted over in `features/pocket-recorder-readings.feature`, and every one of those
    /// assertions would go on passing if `App/DeviceScreen.swift` rendered none of it — which
    /// is exactly the state `detail.battery` and `detail.firmware` are in on `main` today:
    /// built by `StoredFileDevicePresentation.detail`, asserted by
    /// `features/pocket-file-pull-device.feature`, and drawn nowhere. `swift test` cannot
    /// compile `App/`, so the boundary is read off the file.
    ///
    /// IT ALSO HOLDS THE SHAPE, not merely the mention. A strip that printed `line.value`
    /// unconditionally would render `Optional("84%")` for a fact that was read and the empty
    /// string for one that was not — a plausible-looking blank where the whole point is an
    /// offer to go and ask. So the two branches are named.
    func testTheRecorderPageRendersItsReadingsAndOffersToTakeTheMissingOnes() throws {
        let screen = try String(
            contentsOf: Self.repoRoot.appendingPathComponent("App/DeviceScreen.swift"),
            encoding: .utf8)

        // Non-vacuity first: this gate must be reading the file that holds the page.
        // THE ANCHOR IS THE RENDER, NOT THE COMPOSITION, AND THAT IS A DELIBERATE MOVE.
        //
        // It was `screen.contains("RecordingDevicePage.resolve(")`. The composition is in
        // `App/RecorderPageModel.swift` now — a `@MainActor ObservableObject` the app-hosted
        // lane can construct and EXECUTE, which is the whole point of moving it: two mutations
        // to the page's re-read shipped green through this file's `contains()` assertions on
        // 2026-08-17. What is still here, and what these gates are about, is the body that
        // renders what that model decided.
        XCTAssertTrue(screen.contains("model.page(pushed: input)"),
                      "the device page is no longer rendered in App/DeviceScreen.swift — this "
                          + "gate is checking a file that no longer holds the boundary")

        XCTAssertTrue(screen.contains("page.readings"),
                      "App/DeviceScreen.swift never reads `page.readings`, so the battery, "
                          + "free space and firmware a session went and measured reach no "
                          + "surface — the presentation would be built, asserted and drawn "
                          + "nowhere, which is the defect the reachability register exists for")
        // COMPOSED, NOT MERELY DECLARED. `screen.contains("readingsStrip")` is what this
        // assertion said first, and MUT-4 walked straight past it: deleting the one line in
        // the page body that renders the strip left the `private var readingsStrip` and a
        // doc comment mentioning it, so the substring was still there and the gate stayed
        // green over a page that draws nothing. What is checked now is a LINE whose whole
        // content is the reference — which is what a SwiftUI body composition looks like and
        // what a declaration never does.
        //
        // THE COMPOSITION IS NOW A BAND ARM. The page walks `RecorderPageLayout.order` and
        // dispatches on `RecorderPageBand`, so the reference is `case .readings: readingsStrip`
        // rather than a bare statement. The mutation this must still catch is the same one:
        // an arm rewired to draw nothing. Whitespace is collapsed so the check holds the
        // composition and not somebody's column alignment.
        let composes = screen.split(separator: "\n", omittingEmptySubsequences: false)
            .contains {
                $0.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ")
                    == "case .readings: readingsStrip"
            }
        XCTAssertTrue(composes,
                      "`readingsStrip` is declared but never composed into the page body, so "
                          + "the recorder's readings are built and drawn nowhere")

        // THE SHAPE, AND IT IS THE SAME CLAIM AS BEFORE THE STRIP WAS COMPRESSED: a fact that
        // was read renders its value AND the moment it was read; a fact nobody asked renders
        // neither and offers the action instead.
        //
        // WHAT CHANGED IS WHERE THE MOMENT AND THE OFFER LIVE, not whether they are drawn.
        // `RecordingDeviceReadingPresentation.strip(_:)` decides what the whole strip shares,
        // because three facts read by one check used to print three copies of "read just now"
        // and three copies of the SAME "Connect and check now" button — one errand offered
        // three times. So BOTH age branches are named (the shared one and the per-line
        // fallback for a strip whose readings disagree), and so is the single offer.
        for branch in ["if let value = line.value",
                       "RecordingDeviceReadingPresentation.strip(",
                       "if let shared = strip.sharedAge",
                       "strip.sharedAge == nil, let ago = line.observedAgo",
                       "if !strip.unread.isEmpty",
                       "if let ask = strip.askAction"] {
            XCTAssertTrue(screen.contains(branch),
                          "App/DeviceScreen.swift does not carry `\(branch)`. A fact that was "
                              + "read must render its value AND its age; a fact nobody asked "
                              + "must render neither and offer the action instead")
        }
        // AND THE OFFER IS THE REAL ONE. `perform` is the same switch the page's own actions
        // go through, so this button opens a session rather than being decorative.
        XCTAssertTrue(screen.contains("Button(ask) { perform(ask) }"),
                      "the \"nobody has asked\" row's action is not wired to `perform`, so the "
                          + "page states an absence and offers a control that does nothing")
        // AND EVERY UNASKED FACT IS STILL NAMED. The compression removed the repeated BUTTON,
        // never the labels — a strip that silently drops what it has not got is the
        // `Unavailable` defect with the row deleted instead of the word.
        XCTAssertTrue(screen.contains("ForEach(Array(strip.unread.enumerated()), id: \\.offset)"),
                      "the page does not draw the facts nobody has asked for — compressing the "
                          + "strip must remove the repetition, never a fact")

        // THE NAMED RESIDUE, MEASURED RATHER THAN CLAIMED.
        //
        // `StoredFileDevicePresentation.detail` still falls back to
        // `RecordingDeviceConnectPresentation.unavailableValue` for its `battery` and
        // `firmware`. Step 7 says the word becomes unreachable for a Pocket recorder, and the
        // honest way to hold that for these two fields is to measure that NOTHING RENDERS
        // THEM: the shelf panel draws the manifest and the custody promise, never the hero
        // pair. If a future change starts drawing them, this goes red and that change has to
        // decide what an unread battery says there — which is the decision Step 7 made
        // everywhere a person can actually see.
        for unrendered in ["detail.battery", "detail.firmware"] {
            XCTAssertFalse(screen.contains(unrendered),
                           "App/DeviceScreen.swift now renders `\(unrendered)`, which falls "
                               + "back to the word \"Unavailable\" for a fact nobody read. "
                               + "Readings are the surface for that now (`page.readings`), and "
                               + "the two words this step removed cannot come back through a "
                               + "presentation nobody re-examined")
        }
    }

    /// A COMPLETED CHECK CHANGES THE PAGE THE CHECK WAS RUN FROM.
    ///
    /// WHY THIS CANNOT BE A BRINE SCENARIO EITHER, AND IT IS THE SAME REASON AS THE GATE ABOVE.
    /// `features/a-check-changes-the-page-it-was-run-from.feature` holds the KIT half: given a
    /// recorder nobody has checked, the shipped check writes its charge, its firmware and its
    /// free space to the account's store, and `RecordingDevicePageFacts.refreshed` folds them
    /// back into the value the page renders. Every one of those assertions goes on passing
    /// while `App/` never calls the refresh — which is the state `main` was in: the page is
    /// built from the `RecordingDeviceListInput` captured when the row's `NavigationLink` was
    /// pushed (`devicePage(for:)`), and `RecordingDeviceListModel.refresh` fires only on the
    /// Omi's connection state, its battery, `saved` or `sources`, none of which a check on a
    /// record-then-sync recorder touches. So the shelf filled with recordings while Battery,
    /// Free space and Firmware each went on offering "Connect and check now" over numbers
    /// already on the phone's disk.
    ///
    /// AND THE HEADER, WHICH IS THE SAME DEFECT FROM THE OTHER END. `page.status` was
    /// `input.link.label` for every class. A record-then-sync recorder has no live link — the
    /// check opens its own session and closes it — so the header read "Not connected" while
    /// Solleva was actively listing that recorder's files. The only live state this class has
    /// is what a CHECK is doing, and this holds that the view feeds the check's own state in.
    func testACompletedCheckIsReReadIntoThePageItWasRunFrom() throws {
        let screen = try String(
            contentsOf: Self.repoRoot.appendingPathComponent("App/DeviceScreen.swift"),
            encoding: .utf8)

        // NON-VACUITY FIRST: this gate must be reading the file that holds the page.
        // THE ANCHOR IS THE RENDER, NOT THE COMPOSITION, AND THAT IS A DELIBERATE MOVE.
        //
        // It was `screen.contains("RecordingDevicePage.resolve(")`. The composition is in
        // `App/RecorderPageModel.swift` now — a `@MainActor ObservableObject` the app-hosted
        // lane can construct and EXECUTE, which is the whole point of moving it: two mutations
        // to the page's re-read shipped green through this file's `contains()` assertions on
        // 2026-08-17. What is still here, and what these gates are about, is the body that
        // renders what that model decided.
        XCTAssertTrue(screen.contains("model.page(pushed: input)"),
                      "the device page is no longer rendered in App/DeviceScreen.swift — this "
                          + "gate is checking a file that no longer holds the boundary")
        XCTAssertTrue(screen.contains("check.run(hardwareToken:"),
                      "App/DeviceScreen.swift no longer runs a check, so there is no completed "
                          + "check for this gate to be about")

        // THE PAGE IS COMPOSED IN A TYPE SOMETHING CAN RUN. This is now the whole job of this
        // gate, and it is deliberately the ONLY structural claim left in it.
        //
        // WHAT WAS HERE BEFORE, AND WHY IT IS GONE. Five more `contains()` assertions stood
        // where this one does — that `RecordingDevicePageFacts.refreshed(` appeared, that
        // `onChange(of: check.isChecking)` appeared, that a particular `resolve(` spelling did
        // NOT, that `RecordingDeviceCheckState.resolve(isChecking:` appeared, and that
        // `check.isChecking` appeared. On 2026-08-17 all five were measured:
        //
        //   * `guard !checking` → `guard checking` in the body's `onChange` moved the re-read
        //     to the RISING edge, so a finished check's numbers reached the page never.
        //     `swift test --filter FoundryXBrineTests`: 1536 executed, 0 failures. The
        //     app-hosted lane: 7 executed, 0 failures. Every one of the five strings was still
        //     in the file, because none of them is about the comparison.
        //   * `refreshedInput = refreshed` → `_ = await …` discarded the disk read's result.
        //     Same, green.
        //   * and the last of them, `screen.contains("check.isChecking")`, was VACUOUS: that
        //     string appears 5 times in `git show 02ad015^:App/DeviceScreen.swift`, the file as
        //     it stood BEFORE the fix this gate was written to hold. It could never fail.
        //
        // The behaviour lives in `Tests/FoundryXAppScenarioTests/CheckRefreshesThePageFeature
        // Tests.swift` now, which builds the real `RecorderPageModel`, drives a real check over
        // a scripted radio inside the shipping app's process, and reads the presentation the
        // body renders. There is no string there for a mutation to satisfy.
        //
        // WHAT IS LEFT HERE IS THE ANCHOR ABOVE and nothing else. `model.page(pushed: input)`
        // is a claim this file can still honestly make: the page is rendered from a value some
        // OTHER lane decided, which is the property that makes the other lane possible.
    }

    /// THE BRING-OVER'S CONVERSATION IS HANDED TO THE RUNNING APP.
    ///
    /// WHY THIS GATE IS THE WHOLE POINT. `PocketCaptureImport` can write a complete, correct,
    /// pending-finalize capture directory and the app can still show the owner nothing: a
    /// `CaptureManager` hydrates its library ONCE, in `loadExisting()`, at construction. A
    /// conversation created while the app is already open is therefore invisible — and
    /// un-uploaded — until the next launch unless somebody calls `adoptCompletedCapture`.
    /// That is the same shape as the defect this track exists to end, where
    /// `PocketBLEClient.download` shipped fully implemented and fully unit-tested with no
    /// caller: every Brine scenario about the import can be green while nobody can reach it.
    ///
    /// `swift test` cannot compile `App/`, so this reads the file.
    func testABroughtOverConversationIsHandedToTheRunningCaptureOwner() throws {
        let screen = try String(
            contentsOf: Self.repoRoot.appendingPathComponent("App/DeviceScreen.swift"),
            encoding: .utf8)

        // NON-VACUITY FIRST: the affordance this gate is about is still on this screen. It
        // used to anchor on `PocketBringOver.run(peripheralIdentifier:` — the one-file,
        // one-session transfer the page owned before it owned a queue.
        XCTAssertTrue(screen.contains("let queue = PocketTransferQueue("),
                      "App/DeviceScreen.swift no longer runs the bring-over — this gate is "
                          + "checking a file that no longer holds the boundary")

        XCTAssertTrue(screen.contains("manager.adoptCompletedCapture(captureId:"),
                      "nothing in App/ hands the brought-over conversation to the capture "
                          + "owner, so the recording is a directory on disk that the running "
                          + "app does not know exists and will not upload until relaunch")
        XCTAssertTrue(screen.contains("follow.adoptCaptureID"),
                      "the hand-off does not read the capture the bring-over actually produced")

        // AND IT HAPPENS WHETHER OR NOT THE PAGE IS STILL THERE.
        //
        // THIS IS THE HALF THE OLD GATE COULD NOT SEE. The hand-off used to sit BEHIND
        // `guard let self, !Task.isCancelled` — so a transfer the owner walked away from wrote
        // every byte, built the conversation, and told nothing in the running app about it. A
        // transfer that outlives its page is worth nothing if its RESULT does not, and the
        // ordering of these two lines is the whole difference. `swift test` cannot compile
        // `App/`, so it is read as a position in the file.
        // SCOPED TO THE TRANSFER'S OWN ERRAND. `guard let self else { return }` is an ordinary
        // shape in this file — the list screen has one 2,000 lines above — so the search starts
        // at the queue this errand builds, and an unscoped comparison would be answering about
        // somebody else's task.
        guard let errand = screen.range(of: "let queue = PocketTransferQueue(") else {
            return XCTFail("the bring-over no longer builds a transfer queue")
        }
        let tail = screen[errand.upperBound...]
        guard let adopt = tail.range(of: "manager.adoptCompletedCapture(captureId:"),
              let pageOnly = tail.range(of: "guard let self else { return }") else {
            return XCTFail("the bring-over's durable half and its page half are no longer "
                               + "distinguishable in App/DeviceScreen.swift")
        }
        XCTAssertTrue(adopt.lowerBound < pageOnly.lowerBound,
                      "the conversation is handed to the capture owner only AFTER `guard let "
                          + "self`, so leaving the recorder page mid-transfer loses the "
                          + "recording the transfer completed")
        // AND THE MANAGER REACHES THE PAGE THAT DOES IT. Without this the call above cannot
        // compile — but the gate says so in words rather than leaving it to the build.
        XCTAssertTrue(screen.contains("into: manager"),
                      "the device page's bring-over is not given a capture owner to hand to")
        XCTAssertTrue(screen.contains("manager: manager"),
                      "the recording-device page is built without the capture owner")

        // THE DECLARATION, HELD TOO, so the hole cannot be reopened by widening the seam back
        // into something a caller can satisfy by omission.
        let manager = try String(
            contentsOf: Self.repoRoot
                .appendingPathComponent("Sources/FoundryXKit/CaptureManager.swift"),
            encoding: .utf8)
        XCTAssertTrue(
            manager.contains("public func adoptCompletedCapture(captureId: String) -> Bool"),
            "`adoptCompletedCapture` is not the shape App/ calls")
        XCTAssertFalse(
            manager.contains("func adoptCompletedCapture(captureId: String, source:"),
            "adoption grew a source parameter — it takes a capture id and nothing else, "
                + "because it cannot be allowed to care which producer wrote the capture")
    }
}
