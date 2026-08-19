import XCTest
@testable import FoundryXKit

/// THE SAME DEFECT CLASS, ON THE SURFACES `236c4b2` DID NOT CONVERT.
///
/// `3371f9d` fixed the saved-to line by replacing a Bool with `CaptureDestination`.
/// `236c4b2` fixed the WAITS the same way. Both stopped at the function in front of
/// them. `CaptureCardPresentation.statusWord` and `ConversationProgress.label` still
/// took `local: Bool` — one bit for a question with three answers — and `App/` derived
/// that bit as `destination == .phone`, which makes `.computer` and `.vault`
/// INDISTINGUISHABLE. So the conversation card on a Vault owner's home screen read
/// "Waiting for computer" and "Saved to computer", and the detail stepper read
/// "Saved to computer", for a computer he does not own.
///
/// The diagnosis was already written down in the very file that shipped the defect:
/// `CaptureHomeCopy.recordSubtitle(destination:)` carries the comment "(a Vault owner
/// used to read 'on your computer' because this was a Bool)" — converted, correct, and
/// sitting beside its unconverted sibling.
///
/// This suite is `WaitingDestinationGateTests` applied to the card, the chip and the
/// stepper. It reuses that file's `forbiddenPlaces` table rather than restating it, so
/// there is ONE answer in this repository to "what may this tier's owner be told about".
final class CardAndStepperTierWordsTests: XCTestCase {

    /// Every terminal reason the card can be handed, plus none.
    private let reasons: [String?] = [nil, "silent_no_transcript", "noise", "junk_purge",
                                      "key_lost", "something_nobody_mapped"]

    /// Every sentence the CARD can put in its status slot for a tier.
    private func cardWords(_ destination: CaptureDestination) -> [String] {
        var out: [String] = []
        for progress in ConversationProgress.allCases {
            for reason in reasons {
                out.append(CaptureCardPresentation.statusWord(
                    progress: progress, droppedReason: reason, destination: destination))
                out.append(CaptureCardPresentation.statusWord(
                    progress: progress, droppedReason: reason, destination: destination,
                    syncError: "incomplete: 3 segments"))
            }
            out.append(progress.label(destination: destination))
        }
        for step in ConversationProgress.Step.allCases {
            out.append(step.label(destination: destination))
        }
        out.append(CaptureCardPresentation.manualRecoveryActionTitle(destination: destination))
        out.append(CaptureCardPresentation.manualRecoveryInProgressWord(destination: destination))
        return out
    }

    /// THE CLAIM. No tier's card, chip or stepper names a place its owner does not have.
    func testNoCardOrStepperWordNamesAPlaceItsOwnerDoesNotHave() {
        var swept = 0
        for destination in CaptureDestination.allCases {
            let forbidden = WaitingCopySweep.forbiddenPlaces[destination] ?? []
            for text in cardWords(destination) {
                swept += 1
                for word in forbidden {
                    XCTAssertFalse(
                        WaitingCopySweep.mentions(word, in: text),
                        "the \(destination.rawValue) tier's card/stepper names a \(word) "
                        + "this owner does not have: \"\(text)\"")
                }
            }
        }
        XCTAssertGreaterThan(swept, 100, "VACUOUS: only \(swept) card words were swept")
    }

    /// AND THE TWO NON-PHONE TIERS ARE NOT THE SAME TIER. Where a sentence names the
    /// second place at all, the Vault's and the computer's must differ — that equality
    /// IS the crush. Sentences that name no place are allowed to be identical, because
    /// a sentence naming nowhere cannot name the wrong somewhere.
    func testWhereTheSecondPlaceIsNamedTheVaultAndTheComputerDiffer() {
        let computer = cardWords(.computer)
        let vault = cardWords(.vault)
        XCTAssertEqual(computer.count, vault.count)
        var named = 0
        for (c, v) in zip(computer, vault) {
            let namesAPlace = WaitingCopySweep.mentions("computer", in: c)
                || WaitingCopySweep.mentions("Mac", in: c)
            guard namesAPlace else { continue }
            named += 1
            XCTAssertNotEqual(c, v,
                              "the Vault tier inherits the computer's sentence byte for "
                              + "byte: \"\(c)\"")
        }
        XCTAssertGreaterThan(named, 3,
                             "VACUOUS: only \(named) card sentences name the second place")
    }

    /// The phone tier keeps its own words — it has no second place at all, and must never
    /// be told to wait for one.
    func testThePhoneTierIsNeverToldToWaitForAMachineItDoesNotHave() {
        for text in cardWords(.phone) {
            XCTAssertFalse(text.localizedCaseInsensitiveContains("waiting for"),
                           "the phone tier waits for something: \"\(text)\"")
        }
    }

    /// THE POPULATION IS DERIVED, NEVER LISTED. A seventh progress case added without a
    /// tier decision must arrive in the sweep above on its own.
    func testTheProgressPopulationIsTheWholeEnum() {
        XCTAssertEqual(ConversationProgress.allCases.count, 6,
                       "the progress population changed: \(ConversationProgress.allCases)")
        XCTAssertEqual(Set(ConversationProgress.allCases.map(\.rawValue)).count,
                       ConversationProgress.allCases.count)
    }

    /// No card word leaks a wire token — the same property the journey copy holds.
    func testNoCardWordLeaksAMachinesWordForSomething() {
        for destination in CaptureDestination.allCases {
            for text in cardWords(destination) {
                XCTAssertFalse(text.contains("_"), "a wire token reached a person: \"\(text)\"")
            }
        }
    }
}
