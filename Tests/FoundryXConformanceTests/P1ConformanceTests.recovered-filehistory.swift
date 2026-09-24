import XCTest
import FoundryXKit

/// The relay + the one P1 run the three A6 assertions all read.
///
/// Shaped like `ConformanceWorld` in `P3ConformanceTests.swift`: one `@unchecked
/// Sendable` holder rather than mutable statics, because bring-up is a process spawn
/// and three assertions must read ONE run — asserting three times over three separate
/// runs would let the count assertion pass on one run and the behavioural assertion on
/// another.
final class P1World: @unchecked Sendable {
    static let shared = P1World()

    private let lock = NSLock()
    private var started = false
    private var relay: TunnelRelayFixture?
    private(set) var outcome: PredicateOutcome?
    private(set) var bringUpFailure: String?

    func ensureRun() {
        lock.lock()
        defer { lock.unlock() }
        if started { return }
        started = true

        let fixture = TunnelRelayFixture()
        do {
            try fixture.start()
        } catch {
            // A REFUSAL, not a skip: there is no `XCTSkip` anywhere in this target and
            // `ConformanceSkipCensus` asserts that as a count.
            bringUpFailure = "\(error)"
            return
        }
        relay = fixture
        let sem = DispatchSemaphore(value: 0)
        let url = fixture.wsURL
        Task {
            let o = await P1GatewayIdentityPredicate.run(relayURL: url)
            self.setOutcome(o)
            sem.signal()
        }
        if sem.wait(timeout: .now() + 180) == .timedOut {
            bringUpFailure = "P1 did not finish within 180s"
        }
        // "recorded with their output" (A9). Emitted on every run, pass or fail — a
        // predicate whose transcript is only visible when it fails cannot be checked
        // for having actually driven anything.
        if let o = outcome {
            print("=== PREDICATE \(o.name) [\(o.status.rawValue)] casesExecuted=\(o.casesExecuted) ===")
            print(o.output)
            print("=== END \(o.name) ===")
        }
    }

    private func setOutcome(_ o: PredicateOutcome) { outcome = o }

    func teardown() {
        lock.lock()
        defer { lock.unlock() }
        if let r = relay {
            let report = r.teardown()
            if !report.stillRunning.isEmpty {
                // Reported, never pattern-killed. These are the pids this harness started.
                print("P1 teardown: pids still running after SIGTERM: \(report.stillRunning)")
            }
        }
        relay = nil
    }
}

/// T25 **A6** — *"P1 executes behaviourally and both cases run. Absent-identity and
/// wrong-identity gateway responses are both driven against the real relay; **two cases
/// executed** is asserted; CLOSED requires refusal in both."*
///
/// The falsifying mutations the spec names, and which assertion each one reddens:
///
/// - *"Make the predicate assert only that the client logged `pinned=false`; the
///   behavioural assertion goes red because the client still completed the channel"*
///   -> `testP1IsOpenBecauseTheClientProceeded`. The client DOES log `pinned=false`
///   in the absent-identity case (`HostResolver.swift:96`), so a log-reading predicate
///   reports the fix CLOSED. This test pins the observable to proceeding-or-not.
/// - *"drop the wrong-identity case; the two-case count goes red"*
///   -> `testP1DrivesExactlyTwoCases`.
final class P1ConformanceTests: XCTestCase {

    override class func tearDown() {
        P1World.shared.teardown()
        super.tearDown()
    }

    private func requireOutcome() throws -> PredicateOutcome {
        let world = P1World.shared
        world.ensureRun()
        if let why = world.bringUpFailure {
            XCTFail("the blind tunnel relay did not come up, so P1 was never driven: \(why)")
            throw HardRefusal.refused
        }
        guard let o = world.outcome else {
            XCTFail("P1 produced no outcome — the predicate did not finish")
            throw HardRefusal.refused
        }
        // A REFUSED predicate must not be read as a status in either direction.
        if o.status == .refused {
            XCTFail("P1 REFUSED rather than producing a status; no coverage is claimed from a probe that could not run:\n\(o.output)")
            throw HardRefusal.refused
        }
        return o
    }

    /// The count assertion. Dropping the wrong-identity case reddens here.
    func testP1DrivesExactlyTwoCases() throws {
        let o = try requireOutcome()
        XCTAssertEqual(o.casesExecuted, 2,
            """
            P1 must drive BOTH gateway responses — absent identity and wrong identity. \
            \(o.casesExecuted) case(s) executed. One case is not a predicate: the \
            wrong-identity case alone reports a refusal and hides the fail-open entirely.
            \(o.output)
            """)
    }

    /// The behavioural assertion, INVERTED once the defect was fixed.
    ///
    /// This test asserted `.open` for as long as the fail-open existed: the client
    /// completed a channel when the gateway omitted `machine_id`, and asserting the
    /// hole was the only honest thing a predicate could say. That is no longer true —
    /// `RelayConfig.expectedDoorStatic` is non-optional, both consumers compare
    /// unconditionally, and `HostResolver` throws `hostCannotBePinned` rather than
    /// handing out a config it cannot pin. So the assertion is flipped to the state the
    /// code is now in.
    ///
    /// The bar did NOT move. `.closed` is still only reachable by the client refusing
    /// in BOTH cases, still observed as proceeding-or-not rather than read from a log,
    /// and still worthless without the positive control — which is why the completion
    /// assertion below now names the POSITIVE CONTROL specifically. Restoring either
    /// `if let` reddens this test again, which is the property that makes flipping it
    /// safe rather than a way of buying green.
    func testP1IsClosedBecauseTheClientRefusedInBothCases() throws {
        let o = try requireOutcome()
        XCTAssertEqual(o.status, .closed,
            """
            P1 is CLOSED only if the client REFUSES in both cases — an absent \
            `machine_id` and a present-but-wrong one. A status of OPEN here means the \
            fail-open is back: check that `RelayConfig.expectedDoorStatic` is still \
            non-optional and that neither consumer has regained an `if let` \
            (`RelayTransport.swift`, `DoorConnection.swift`).
            \(o.output)
            """)
        XCTAssertTrue(o.output.contains("positive control (correct machine_id): the client completed the channel"),
            """
            The CLOSED verdict is meaningless without a rig that can reach transport \
            mode: a broken door or a mis-parsed relay URL would make every case \
            "refuse" and report the fix as landed because the harness stopped working. \
            The positive control must be OBSERVED completing.
            \(o.output)
            """)
        XCTAssertTrue(o.output.contains("case absent-identity: the client REFUSED"),
            """
            The absent-identity case must be recorded as a REFUSAL by the client, not \
            merely absent from the transcript. A case that silently disappears is how a \
            predicate reports CLOSED having tested one thing.
            \(o.output)
            """)
    }

    /// The negative half of the same observable: a pin that is present and wrong is
    /// still enforced. Without this, a client that refused unconditionally would look
    /// identical to one that pins correctly.
    func testTheWrongIdentityCaseIsRefusedOnDoorIdentity() throws {
        let o = try requireOutcome()
        XCTAssertTrue(o.output.contains("case wrong-identity: the client REFUSED on door identity"),
            """
            The wrong-identity case must be refused BY THE PIN — `RelayError.doorIdentityMismatch` \
            — and not by a transport error that happens to look like a refusal.
            \(o.output)
            """)
    }
}

/// Thrown to end a test that has already reported its failure. This target contains no
/// `XCTSkip` (asserted as a count by `ConformanceSkipCensus`); this type exists so a
/// refusal can stop a test WITHOUT being a skip, and it is never caught to make one.
enum HardRefusal: Error { case refused }
