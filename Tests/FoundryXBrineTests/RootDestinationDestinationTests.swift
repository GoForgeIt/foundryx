import XCTest
@testable import FoundryXKit

/// THE TIER→WORDS BINDING, EXECUTED.
///
/// `RootDestination.captureDestination` shipped correct and pinned (SyncBarPresenterTests)
/// and with NO PRODUCTION CALLER — a tested table nothing consulted.
/// `App/RootView.swift` named the place three times instead — `.computer`
/// in the computer arm, `.vault` in the cell arm, `.phone` in the phone arm — and `swift
/// test` cannot compile `App/`, so flipping any one of those literals compiled, shipped,
/// and passed every gate in this repository while a Vault owner read a Mac's words on
/// every wait, every sync line and every journey step under those tabs.
///
/// The literals are gone; the arms take one derived value. This suite is what now stands
/// between a tier and another tier's words, so it is held over the WHOLE population of
/// `RootDestination` rather than over the three cases somebody remembered.
final class RootDestinationDestinationTests: XCTestCase {

    /// Every brain that is running the app names a place, and no two name the same one.
    /// The crush this whole wave exists for is `.cellBrain` and `.computerBrain` agreeing.
    func testEveryRunningBrainNamesItsOwnPlaceAndNoTwoAgree() {
        let running: [RootDestination] = [.computerBrain, .cellBrain, .phoneBrain]
        let named = running.compactMap(\.captureDestination)
        XCTAssertEqual(named.count, running.count,
                       "a running brain has no place to name: \(running)")
        XCTAssertEqual(Set(named).count, named.count,
                       "two brains name the same place — the .cellBrain-falls-into-"
                       + ".computerBrain crush: \(named)")
        XCTAssertEqual(RootDestination.computerBrain.captureDestination, .computer)
        XCTAssertEqual(RootDestination.cellBrain.captureDestination, .vault)
        XCTAssertEqual(RootDestination.phoneBrain.captureDestination, .phone)
    }

    /// EVERY destination `CaptureDestination` can hold is reachable from a brain. If a
    /// fourth tier arrives and nothing routes to it, its words are unreachable and the
    /// tier silently inherits somebody else's — which is how this started.
    func testEveryCaptureDestinationIsReachableFromSomeBrain() {
        let reachable = Set([RootDestination.computerBrain, .cellBrain, .phoneBrain,
                             .signInGate].compactMap(\.captureDestination))
        for destination in CaptureDestination.allCases {
            XCTAssertTrue(reachable.contains(destination),
                          "no brain resolves to \(destination.rawValue) — its words can "
                          + "never render, and its owner reads another tier's")
        }
    }

    /// The sign-in gate has nowhere to save anything and must not be given a default that
    /// reads like a place.
    func testTheSignInGateNamesNoPlace() {
        XCTAssertNil(RootDestination.signInGate.captureDestination)
    }

    /// THE ON-SCREEN MAPPING IS THE SAME MAPPING. `captureDestinationOnScreen` is what
    /// `RootView` actually calls; it must agree with `captureDestination` everywhere the
    /// latter has an answer, or the App and the tests would be reading two different
    /// tables — the exact split this fix removes.
    func testTheOnScreenMappingAgreesWithTheOptionalOneEverywhere() {
        for dest in [RootDestination.computerBrain, .cellBrain, .phoneBrain, .signInGate] {
            if let named = dest.captureDestination {
                XCTAssertEqual(dest.captureDestinationOnScreen, named,
                               "\(dest) renders \(dest.captureDestinationOnScreen) but "
                               + "resolves to \(named)")
            } else {
                // The only tier that names no second place at all — never a Mac, never a
                // Vault, for a user who has not signed in.
                XCTAssertEqual(dest.captureDestinationOnScreen, .phone)
            }
        }
    }

    /// AND THE WHOLE CHAIN. The brain a user PICKS, routed through the gate the app
    /// actually runs, must name the place that choice saves to — so a correct mapping
    /// wired to the wrong gate arm still cannot put a computer in front of a cell owner.
    func testAResolvedChoiceNamesThePlaceThatChoiceSavesTo() {
        for choice in BrainChoice.allCases {
            let resolved = RootGate.destination(signedIn: true, splashElapsed: true,
                                                brain: choice, hostResolved: true,
                                                letStraightIn: true, cellPaired: true)
            XCTAssertEqual(resolved.captureDestinationOnScreen, choice.captureDestination,
                           "picking \(choice) resolves to \(resolved), which names "
                           + "\(resolved.captureDestinationOnScreen) — but that choice "
                           + "saves to \(choice.captureDestination)")
        }
    }

    /// A CHOSEN-BUT-UNRESOLVED BRAIN DEGRADES, AND THE WORDS DEGRADE WITH IT. A picked
    /// computer with no reachable host, and a picked cloud with no paired cell, both run
    /// on the phone — and must say so, not name a place the session never reached.
    func testAnUnresolvedChoiceNamesThePhoneAndNotThePlaceItFailedToReach() {
        let noHost = RootGate.destination(signedIn: true, splashElapsed: true,
                                          brain: .myComputer, hostResolved: false,
                                          letStraightIn: true, cellPaired: false)
        XCTAssertEqual(noHost.captureDestinationOnScreen, .phone)
        let noCell = RootGate.destination(signedIn: true, splashElapsed: true,
                                          brain: .foundryCloud, hostResolved: false,
                                          letStraightIn: true, cellPaired: false)
        XCTAssertEqual(noCell.captureDestinationOnScreen, .phone)
    }
}
