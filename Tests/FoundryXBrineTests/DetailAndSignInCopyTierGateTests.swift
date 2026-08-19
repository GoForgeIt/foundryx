import XCTest
@testable import FoundryXKit

/// THE SENTENCES THAT WERE WRITTEN INSIDE SWIFTUI BODIES, NOW WHERE A TEST CAN RUN THEM.
///
/// X2 and X5. Three literals rendered to people and consulted no tier at all, in files
/// `swift test` cannot compile:
///
///   • "On-device transcript, finishing on your computer."  — chosen by `showingProvisional`
///     alone, with `destination` in scope four lines above and passed to the waits either
///     side of it.
///   • "Load this voice note's transcript from your computer." — branching only on `isOlder`.
///   • "End-to-end encrypted to your Mac · you choose what stays private" — on the SIGN-IN
///     screen, which runs before any brain is resolved, so it was false for a Vault owner,
///     false for a phone-only owner, and false for every new user, i.e. everyone who saw it.
///
/// They are `ConversationDetailCopy` and `SignInCustodyLine` now, and this suite sweeps
/// them the way the waits are swept — through the ONE `forbiddenPlaces` table.
final class DetailAndSignInCopyTierGateTests: XCTestCase {

    private func detailWords(_ destination: CaptureDestination) -> [String] {
        [ConversationDetailCopy.provisionalTranscriptNote(destination: destination),
         ConversationDetailCopy.loadTranscriptNote(isOlder: true, destination: destination),
         ConversationDetailCopy.loadTranscriptNote(isOlder: false, destination: destination),
         SignInCustodyLine.text(destination: destination)]
    }

    func testNoDetailOrSignInSentenceNamesAPlaceItsOwnerDoesNotHave() {
        var swept = 0
        for destination in CaptureDestination.allCases {
            let forbidden = WaitingCopySweep.forbiddenPlaces[destination] ?? []
            for text in detailWords(destination) {
                swept += 1
                XCTAssertFalse(text.isEmpty)
                for word in forbidden {
                    XCTAssertFalse(
                        WaitingCopySweep.mentions(word, in: text),
                        "the \(destination.rawValue) tier's detail/sign-in copy names a "
                        + "\(word) this owner does not have: \"\(text)\"")
                }
            }
        }
        XCTAssertEqual(swept, 12, "the population changed: \(swept) sentences")
    }

    /// THE SIGN-IN LINE NAMES NO PLACE WHEN THERE IS NO PLACE TO NAME. `nil` is the real,
    /// normal input on that screen — a tier has not been chosen yet — and the sentence must
    /// still be a true custody claim rather than a guess at hardware.
    func testTheSignInLineNamesNoMachineBeforeATierExists() {
        let line = SignInCustodyLine.text(destination: nil)
        for word in ["Mac", "computer", "Vault", "iPhone", "relay"] {
            XCTAssertFalse(WaitingCopySweep.mentions(word, in: line),
                           "the pre-tier sign-in line names a \(word): \"\(line)\"")
        }
        XCTAssertTrue(line.localizedCaseInsensitiveContains("your own devices"),
                      "the pre-tier line dropped its custody claim: \"\(line)\"")
        // And it is NOT the shipped sentence, which named a Mac to everyone.
        XCTAssertNotEqual(line,
                          "End-to-end encrypted to your Mac · you choose what stays private")
    }

    /// The two non-phone tiers do not share a sentence where one names the second place.
    func testTheVaultNeverInheritsTheComputersDetailSentence() {
        for (c, v) in zip(detailWords(.computer), detailWords(.vault))
        where WaitingCopySweep.mentions("computer", in: c)
            || WaitingCopySweep.mentions("Mac", in: c) {
            XCTAssertNotEqual(c, v, "the Vault inherits the computer's sentence: \"\(c)\"")
        }
    }
}

/// THE DEFAULT THE WHOLE X3 WIRING RESTS ON, MADE AN EXECUTABLE CLAIM.
///
/// `EnvironmentValues.captureDestination` must have a default, and this program's rule is
/// that a default about where a person's audio went is "a decision made by whoever
/// forgot". That rule is about defaults that can NAME A PLACE THE OWNER DOES NOT HAVE.
/// `CaptureDestinationEnvironment.fallback` is `.phone` precisely because the phone tier
/// names no second place at all — so a forgotten `.environment` degrades to saying LESS,
/// never to naming a machine somebody does not own.
///
/// This suite is what makes that an argument rather than an assertion. Change the fallback
/// to `.computer` and it goes red, because the computer tier is permitted to say "Mac",
/// "computer" and "relay" — none of which a phone-only owner has.
final class CaptureDestinationFallbackTests: XCTestCase {

