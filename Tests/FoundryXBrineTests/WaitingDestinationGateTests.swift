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
enum WaitingCopySweep {
    static func allStrings(kind: WaitKind, destination: CaptureDestination) -> [String] {
        let copy = WaitCopy.make(for: kind, destination: destination)
        var out = [copy.headline, copy.privacyLine]
        out += WaitPhaseText.ladder(for: kind, destination: destination).map(\.text)
        if kind == .sync,
           let label = WaitProgressLabel.syncLabel(.determinate(done: 3, total: 8),
                                                  destination: destination) {
            out.append(label)
        }
        out += WaitingTipDeck(kind: kind, destination: destination,
                              stats: .init(conversationCount: 1284, segmentsOnComputer: 9021))
            .tips.map(\.text)
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
