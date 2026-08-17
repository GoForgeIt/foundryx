// THE RULE AND THE LEASE, HELD WHERE `swift test` CAN REACH THEM.
//
// The defect these answer shipped as ONE comparison inside a SwiftUI body — `if phase !=
// .active { check.cancel() }` — and a SwiftUI body is the one place in this repository that
// nothing can execute. That is why the rule is a kit enum now: not for tidiness, but because
// a decision that cannot be run is a decision that cannot be wrong out loud.

import XCTest
@testable import FoundryXKit

@MainActor
final class PocketBackgroundErrandTests: XCTestCase {

    // MARK: - The rule

    /// THE WHOLE DEFECT, AS ONE ASSERTION. `.inactive` is a screenshot, Control Center, the
    /// app switcher, a notification banner, an incoming call. It is never the owner leaving.
    func testAMomentaryInterruptionNeverStopsAnErrand() {
        XCTAssertEqual(
            PocketErrandScenePhasePolicy.decide(phase: .inactive, isHoldingBackgroundTime: true),
            .carryOn)
        // AND WITHOUT AN ASSERTION EITHER. A screenshot does not suspend the process, so the
        // errand is fine whether or not anything is protecting it — folding this into "no
        // time held ⇒ stop" would reintroduce the bug through the other door.
        XCTAssertEqual(
            PocketErrandScenePhasePolicy.decide(phase: .inactive, isHoldingBackgroundTime: false),
            .carryOn)
    }

    func testBeingInFrontOfSomebodyNeverStopsAnErrand() {
        XCTAssertEqual(
            PocketErrandScenePhasePolicy.decide(phase: .active, isHoldingBackgroundTime: false),
            .carryOn)
        XCTAssertEqual(
            PocketErrandScenePhasePolicy.decide(phase: .active, isHoldingBackgroundTime: true),
            .carryOn)
    }

    /// THE POINT OF THE ASSERTION, STATED AS A DIFFERENCE. The same transition means two
    /// opposite things depending on whether the process has been given time to finish in.
    func testTheSameDepartureMeansCarryOnOrStopDependingOnWhoIsHoldingTime() {
        XCTAssertEqual(
            PocketErrandScenePhasePolicy.decide(phase: .background, isHoldingBackgroundTime: true),
            .carryOn,
            "an errand holding background time is exactly the errand that may keep running")
        XCTAssertEqual(
            PocketErrandScenePhasePolicy.decide(phase: .background, isHoldingBackgroundTime: false),
            .stopTheErrand,
            """
            an unprotected process is suspended within seconds of going to the background, so \
            carrying on would be a promise the runtime does not keep — the transfer would die \
            anyway, with the page still claiming it was working.
            """)
    }

    // MARK: - The lease

    func testTakingTimeOnceAndGivingItBackLeavesNothingHeld() {
        let system = RecordingBackgroundTime()
        let lease = PocketBackgroundLease(time: system.seam)
        XCTAssertFalse(lease.isHeld)

        XCTAssertTrue(lease.begin(subject: PocketErrandCommand.bringOverSubject))
        XCTAssertTrue(lease.isHeld)
        XCTAssertEqual(lease.subject, PocketErrandCommand.bringOverSubject)
        XCTAssertEqual(system.outstanding.count, 1)
        XCTAssertEqual(system.namesAsked, [PocketErrandCommand.bringOverSubject])

        lease.end()
        XCTAssertFalse(lease.isHeld)
        XCTAssertEqual(lease.taken, 1)
        XCTAssertEqual(lease.released, 1)
        XCTAssertEqual(system.outstanding, [], "the system is still holding the process up")
    }

    /// FIVE ERRAND ENTRY POINTS FUNNEL THROUGH ONE `beginErrand`, and a re-entrant tap must
    /// not buy a second assertion nobody will ever release.
    func testAskingTwiceTakesTimeOnce() {
        let system = RecordingBackgroundTime()
        let lease = PocketBackgroundLease(time: system.seam)
        XCTAssertTrue(lease.begin(subject: "shelf"))
        XCTAssertTrue(lease.begin(subject: "bring-over"))
        XCTAssertEqual(lease.taken, 1)
        XCTAssertEqual(system.namesAsked, ["shelf"])
        lease.end()
        XCTAssertEqual(system.outstanding, [])
    }

    /// EVERY EXIT PATH ENDS AT THE SAME `end()`, and the paths overlap: an errand that
    /// finished AND an owner who left the page both arrive here for one departure.
    func testGivingBackTwiceIsSilentAndDoesNotDoubleRelease() {
        let system = RecordingBackgroundTime()
        let lease = PocketBackgroundLease(time: system.seam)
        lease.begin(subject: "bring-over")
        lease.end()
        lease.end()
        XCTAssertEqual(lease.released, 1, "one assertion was released twice")
        XCTAssertEqual(system.released.count, 1)
    }

