import XCTest
@testable import FoundryXKit

// THE GATE THIS DEFECT CLASS GETS. A cell owner read "Speech-to-text runs on your own
// Mac — the audio never goes to a server we run" because `WaitCopy.make` was a two-way
// Bool and `.vault` fell into the `.computer` arm byte-identically — the same crush
// 3371f9d fixed for the saved-to line and did NOT generalise. This suite is the
// `CaptureSavedToLineFeatureTests` shape applied to every wait: destinations are
// enumerated FROM `CaptureDestination.allCases` (never a hand-written list), and every
// string a wait can render is swept, so a fourth brain arrives here without anyone
// remembering to add it.
//
// MUTATION-PROVEN: making the `.vault` transcription arm return the `.computer` copy,
// making the vault sync label read "safely on your computer", and giving the vault deck
// the computer evergreen each turn this suite RED (run 2026-08-18).

/// Every string a wait can put on screen for a (kind, destination) pair: the copy,
/// the elapsed phase ladder, the determinate sync label, and the full tip deck with
/// stats present so the stat tips are swept too.
///
/// IT IS BUILT FROM `WaitingExperienceModel`, NOT FROM THE STATIC PIECES.
///
/// The first version of this sweep called `WaitCopy.make`, `WaitPhaseText.ladder`,
/// `WaitProgressLabel.syncLabel` and `WaitingTipDeck.init` directly — the four
/// ingredients — and never once asked the MODEL the view actually binds to. Every
/// ingredient was exhaustive over `CaptureDestination` and every ingredient was
/// correct, and the suite was still blind to the only place the tier can be lost: the
/// COMPOSITION. `WaitingExperienceModel.statusLine` and `.tipDeck` each pass
/// `destination` down by hand, and pinning either of those hand-offs to `.computer`
/// left this file, and every other, green while a Vault owner read
/// "Still reaching your Mac — the tunnel may be waking up."
///
/// So the sweep now renders through the model: `model.copy`, `model.statusLine(elapsed:)`
/// at every elapsed the ladders can select, and `model.tip(elapsed:)` across a full
/// rotation of the deck. What is swept is what is rendered.
enum WaitingCopySweep {
    /// Library counts that make the stat tips real (a nil count drops its tip, which
    /// would silently shrink the swept population).
    static let sweepStats = WaitingLibraryStats(conversationCount: 1284,
                                                segmentsOnComputer: 9021)

    /// The elapsed seconds the sweep drives `statusLine` at: 0 (the base line stands),
    /// every threshold on every ladder in the file — taken over ALL destinations, so a
    /// leg pinned to the wrong tier is still driven past its own rungs — and one value
    /// past the last rung.
    static func sweepElapsed(kind: WaitKind) -> [TimeInterval] {
        var out: Set<TimeInterval> = [0]
        for destination in CaptureDestination.allCases {
            for rung in WaitPhaseText.ladder(for: kind, destination: destination) {
                out.insert(rung.after)
                out.insert(rung.after + 0.5)
            }
        }
        out.insert(600)
        return out.sorted()
    }

    static func allStrings(kind: WaitKind, destination: CaptureDestination) -> [String] {
        // The sync label is only reachable through a determinate progress; the model
        // ignores it for every other kind, exactly as the view does.
        let model = WaitingExperienceModel(kind: kind, destination: destination,
                                           progress: .determinate(done: 3, total: 8),
                                           stats: sweepStats)
        var out = [model.copy.headline, model.copy.privacyLine]
        // THE STATUS LINE, as rendered — the sync count for sync, the phase phrase once
        // a rung is reached, the privacy line before that.
        out += sweepElapsed(kind: kind).map { model.statusLine(elapsed: $0) }
        // THE WHOLE DECK, through the model's own rotation rather than a deck built here:
        // `rotationIndex` turns each multiple of the rotation interval into the next tip.
        let deckSize = model.tipDeck.count
        out += (0..<deckSize).map {
            model.tip(elapsed: TimeInterval($0) * WaitingExperienceModel.tipRotationInterval).text
        }
        return out
    }

    /// The places a destination's owner does NOT have, as whole words. The phone is on
    /// every tier (the app runs on it), so "phone"/"iPhone" is never forbidden. The
    /// relay exists ONLY on the computer tier — the cell is a direct HTTPS door and the
    /// phone tier never leaves the device — so "relay" is forbidden everywhere else.
    static let forbiddenPlaces: [CaptureDestination: [String]] = [
        .phone: ["Mac", "computer", "Vault", "relay"],
        .computer: ["Vault"],
        .vault: ["Mac", "computer", "relay"],
    ]

