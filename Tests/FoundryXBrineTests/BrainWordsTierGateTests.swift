import XCTest
@testable import FoundryXKit

/// THE SENTENCES THAT SEND A PERSON SOMEWHERE, HELD OVER EVERY TIER.
///
/// `KilnLibraryCopy` and `DoorFailureMessage` were written when there was exactly one
/// other place a person's things could live, so they said "your Mac" unconditionally.
/// A Vault owner whose cell was unreachable read **"Open Solleva on your Mac and make
/// sure it's awake"** — an instruction that looks actionable and cannot be acted on,
/// which is worse than saying nothing. A phone-only owner read "No computer is
/// connected" about a computer that was never part of his product.
///
/// These are the cheapest surfaces in the program to get right, because unlike the copy
/// in `App/` they are in the kit, where a test can execute them. This suite reuses
/// `WaitingDestinationGateTests.forbiddenPlaces` — the one table — rather than restating
/// what each tier may be told about.
final class BrainWordsTierGateTests: XCTestCase {

    private let reaches: [MacReach] = [.reachable, .noComputer, .unreachable("Timed out.")]
    private let coverages: [ChatListCoverage] = [
        .complete, .truncated(shownFromMac: 20, totalOnMac: 90),
        .thisPhoneOnly(reason: "It did not answer."), .pending,
    ]
    private let statuses: [RemoteSession.Status] = [
        .noHost, .resolving, .signedOut, .unconfigured,
        .connected(host: "h-1"), .error("boom"),
    ]

    /// Every sentence these two files can put in front of a person on one tier.
    private func brainWords(_ destination: CaptureDestination) -> [String] {
        var out: [String] = []
        for r in reaches {
            out.append(KilnLibraryCopy.reason(r, destination: destination))
            if let l = KilnLibraryCopy.reachLine(r, destination: destination) { out.append(l) }
        }
        for c in coverages {
            for searching in [true, false] {
                if let l = KilnLibraryCopy.coverageLine(c, searching: searching,
                                                        destination: destination) {
                    out.append(l)
                }
            }
        }
        for s in statuses {
            let m = DoorFailureMessage.make(status: s, underlying: nil, destination: destination)
            out.append(m.text)
            if let a = m.action { out.append(a) }
        }
        let transport = DoorFailureMessage.make(doorTransportFailure: DoorError.transport("x"),
                                                destination: destination)
        out.append(transport.text)
        if let a = transport.action { out.append(a) }
        for e in [KilnLibraryError.noSession, .unreachable, .unauthorized] {
            let m = DoorFailureMessage.make(kilnLibraryFailure: e, destination: destination)
            out.append(m.text)
            if let a = m.action { out.append(a) }
        }
        out.append(KilnLibraryCopy.subagentNoteText(destination: destination))
        return out.filter { !$0.isEmpty }
    }

    /// THE CLAIM. No tier is told about a machine it does not have.
    func testNoBrainSentenceNamesAPlaceItsOwnerDoesNotHave() {
        var swept = 0
        for destination in CaptureDestination.allCases {
            let forbidden = WaitingCopySweep.forbiddenPlaces[destination] ?? []
            for text in brainWords(destination) {
                swept += 1
                for word in forbidden {
                    XCTAssertFalse(
                        WaitingCopySweep.mentions(word, in: text),
                        "the \(destination.rawValue) tier's brain copy names a \(word) this "
                        + "owner does not have: \"\(text)\"")
                }
            }
        }
        XCTAssertGreaterThan(swept, 60, "VACUOUS: only \(swept) brain sentences were swept")
    }

