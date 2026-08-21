import XCTest
@testable import FoundryXKit

/// AC15 as Nick ruled it on 2026-08-21: clearing ships BOTH automatically and manually, the
/// choice is a per-recorder setting, and a full recorder says so and offers both ways out.
///
/// The pairing that matters most here is the one between ARMING and the SAFETY PREDICATE.
/// Arming a recorder removes the requirement that a person tap each recording. It does NOT
/// lower the bar for removal. Every scenario below that proves the automatic path CAN take
/// something is paired with one proving it CANNOT take something that is only on the recorder —
/// because a permission test with no matching refusal test is satisfied by deleting everything.
final class PocketRecorderRoomAndAutoClearTests: XCTestCase {

    private func request(_ stamp: String) -> PocketRecordingRequest {
        PocketRecordingRequest(date: "2026-08-21", timestamp: stamp)
    }

    private func presence(safeElsewhere: Bool) -> PocketRecordingPresence {
        PocketRecordingPresence(
            onRecorder: PocketPlaceReading(answer: .yes, observedAt: Date()),
            onThisPhone: PocketPlaceReading(answer: .yes, observedAt: Date()),
            safeElsewhere: PocketPlaceReading(answer: safeElsewhere ? .yes : .no, observedAt: Date()))
    }

    private let armed = PocketAutoClear(armedAt: Date(timeIntervalSince1970: 1_000_000))

    // MARK: - The setting decides, and OFF is the default

    func testAnUnarmedRecorderClearsNothingEvenWhenEveryRecordingIsSafeElsewhere() {
        let requests = [request("20260821T090000"), request("20260821T100000")]
        let decisions = PocketAutomaticDrainPolicy.clearDecisions(
            broughtOverAutomatically: requests,
            autoClear: .off,
            presence: { _ in self.presence(safeElsewhere: true) })

        XCTAssertEqual(decisions.count, requests.count,
                       "every recording must be accounted for, not silently dropped from the list")
        for decision in decisions {
            guard case .keep(_, let why) = decision else {
                return XCTFail("an unarmed recorder cleared something: \(decision)")
            }
            XCTAssertEqual(why, .recorderIsNotArmed)
        }
    }

    /// THE PAIRED PERMISSION. Without this, the refusal test above is satisfied by a policy
    /// that never clears anything at all — which is exactly what shipped before this ruling.
    func testAnArmedRecorderClearsARecordingThatIsProvablySomewhereElse() {
        let one = request("20260821T090000")
        let decisions = PocketAutomaticDrainPolicy.clearDecisions(
            broughtOverAutomatically: [one],
            autoClear: armed,
            presence: { _ in self.presence(safeElsewhere: true) })

        XCTAssertEqual(decisions, [.clear(one)])
    }

    /// THE SAFETY PREDICATE, UNCHANGED BY ARMING. This is the scenario that makes arming safe.
    func testAnArmedRecorderWillNotClearARecordingThatIsOnlyOnTheRecorder() {
        let one = request("20260821T090000")
        let decisions = PocketAutomaticDrainPolicy.clearDecisions(
            broughtOverAutomatically: [one],
            autoClear: armed,
            presence: { _ in self.presence(safeElsewhere: false) })

        XCTAssertEqual(decisions, [.keep(one, because: .notProvenToBeAnywhereElse)])
    }

    /// `unknown ⇒ keep`. A place nobody asked about is not a copy anybody holds.
    func testAnUnaskedPlaceIsNotACopyAndTheRecordingStays() {
        let one = request("20260821T090000")
        let unknown = PocketRecordingPresence(
            onRecorder: PocketPlaceReading(answer: .yes, observedAt: Date()),
            onThisPhone: PocketPlaceReading(answer: .yes, observedAt: Date()),
            safeElsewhere: PocketPlaceReading(answer: .unknown, observedAt: nil))

        XCTAssertEqual(
            PocketAutomaticDrainPolicy.clearDecisions(
                broughtOverAutomatically: [one], autoClear: armed, presence: { _ in unknown }),
            [.keep(one, because: .notProvenToBeAnywhereElse)])
    }

    func testTheCandidateListAgreesWithTheDecisions() {
        let safe = request("20260821T090000")
        let unsafe = request("20260821T100000")
        let candidates = PocketAutomaticDrainPolicy.clearCandidates(
            broughtOverAutomatically: [safe, unsafe],
            autoClear: armed,
            presence: { $0 == safe ? self.presence(safeElsewhere: true)
                                   : self.presence(safeElsewhere: false) })

        XCTAssertEqual(candidates, [safe],
                       "the convenience read must not disagree with clearDecisions")
    }

    // MARK: - Room

