// THE COMMAND PATH, AS A THING THE LOG CAN TELL APART FROM AN OBSERVATION.
//
// `DoorLog` shipped as a levelled text log and nothing else: `info` / `warn` / `error`, a ring
// buffer, and a relay flush. Everything in it is a sentence, so "did the app DO this" and "did
// the app NOTICE this" are the same kind of line and neither can be found without grepping
// English. That is the whole reason the recorder surface has no CQRS: there was no command
// stream to put a command in.
//
// This holds the split. A command is recorded in its own ordered stream AND mirrored into the
// levelled entries, because the entries are what reach the relay — a split that stopped
// shipping the commands would be a diagnostic regression sold as an improvement.

import XCTest
@testable import FoundryXKit

final class DoorLogCommandPathTests: XCTestCase {

    /// THE ONE THAT MATTERS. Before the split there is no stream to look in at all.
    func testACommandIsRecordedInItsOwnStream() {
        let log = DoorLog()
        log.command(PocketErrandCommand.start, subject: "shelf")
        XCTAssertEqual(log.commands.count, 1)
        XCTAssertEqual(log.commands.first?.name, "errand.start")
        XCTAssertEqual(log.commands.first?.subject, "shelf")
        XCTAssertNil(log.commands.first?.outcome)
    }

    /// ORDER IS THE POINT. A command stream that does not preserve the sequence cannot say
    /// whether the errand stopped before or after custody took the file.
    func testCommandsKeepTheOrderTheyWereIssuedIn() {
        let log = DoorLog()
        log.command(PocketErrandCommand.start, subject: "bring-over")
        log.command(PocketErrandCommand.custodyCommit, subject: "2026-03-28/20260328001919")
        log.command(PocketErrandCommand.stop, subject: "bring-over",
                    outcome: DoorLog.succeeded)
        XCTAssertEqual(log.commands.map(\.name),
                       ["errand.start", "custody.commit", "errand.stop"])
    }

    /// THE SPLIT MUST NOT STARVE THE QUERY SIDE. `entries` is what `flush()` ships to the
    /// relay; a command that only lived in the new stream would be a line the on-call person
    /// used to be able to read and now cannot.
    func testEveryCommandAlsoReachesTheLevelledEntriesTheRelayShips() {
        let log = DoorLog()
        log.command(PocketErrandCommand.start, subject: "shelf")
        XCTAssertEqual(log.entries.count, 1,
                       "a command that is not also an entry never reaches /diag/log")
        XCTAssertEqual(log.entries.first?.text, "cmd errand.start subject=shelf")
    }

    /// ONE PINNED WIRE FORM, because a server-side grep depends on it and two producers must
    /// not name the same thing differently — the discipline `FoundryXDiagContext.wireHeader`
    /// is already held to.
    func testTheWireFormOfACommandIsPinned() {
        let log = DoorLog()
        log.command(PocketErrandCommand.stop, subject: "bring-over",
                    outcome: DoorLog.succeeded)
        XCTAssertEqual(log.entries.first?.text,
                       "cmd errand.stop subject=bring-over outcome=ok")
    }

    /// A command that ENDED WELL stays at `info`; the level is not decided by adjective.
    func testASucceededCommandStaysAtInfo() {
        let log = DoorLog()
        log.command(PocketErrandCommand.stop, subject: "shelf", outcome: DoorLog.succeeded)
        XCTAssertEqual(log.entries.first?.level, .info)
    }

    /// A command that FAILED is still a command, and it is the one worth finding.
    func testAFailedCommandIsRecordedWithItsOutcome() {
        let log = DoorLog()
        log.command(PocketErrandCommand.stop, subject: "shelf", outcome: "unreachable")
        XCTAssertEqual(log.commands.first?.outcome, "unreachable")
        XCTAssertEqual(log.entries.first?.level, .warn,
                       "an errand that ended badly must be findable at a level above info")
    }

    /// Finding the three the recorder surface issues, without grepping English.
    func testCommandsCanBeFoundByName() {
        let log = DoorLog()
        log.command(PocketErrandCommand.start, subject: "a")
        log.command(PocketErrandCommand.start, subject: "b")
        log.command(PocketErrandCommand.stop, subject: "a")
        XCTAssertEqual(log.commands(named: PocketErrandCommand.start).map(\.subject), ["a", "b"])
        XCTAssertEqual(log.commands(named: PocketErrandCommand.stop).count, 1)
        XCTAssertTrue(log.commands(named: PocketErrandCommand.custodyCommit).isEmpty)
    }

    /// BOUNDED, like the entries. An unbounded command stream is a leak on a log whose whole
    /// design is a ring buffer.
    func testTheCommandStreamIsBoundedByTheSameCap() {
        let log = DoorLog(cap: 4)
        for i in 0..<10 { log.command(PocketErrandCommand.start, subject: "\(i)") }
        XCTAssertEqual(log.commands.count, 4)
        XCTAssertEqual(log.commands.map(\.subject), ["6", "7", "8", "9"],
                       "the ring must drop the OLDEST, not the newest")
    }

    /// THE CLOSED VOCABULARY the recorder surface issues, pinned here so the app and the
    /// scenarios cannot drift to two spellings of the same command.
    /// FOUR SINCE STEP 6. `recorder.removal` joined it when the recorder page gained the one
    /// command that takes something AWAY — and it is a distinct word from `custody.commit` for
    /// the same reason that one is distinct from `errand.stop`: "a recording arrived on this
    /// phone" and "a recording left the recorder" are two facts, and the second is the only one
    /// that answers "where did my recording go".
    func testTheErrandVocabularyIsExactlyFour() {
        XCTAssertEqual(PocketErrandCommand.every,
                       ["errand.start", "errand.stop", "custody.commit", "recorder.removal"])
        // AND THE SUBJECTS ARE THREE DISTINCT ERRANDS. Two spellings of one errand is a log
        // whose command stream cannot be read back.
        XCTAssertEqual(Set([PocketErrandCommand.shelfSubject,
                            PocketErrandCommand.bringOverSubject,
                            PocketErrandCommand.removalSubject]).count, 3)
    }

    /// AN EXISTENCE ASSERTION OVER THE SAME POPULATION as the prohibitions above: a log that
    /// records nothing satisfies every "must not" in this file, so this pins that the plain
    /// levelled path still works and is still distinct from a command.
    func testAnObservationIsNotACommand() {
        let log = DoorLog()
        log.info("recording device: unreachable — neverAnswered")
        XCTAssertEqual(log.entries.count, 1)
        XCTAssertTrue(log.commands.isEmpty,
                      "an observation counted as a command makes the split meaningless")
    }
}