    /// The fallback must be the tier that is forbidden from naming EVERY other place —
    /// i.e. the tier whose vocabulary is safe for a reader on any tier.
    func testTheFallbackTierIsForbiddenFromNamingEveryOtherPlace() {
        let fallback = CaptureDestinationEnvironment.fallback
        let forbidden = Set(WaitingCopySweep.forbiddenPlaces[fallback] ?? [])
        for place in ["Mac", "computer", "Vault", "relay"] {
            XCTAssertTrue(forbidden.contains(place),
                          "the environment fallback is .\(fallback.rawValue), which is "
                          + "ALLOWED to say \"\(place)\" — a surface that forgot to read the "
                          + "tier would then name a machine its reader may not have")
        }
    }

    /// AND THE FALLBACK'S OWN COPY IS ACTUALLY CLEAN, across every tier-varying surface in
    /// the program — not just permitted to be. This is the property the whole wiring rests
    /// on, so it is held over the real sentences rather than over the table.
    func testEverySurfaceRenderedAtTheFallbackNamesNoPlaceAtAll() {
        let fallback = CaptureDestinationEnvironment.fallback
        let forbidden = WaitingCopySweep.forbiddenPlaces[fallback] ?? []
        var texts: [String] = []
        for kind in WaitKind.allCases {
            texts += WaitingCopySweep.allStrings(kind: kind, destination: fallback)
        }
        for progress in ConversationProgress.allCases {
            texts.append(CaptureCardPresentation.statusWord(
                progress: progress, droppedReason: nil, destination: fallback))
            texts.append(progress.label(destination: fallback))
        }
        for step in ConversationProgress.Step.allCases {
            texts.append(step.label(destination: fallback))
        }
        texts.append(CaptureCardPresentation.manualRecoveryActionTitle(destination: fallback))
        texts.append(CaptureCardPresentation.manualRecoveryInProgressWord(destination: fallback))
        texts.append(CaptureCardPresentation.manualRecoveryHint(destination: fallback))
        texts.append(CaptureHomeCopy.recordSubtitle(destination: fallback))
        texts.append(ConversationDetailCopy.provisionalTranscriptNote(destination: fallback))
        texts.append(ConversationDetailCopy.loadTranscriptNote(isOlder: true, destination: fallback))
        texts.append(ConversationDetailCopy.loadTranscriptNote(isOlder: false, destination: fallback))
        texts.append(SignInCustodyLine.text(destination: fallback))
        texts.append(KilnLibraryCopy.subagentNoteText(destination: fallback))
        texts.append(SyncStripCopy.allSaved(destination: fallback))

        XCTAssertGreaterThan(texts.count, 80,
                             "VACUOUS: only \(texts.count) fallback sentences were swept")
        for text in texts {
            for word in forbidden {
                XCTAssertFalse(
                    WaitingCopySweep.mentions(word, in: text),
                    "a surface rendered at the environment fallback names a \(word): "
                    + "\"\(text)\"")
            }
        }
    }

    /// THE ON-DEVICE TITLING WAIT IS A KIND, NOT A PLACE. It says the same true thing on
    /// every tier, because the phone does that work on every tier — which is why the
    /// literal `destination: .phone` that used to sit in a view body could be deleted
    /// rather than moved.
    func testTheOnDeviceTitlingWaitSaysTheSameTrueThingOnEveryTier() {
        let copies = CaptureDestination.allCases.map {
            WaitCopy.make(for: .onDeviceTitle, destination: $0)
        }
        XCTAssertEqual(Set(copies.map(\.privacyLine)).count, 1,
                       "on-device titling differs by tier: \(copies.map(\.privacyLine))")
        XCTAssertTrue(copies[0].privacyLine.contains("on your iPhone"),
                      "on-device titling stopped naming the phone: \(copies[0].privacyLine)")
        // And it is a DIFFERENT wait from the brain's titling, or the type would be
        // decorative — the computer tier's `.title` names the computer, this never does.
        XCTAssertNotEqual(WaitCopy.make(for: .title, destination: .computer).privacyLine,
                          WaitCopy.make(for: .onDeviceTitle, destination: .computer).privacyLine)
    }
}