    /// NOBODY IS SENT TO A MACHINE THEY DO NOT OWN. The action half of these messages is
    /// an instruction; an instruction naming the wrong machine is the specific harm here,
    /// so it gets its own claim rather than riding on the sweep above.
    func testNoTierIsToldToGoAndFixAMachineItDoesNotHave() {
        for destination in CaptureDestination.allCases where destination != .computer {
            for status in statuses {
                let action = DoorFailureMessage.make(status: status, underlying: nil,
                                                     destination: destination).action ?? ""
                XCTAssertFalse(action.localizedCaseInsensitiveContains("on your Mac"),
                               "the \(destination.rawValue) tier is sent to a Mac: \"\(action)\"")
            }
            let action = DoorFailureMessage.make(doorTransportFailure: DoorError.transport("x"),
                                                 destination: destination).action ?? ""
            XCTAssertFalse(action.localizedCaseInsensitiveContains("on your Mac"),
                           "the \(destination.rawValue) tier is sent to a Mac: \"\(action)\"")
        }
        // The computer tier's instruction is TRUE and must survive — a gate that passed by
        // deleting every actionable sentence would be worse than the defect.
        XCTAssertEqual(
            DoorFailureMessage.make(doorTransportFailure: DoorError.transport("x"),
                                    destination: .computer).action,
            "Open Solleva on your Mac and make sure it's awake.")
    }

    /// THE PHONE TIER HAS NO SECOND PLACE, so it is never told that something is missing
    /// from a list because somewhere else could not be reached.
    func testThePhoneTierIsNeverToldSomethingIsMissingFromSomewhereElse() {
        for text in brainWords(.phone) {
            XCTAssertFalse(text.localizedCaseInsensitiveContains("aren't listed"),
                           "the phone tier claims chats exist elsewhere: \"\(text)\"")
            XCTAssertFalse(text.localizedCaseInsensitiveContains("were not searched"),
                           "the phone tier claims a place went unsearched: \"\(text)\"")
        }
    }

    /// A SEARCH STILL STATES ITS SCOPE ON EVERY TIER. The honesty invariant these
    /// functions were written for must survive the conversion: a result set with no
    /// stated scope is a partial answer wearing a complete one's clothes.
    func testASearchAlwaysStatesItsScopeOnEveryTier() {
        for destination in CaptureDestination.allCases {
            for coverage in coverages {
                XCTAssertNotNil(
                    KilnLibraryCopy.coverageLine(coverage, searching: true,
                                                 destination: destination),
                    "the \(destination.rawValue) tier searched and said nothing about scope")
            }
            // And a complete, unsearched list is still allowed to be silent.
            XCTAssertNil(KilnLibraryCopy.coverageLine(.complete, searching: false,
                                                      destination: destination))
            // Silence about REACH is allowed only when the brain was actually reached.
            XCTAssertNil(KilnLibraryCopy.reachLine(.reachable, destination: destination))
            for reach in [MacReach.noComputer, .unreachable("x")] {
                XCTAssertNotNil(KilnLibraryCopy.reachLine(reach, destination: destination),
                                "the \(destination.rawValue) tier drew a partial list in silence")
            }
        }
    }

    /// AND THE TWO NON-PHONE TIERS ARE NOT THE SAME TIER — wherever a sentence names the
    /// second place, the Vault's and the computer's differ.
    func testTheVaultNeverInheritsTheComputersSentence() {
        let computer = brainWords(.computer)
        let vault = brainWords(.vault)
        XCTAssertEqual(computer.count, vault.count)
        var named = 0
        for (c, v) in zip(computer, vault)
        where WaitingCopySweep.mentions("Mac", in: c)
            || WaitingCopySweep.mentions("computer", in: c) {
            named += 1
            XCTAssertNotEqual(c, v, "the Vault inherits the computer's sentence: \"\(c)\"")
        }
        XCTAssertGreaterThan(named, 5,
                             "VACUOUS: only \(named) sentences name the second place")
    }

    /// No brain sentence leaks a wire token to a person.
    func testNoBrainSentenceLeaksAMachinesWordForSomething() {
        for destination in CaptureDestination.allCases {
            for text in brainWords(destination) {
                XCTAssertFalse(text.contains("_"), "a wire token reached a person: \"\(text)\"")
            }
        }
    }
}