    /// **THE BOUNDARY THIS RULE EXISTS FOR.** Nick's recorder reported 58,767 of 58,992 — 99.6%
    /// — and took another recording that same day. Rounding would call it full and tell him he
    /// could not record when he could.
    func testARecorderAtNinetyNinePointSixPercentIsNotFull() {
        let room = RecordingDeviceReadingPresentation.room(used: 58_767, total: 58_992)
        XCTAssertFalse(room.isFull, "99.6% was reported as full; that recorder still records")
        XCTAssertEqual(room, .roomRemaining(percentFull: 99))
    }

    func testARecorderReportingAsMuchUsedAsCapacityHasNoRoomLeft() {
        XCTAssertTrue(RecordingDeviceReadingPresentation.room(used: 58_992, total: 58_992).isFull)
        XCTAssertTrue(RecordingDeviceReadingPresentation.room(used: 60_000, total: 58_992).isFull,
                      "a recorder reporting more used than it has capacity is full, not over 100%")
    }

    /// A recorder nobody asked is NEITHER full NOR empty.
    func testAnUnaskedRecorderIsNeitherFullNorAnswered() {
        let room = RecordingDeviceReadingPresentation.room(used: 0, total: 0)
        XCTAssertEqual(room, .notAsked)
        XCTAssertFalse(room.isFull, "an unasked recorder must never read as full")
        XCTAssertFalse(room.wasAnswered)
    }

    /// The rendered sentence and the decision come from one rule, so they cannot drift.
    ///
    /// **The first draft of this test compared `line` to itself** on the not-full branch —
    /// `expected = line` — which is a check that cannot fail, in a test written to catch checks
    /// that cannot fail. Both branches now derive the expected string from the ROOM VALUE, so
    /// the two representations are genuinely compared.
    func testTheRenderedFullnessAgreesWithTheDecision() {
        var examined = 0
        for (used, total) in [(0, 100), (40, 100), (58_767, 58_992),
                              (58_992, 58_992), (60_000, 58_992), (0, 0)] {
            let room = RecordingDeviceReadingPresentation.room(used: used, total: total)
            let line = RecordingDeviceReadingPresentation.storageFullness(used: used, total: total)
            switch room {
            case .notAsked:
                XCTAssertNil(line, "an unasked recorder rendered a fullness sentence")
            case .roomRemaining(let percent):
                XCTAssertEqual(line, "\(percent)% full",
                               "sentence and value disagree at used=\(used) total=\(total)")
            case .noRoomLeft:
                XCTAssertEqual(line, "\(RecordingDeviceReadingPresentation.fullPercent)% full",
                               "a full recorder rendered \(line ?? "nil")")
            }
            examined += 1
        }
        XCTAssertEqual(examined, 6, "the loop skipped cases, so it proved less than it claims")
    }

    // MARK: - The two ways out

    func testAFullUnarmedRecorderOffersBothRoutes() {
        let offers = PocketRecorderRoomPresentation.offers(room: .noRoomLeft, autoClear: .off)
        XCTAssertEqual(offers, [PocketRecorderRoomPresentation.makeRoomAction,
                                PocketRecorderRoomPresentation.armAutoClearAction])
    }

    /// An offer that does nothing when taken is worse than no offer.
    func testAFullArmedRecorderIsNotOfferedArmingAgain() {
        let offers = PocketRecorderRoomPresentation.offers(room: .noRoomLeft, autoClear: armed)
        XCTAssertEqual(offers, [PocketRecorderRoomPresentation.makeRoomAction])
    }

    /// THE PAIRED SILENCE. A recorder with room, and one nobody asked, offer nothing — so the
    /// tests above cannot be satisfied by a surface that always shows both buttons.
    func testARecorderWithRoomOrNoAnswerOffersNothing() {
        XCTAssertEqual(
            PocketRecorderRoomPresentation.offers(room: .roomRemaining(percentFull: 40),
                                                  autoClear: .off), [])
        XCTAssertEqual(
            PocketRecorderRoomPresentation.offers(room: .notAsked, autoClear: .off), [],
            "an unchecked recorder must not tell somebody to clear space")
    }

    /// Every line is non-empty and distinct — copy that collides is copy a person cannot act on.
    func testEveryLineIsRealAndDistinct() {
        let lines = PocketRecorderRoomPresentation.everyLine
        XCTAssertFalse(lines.isEmpty, "the population is empty, so the checks below examine nothing")
        for line in lines { XCTAssertFalse(line.trimmingCharacters(in: .whitespaces).isEmpty) }
        XCTAssertEqual(Set(lines).count, lines.count, "two of these lines are identical")
    }
}
