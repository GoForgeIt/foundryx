import XCTest
import Foundation
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
    /// `App/` call sites. It rejects the two spellings that would satisfy it vacuously.
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
            for vacuous in ["setAccountScopeForGapOutcomes(nil)",
                            "setAccountScopeForGapOutcomes(nil as String?)"] {
                XCTAssertFalse(source.contains(vacuous),
                               "\(path) hands the gap-outcome scope a literal `nil`, which "
                                   + "withholds every outcome from its own account forever "
                                   + "while satisfying every source-text check of this wiring")
            }
        }
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