    func testGivingBackWhenNothingWasEverTakenIsSilent() {
        let system = RecordingBackgroundTime()
        let lease = PocketBackgroundLease(time: system.seam)
        lease.end()
        XCTAssertEqual(lease.released, 0)
        XCTAssertEqual(system.released, [])
    }

    /// A REFUSAL IS AN ANSWER, NOT AN ERROR. An app already past its background budget gets
    /// nothing, and the honest consequence is an errand that stops on the next departure
    /// rather than one that is suspended mid-transfer and lies about it.
    func testASystemThatWillNotGiveTimeSaysSoRatherThanPretending() {
        let lease = PocketBackgroundLease(time: .refused)
        XCTAssertFalse(lease.begin(subject: "bring-over"))
        XCTAssertFalse(lease.isHeld)
        XCTAssertEqual(lease.refusals, 1)
        XCTAssertEqual(lease.taken, 0)
        XCTAssertEqual(
            PocketErrandScenePhasePolicy.decide(phase: .background,
                                                isHoldingBackgroundTime: lease.isHeld),
            .stopTheErrand)
    }

    /// THE SYSTEM TAKING THE TIME BACK. An assertion not ended from its own expiry handler
    /// gets the app KILLED, so the lease must release BEFORE it tells its owner — and it must
    /// tell its owner, or the errand carries on into a suspension nobody reported.
    func testWhenTheSystemTakesTheTimeBackTheLeaseReleasesItAndSaysSo() {
        let system = RecordingBackgroundTime()
        let lease = PocketBackgroundLease(time: system.seam)
        var toldWhileStillHolding: Bool?
        lease.onExpiry = { toldWhileStillHolding = lease.isHeld }

        lease.begin(subject: "bring-over")
        system.expireEverything()

        XCTAssertEqual(toldWhileStillHolding, false,
                       "the owner was told before the assertion was handed back")
        XCTAssertFalse(lease.isHeld)
        XCTAssertEqual(lease.released, 1)
        XCTAssertEqual(system.outstanding, [])
    }

    /// THE LAST RESORT. If the object holding the lease goes away mid-errand, nothing else is
    /// ever going to end the assertion — and an assertion that outlives its owner is precisely
    /// the one that gets the process terminated by the watchdog.
    func testALeaseThatIsReleasedMidErrandStillGivesTheTimeBack() {
        let system = RecordingBackgroundTime()
        do {
            let lease = PocketBackgroundLease(time: system.seam)
            lease.begin(subject: "bring-over")
            XCTAssertEqual(system.outstanding.count, 1)
            _ = lease
        }
        XCTAssertEqual(system.outstanding, [],
                       "the model was released mid-transfer and the process is still held up")
    }

    /// EVERY PHASE IS DECIDED. A `switch` with no `default` is what makes this true today; the
    /// test is what notices if somebody adds a case and a `default` on the same afternoon.
    func testEveryPhaseHasAnAnswer() {
        for phase in PocketErrandScenePhase.allCases {
            for holding in [true, false] {
                let decision = PocketErrandScenePhasePolicy.decide(
                    phase: phase, isHoldingBackgroundTime: holding)
                XCTAssertTrue(decision == .carryOn || decision == .stopTheErrand)
            }
        }
        XCTAssertEqual(PocketErrandScenePhase.allCases.count, 3)
    }
}

// MARK: - A system whose answers a test owns

/// `UIApplication` is the one thing a hermetic run cannot have, so it is the one thing this
/// stands in for. It records rather than asserts: every claim above is about the COUNTS, and a
/// double-take or a missed release is only visible as a number.
@MainActor
private final class RecordingBackgroundTime {
    private(set) var namesAsked: [String] = []
    private(set) var released: [PocketBackgroundTimeToken] = []
    private var expiries: [PocketBackgroundTimeToken: @MainActor @Sendable () -> Void] = [:]
    private var next = 1

    /// The assertions the system still believes are held.
    private(set) var outstanding: [PocketBackgroundTimeToken] = []

    var seam: PocketBackgroundTime {
        PocketBackgroundTime(
            begin: { [weak self] named, onExpiry in
                guard let self else { return nil }
                let token = PocketBackgroundTimeToken(rawValue: self.next)
                self.next += 1
                self.namesAsked.append(named)
                self.outstanding.append(token)
                self.expiries[token] = onExpiry
                return token
            },
            end: { [weak self] token in
                // The lease's `deinit` can reach this from any thread, exactly as the shipped
                // seam can. Hop the way the shipped one does so the recording stays coherent.
                let record = { @Sendable in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.released.append(token)
                        self.outstanding.removeAll { $0 == token }
                        self.expiries[token] = nil
                    }
                }
                if Thread.isMainThread { record() } else { DispatchQueue.main.sync(execute: record) }
            })
    }

    /// What iOS does when the budget runs out.
    func expireEverything() {
        for handler in expiries.values { handler() }
    }
}