    /// Whole-word, case-insensitive mention — "machine" must NOT count as "Mac".
    static func mentions(_ word: String, in text: String) -> Bool {
        text.range(of: "\\b\(word)\\b", options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// The waits whose mechanism (and therefore words) differ by tier. `recap` runs on
    /// the phone on every tier and is allowed to say the same true thing three times.
    static let tierDifferingKinds: [WaitKind] = [.title, .transcription, .doorFetch, .sync]
}

final class WaitingDestinationGateTests: XCTestCase {

    /// A fourth brain must arrive HERE without anyone remembering: the population is
    /// `CaptureDestination.allCases`, and the forbidden-places table must cover it.
    func testForbiddenPlaceTableCoversEveryDestination() {
        for destination in CaptureDestination.allCases {
            XCTAssertNotNil(WaitingCopySweep.forbiddenPlaces[destination],
                            "no forbidden-places row for \(destination.rawValue) — a new "
                            + "tier arrived without deciding what it must never claim")
        }
    }

    /// (a) No destination's words name a place its owner does not have. This is the
    /// exact sentence Nick's screenshot violated: a Vault owner told about "your own Mac".
    func testNoWaitNamesAPlaceItsOwnerDoesNotHave() {
        for destination in CaptureDestination.allCases {
            let forbidden = WaitingCopySweep.forbiddenPlaces[destination] ?? []
            for kind in WaitKind.allCases {
                for text in WaitingCopySweep.allStrings(kind: kind, destination: destination) {
                    for word in forbidden {
                        XCTAssertFalse(
                            WaitingCopySweep.mentions(word, in: text),
                            "the \(destination.rawValue) tier's \(kind.rawValue) wait names "
                            + "a \(word) this owner does not have: \"\(text)\"")
                    }
                }
            }
        }
    }

    /// (b) For the waits whose mechanism differs by tier, no two destinations share a
    /// sentence — two tiers rendering the SAME words is the exact shape of the defect.
    func testTierDifferingWaitsNeverShareASentence() {
        for kind in WaitingCopySweep.tierDifferingKinds {
            let rendered = CaptureDestination.allCases.map { destination -> String in
                let copy = WaitCopy.make(for: kind, destination: destination)
                return copy.headline + "\n" + copy.privacyLine
            }
            XCTAssertEqual(Set(rendered).count, rendered.count,
                           "two destinations render the SAME \(kind.rawValue) copy — "
                           + "the .vault-falls-into-.computer crush: \(rendered)")
        }
    }

    /// (c) Only the phone tier may claim the audio never leaves the device, and no
    /// non-phone tier may headline transcription as "local" — it is remote (and private),
    /// and those are different claims.
    func testOnlyThePhoneTierClaimsTheAudioStaysOnTheDevice() {
        for destination in CaptureDestination.allCases where destination != .phone {
            for kind in WaitKind.allCases {
                for text in WaitingCopySweep.allStrings(kind: kind, destination: destination) {
                    XCTAssertFalse(text.localizedCaseInsensitiveContains("never leaves"),
                                   "the \(destination.rawValue) tier claims audio stays on "
                                   + "the device: \"\(text)\"")
                }
            }
            let transcription = WaitCopy.make(for: .transcription, destination: destination)
            XCTAssertFalse(transcription.headline.localizedCaseInsensitiveContains("locally"),
                           "the \(destination.rawValue) tier headlines transcription as "
                           + "local: \"\(transcription.headline)\"")
        }
    }

    /// (d) The relay exists only on the computer tier, and its wait may still say so.
    func testTheRelaySentenceSurvivesOnTheComputerTier() {
        let copy = WaitCopy.make(for: .doorFetch, destination: .computer)
        XCTAssertTrue(copy.privacyLine.localizedCaseInsensitiveContains("relay"),
                      "the computer tier's doorFetch dropped its true relay sentence")
    }

    /// The false sentence from the screenshot, pinned OUT: no vault string may deny
    /// that the audio goes to a machine we operate, and the vault's transcription wait
    /// must name the Vault.
    func testTheVaultTranscriptionWaitTellsTheTruth() {
        let copy = WaitCopy.make(for: .transcription, destination: .vault)
        XCTAssertTrue(copy.headline.contains("Vault"),
                      "vault transcription headline does not name the Vault: \"\(copy.headline)\"")
        for kind in WaitKind.allCases {
            for text in WaitingCopySweep.allStrings(kind: kind, destination: .vault) {
                XCTAssertFalse(text.contains("never goes to a server"),
                               "the vault tier denies the server it IS: \"\(text)\"")
            }
        }
    }

    // MARK: - THE COMPOSITION SEAM

    /// THE DEFECT CLASS, HELD AT THE JOIN.
    ///
    /// `WaitingExperienceModel.statusLine` is the string the app renders under the
    /// headline, and it forwards `destination` to `WaitPhaseText.phrase` BY HAND. Pinning
    /// that one argument to `.computer` is a one-line, compiling edit that used to leave
    /// every suite in this repository green while a Vault owner read "Still reaching your
    /// Mac — the tunnel may be waking up." Held here over the whole population: every
    /// destination, every kind, every elapsed either ladder can select.
    func testTheRenderedStatusLineNeverNamesAPlaceItsOwnerDoesNotHave() {
        var swept = 0
        for destination in CaptureDestination.allCases {
            let forbidden = WaitingCopySweep.forbiddenPlaces[destination] ?? []
            for kind in WaitKind.allCases {
                let model = WaitingExperienceModel(kind: kind, destination: destination,
                                                   progress: .determinate(done: 3, total: 8),
                                                   stats: WaitingCopySweep.sweepStats)
                for elapsed in WaitingCopySweep.sweepElapsed(kind: kind) {
                    let line = model.statusLine(elapsed: elapsed)
                    swept += 1
                    for word in forbidden {
                        XCTAssertFalse(
                            WaitingCopySweep.mentions(word, in: line),
                            "the \(destination.rawValue) tier's \(kind.rawValue) status line "
                            + "at \(elapsed)s names a \(word) this owner does not have: "
                            + "\"\(line)\" — the model's own destination hand-off is wrong")
                    }
                }
            }
        }
        XCTAssertGreaterThan(swept, 40, "VACUOUS: only \(swept) status lines were driven")
    }

    /// AND THE PHASE LEG IS ACTUALLY REACHED. A status line sweep that never gets past
    /// the first rung only ever sees the privacy line, and would pass with the phase leg
    /// wired to any tier at all. So: the door wait, past its rung, must render its OWN
    /// tier's phrase — three destinations, three distinct sentences, none of them the
    /// base copy.
    func testTheStatusLinePhaseLegIsDrivenAndIsTierSpecific() {
        let phrases = CaptureDestination.allCases.map { destination -> String in
            let model = WaitingExperienceModel(kind: .doorFetch, destination: destination)
            return model.statusLine(elapsed: 30)
        }
        XCTAssertEqual(Set(phrases).count, phrases.count,
                       "two tiers render the same door phase line: \(phrases)")
        for (destination, phrase) in zip(CaptureDestination.allCases, phrases) {
            let base = WaitCopy.make(for: .doorFetch, destination: destination).privacyLine
            XCTAssertNotEqual(phrase, base,
                              "the \(destination.rawValue) door status line never left the "
                              + "base copy — the phase leg is not being driven")
        }
        XCTAssertEqual(
            WaitingExperienceModel(kind: .doorFetch, destination: .vault).statusLine(elapsed: 30),
            "Still reaching your Vault — it may be waking up.")
    }

    /// The other hand-off on the same struct: `tipDeck` passes `destination` down by hand
    /// too, so a tip deck can be pinned to a tier the owner is not on while the deck TYPE
    /// stays exhaustive and every deck test stays self-consistent. The model's deck must
    /// be its own tier's deck, and no two tiers' decks may be equal.
    func testTheModelsTipDeckIsItsOwnTiersDeck() {
        for kind in WaitKind.allCases {
            var decks: [WaitingTipDeck] = []
            for destination in CaptureDestination.allCases {
                let model = WaitingExperienceModel(kind: kind, destination: destination,
                                                   stats: WaitingCopySweep.sweepStats)
                XCTAssertEqual(model.tipDeck,
                               WaitingTipDeck(kind: kind, destination: destination,
                                              stats: WaitingCopySweep.sweepStats),
                               "the \(destination.rawValue) tier's \(kind.rawValue) model "
                               + "hands its deck a destination that is not its own")
                decks.append(model.tipDeck)
            }
            XCTAssertEqual(Set(decks.map { $0.tips.map(\.text).joined(separator: "|") }).count,
                           decks.count,
                           "two tiers get the byte-identical \(kind.rawValue) deck")
        }
    }

    /// The sweep is not allowed to be a small one. If a leg stops contributing strings —
    /// a nil stat, an empty ladder, a deck that collapsed — the tier claims above go
    /// quietly vacuous, which is how a green suite hid this defect for a whole wave.
    func testTheSweptPopulationIsLargeEnoughToMeanSomething() {
        var total = 0
        for destination in CaptureDestination.allCases {
            for kind in WaitKind.allCases {
                let strings = WaitingCopySweep.allStrings(kind: kind, destination: destination)
                XCTAssertGreaterThanOrEqual(
                    strings.count, 8,
                    "the \(destination.rawValue)/\(kind.rawValue) sweep is \(strings.count) "
                    + "strings — a leg stopped contributing")
                XCTAssertFalse(strings.contains(where: \.isEmpty),
                               "an empty string reached the sweep for "
                               + "\(destination.rawValue)/\(kind.rawValue)")
                total += strings.count
            }
        }
        XCTAssertGreaterThan(total, 150, "VACUOUS: the whole sweep is \(total) strings")
    }

    /// The sync count names its own destination on all three tiers, distinctly.
    func testSyncLabelNamesEachDestinationDistinctly() {
        let labels = CaptureDestination.allCases.compactMap {
            WaitProgressLabel.syncLabel(.determinate(done: 3, total: 8), destination: $0)
        }
        XCTAssertEqual(labels.count, CaptureDestination.allCases.count)
        XCTAssertEqual(Set(labels).count, labels.count,
                       "two destinations share a sync count line: \(labels)")
    }
}
