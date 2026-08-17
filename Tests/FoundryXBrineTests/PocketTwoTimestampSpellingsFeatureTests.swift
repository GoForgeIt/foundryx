import XCTest
import BrineSwiftCore
@testable import FoundryXKit

/// `features/pocket-two-timestamp-spellings.feature`.
///
/// WHY THIS SUITE EXISTS. The 2026-08-16 bench read Nick's own recorder and found it naming its
/// recordings TWO ways on ONE device — bare `20260807142852` and PH-prefixed `PH260811175026`.
/// The reference document records that as a hazard for the WIRE, and the wire half was honoured:
/// `(date, timestamp)` is carried verbatim into the file key, the removal frame and the receipt.
///
/// The READ half was not. `PocketRecordingLabel` required fourteen DIGITS, so every PH-prefixed
/// recording fell through every guard at once: its row rendered the raw wire token instead of a
/// time, it sorted above every bare stamp on its day because `"P" > "9"` in ASCII, and — worst —
/// `reportedInstant` returned nil and its one production caller replaced that with `Date()`, so
/// the conversation was filed on the day it was COLLECTED. On the measured device that is nine
/// recordings of nineteen, silently misdated, with no warning of any kind, because
/// `recorderIsAhead` cannot fire when the reported instant IS the arrival instant.
///
/// WHAT DRIVES WHAT. Every step below calls the shipped functions — `PocketRecordingLabel`,
/// `PocketInventoryReader.read` over a faked radio, and `PocketCaptureImport.makeConversation`
/// writing a real capture directory to a real temporary root. Nothing here re-implements a
/// parser. The two stamps are the ones the bench actually measured, not invented shapes.
final class PocketTwoTimestampSpellingsFeatureTests: XCTestCase {

    func testPocketTwoTimestampSpellingsFeature() async throws {
        let world = TwoSpellingsWorld()
        let result = try await BrineFeatureRunner.run(
            "pocket-two-timestamp-spellings",
            registry: StepRegistry(TwoSpellingsSteps.make(world)))
        XCTAssertEqual(result.passed, 4)
    }

    /// THE TWO MEASURED STAMPS, IN ONE FIXTURE, ASSERTED TO PRODUCE TWO DIFFERENT INSTANTS.
    ///
    /// This is the assertion the reviewers asked for by name. It is a unit test rather than a
    /// scenario because it is about a parse, and because it must state the EXPECTED instants
    /// rather than merely that they differ — "two different answers" is also what a function
    /// returning `nil` and `Date()` produces.
    func testBothMeasuredStampsParseToTheInstantTheRecorderMeant() {
        // 2026-08-07 14:28:52 UTC
        let bare = PocketRecordingLabel.reportedInstant(date: "2026-08-07",
                                                        timestamp: "20260807142852")
        // 2026-08-11 17:50:26 UTC — the SAME six fields, with a two-digit year and a prefix.
        let prefixed = PocketRecordingLabel.reportedInstant(date: "2026-08-11",
                                                           timestamp: "PH260811175026")
        XCTAssertEqual(bare, Date(timeIntervalSince1970: 1_786_112_932),
                       "the bare spelling stopped parsing")
        XCTAssertEqual(prefixed, Date(timeIntervalSince1970: 1_786_470_626),
                       "the PH spelling does not parse to the instant it names. Nine of the "
                        + "nineteen recordings on the measured device carry this spelling")
        XCTAssertNotEqual(bare, prefixed)
    }

    /// THE FLOOR. A spelling nobody has seen still gets no invented instant — the property the
    /// PH fix must not trade away while it is teaching the parser a second shape.
    func testAThirdSpellingNobodyHasSeenStillRefusesToGuess() {
        for unknown in ["", "XX260811175026", "PH26081117502", "PH2608111750269",
                        "PHABCDEFGHIJKL", "2026-08-11"] {
            XCTAssertNil(PocketRecordingLabel.reportedInstant(date: "2026-08-11",
                                                             timestamp: unknown),
                         "\(unknown) was given an instant this build cannot justify")
        }
    }
}

private enum TwoSpellingsSteps {
    static func make(_ world: TwoSpellingsWorld) -> [StepDefinition] {
        let givens = [
            "a recorder holding one recording named each of the two ways it names them",
            "a recorder holding recordings made minutes apart on one day, named both ways",
            "a recording made on an earlier day and named the other way",
            "a recording whose time is spelled in a way this build has never seen",
        ]
        let whens = [
            "Solleva puts them in the order it shows them",
            "I bring it over",
        ]
        let thens = [
            "both recordings show the time of day they were made",
            "neither of them shows the recorder's raw name for the file instead of a time",
            "they are listed newest first by when they were actually made",
            "the way each one happens to be named does not change where it sits",
            "the conversation is dated the day it was made",
            "it is not dated the day I collected it",
            "Solleva says the recording's own time is not known",
            "the recording is still brought over",
        ]
        var steps = givens.map { phrase in
            defineStep(phrase) { context, _, _ in try await world.given(phrase); return context }
        }
        steps += whens.map { phrase in
            defineStep(phrase) { context, _, _ in try await world.when(phrase); return context }
        }
        steps += thens.map { phrase in
            defineCheck(phrase) { _, _, _ in try await world.then(phrase) }
        }
        return steps
    }
}

private actor TwoSpellingsWorld {

    /// THE TWO SPELLINGS, MEASURED. `PH260811175026` and `20260807142852` are transcribed from
    /// `foundry-hearth/reference/pocket-ble-protocol.md`, which recorded them off the hardware.
    static let prefixedDay = "2026-08-11"
    static let prefixedStamp = "PH260811175026"
    static let bareDay = "2026-08-07"
    static let bareStamp = "20260807142852"

    /// The moment the collector happens to be holding the phone. Deliberately a DIFFERENT day
    /// from both recordings, because "filed under the day it was collected" and "filed under the
    /// day it was made" are indistinguishable on a fixture where those are the same day.
    static let collectedAt = Date(timeIntervalSince1970: 1_786_752_000)  // 2026-08-15

    private var listed: [PocketRecording] = []
    private var imported: PocketImportedCapture?
    private var clock: PocketConversationTime?
    private var root: URL?

    deinit {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    // MARK: Given

    func given(_ phrase: String) async throws {
        switch phrase {
        case "a recorder holding one recording named each of the two ways it names them":
            listed = [
                PocketRecording(date: Self.prefixedDay, timestamp: Self.prefixedStamp,
                                sizeBytes: 2_764_000),
                PocketRecording(date: Self.bareDay, timestamp: Self.bareStamp,
                                sizeBytes: 14_400_000),
            ]

        case "a recorder holding recordings made minutes apart on one day, named both ways":
            // ONE DAY, THREE RECORDINGS, INTERLEAVED SPELLINGS. The PH one was made in the
            // MIDDLE, so a lexicographic sort on the raw token cannot accidentally be right:
            // "P" > "9" puts it first, and the correct answer puts it second.
            listed = [
                PocketRecording(date: "2026-08-11", timestamp: "20260811090000",
                                sizeBytes: 1_000),
                PocketRecording(date: "2026-08-11", timestamp: "PH260811175026",
                                sizeBytes: 2_000),
                PocketRecording(date: "2026-08-11", timestamp: "20260811203000",
                                sizeBytes: 3_000),
            ]

        case "a recording made on an earlier day and named the other way":
            listed = [PocketRecording(date: Self.prefixedDay, timestamp: Self.prefixedStamp,
                                      sizeBytes: 2_764_000)]

        case "a recording whose time is spelled in a way this build has never seen":
            listed = [PocketRecording(date: "2026-08-11", timestamp: "ZZ-not-a-time",
                                      sizeBytes: 2_000)]

        default:
            throw BrineStepError("unknown given: \(phrase)")
        }
    }

    // MARK: When

    func when(_ phrase: String) async throws {
        switch phrase {
        case "Solleva puts them in the order it shows them":
            // THE SHIPPED READER'S OWN ORDERING, applied to a listing in the firmware's
            // directory order rather than in time order — which is the whole reason the reader
            // sorts at all. `ordered(_:)` is the function `read(client:)` calls; driving it
            // directly is what lets this scenario run without a radio.
            listed = PocketInventoryReader.ordered(listed.shuffled())

        case "I bring it over":
            let recording = try XCTUnwrapAsync(listed.first, "no recording was set up")
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("pocket-spellings-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            self.root = root
            let audio = root.appendingPathComponent("held.mp3")
            try Self.fixtureMP3().write(to: audio)
            // THE SHIPPED IMPORT, with the SHIPPED derivation of the reported instant — the
            // exact expression `PocketBringOver` uses, so a fix that only edits the parser and
            // leaves the call site inventing `Date()` cannot pass this.
            let reported = PocketRecordingLabel.reportedInstant(date: recording.date,
                                                                timestamp: recording.timestamp)
            imported = try PocketCaptureImport.makeConversation(
                fromHeldFile: audio,
                recorder: RecordingDeviceIdentity(shape: .filePull, hardwareToken: "spellings"),
                displayName: "Pocket",
                recorderReported: reported,
                broughtOverAt: Self.collectedAt,
                binding: nil,
                baseDir: root,
                log: nil)
            clock = PocketConversationClock.resolve(reported: reported,
                                                    broughtOver: Self.collectedAt,
                                                    calendar: Self.utc)

        default:
            throw BrineStepError("unknown when: \(phrase)")
        }
    }

    // MARK: Then

    func then(_ phrase: String) async throws {
        switch phrase {
        case "both recordings show the time of day they were made":
            let titles = listed.map { PocketRecordingLabel.title(date: $0.date,
                                                                 timestamp: $0.timestamp) }
            guard titles.contains("\(Self.prefixedDay) · 17:50"),
                  titles.contains("\(Self.bareDay) · 14:28") else {
                throw BrineStepError("the rows read \(titles) — one of the two spellings is "
                                        + "not showing the time it names")
            }

        case "neither of them shows the recorder's raw name for the file instead of a time":
            for recording in listed {
                let title = PocketRecordingLabel.title(date: recording.date,
                                                       timestamp: recording.timestamp)
                guard !title.contains(recording.timestamp) else {
                    throw BrineStepError("the row reads \"\(title)\" — the recorder's own wire "
                                            + "token is on a person's screen instead of a time")
                }
            }

        case "they are listed newest first by when they were actually made":
            guard listed.map(\.timestamp)
                    == ["20260811203000", "PH260811175026", "20260811090000"] else {
                throw BrineStepError("the shelf reads \(listed.map(\.timestamp)) — that is the "
                                        + "raw text order, not the order they were made")
            }

        case "the way each one happens to be named does not change where it sits":
            // THE POSITIVE CONTROL. Sorted by the PARSED instant the answer above is correct;
            // sorted by the raw token it is not — so this step states the difference rather
            // than restating the previous assertion.
            let byRawToken = listed.sorted { $0.timestamp > $1.timestamp }.map(\.timestamp)
            guard byRawToken != listed.map(\.timestamp) else {
                throw BrineStepError("this fixture cannot tell the two orderings apart, so the "
                                        + "step above proves nothing")
            }

        case "the conversation is dated the day it was made":
            let capture = try XCTUnwrapAsync(imported, "nothing was imported")
            guard Self.day(of: capture.startedAt) == "2026-08-11" else {
                throw BrineStepError("the conversation is dated "
                                        + "\(Self.day(of: capture.startedAt)), not the day the "
                                        + "recording was made")
            }

        case "it is not dated the day I collected it":
            let capture = try XCTUnwrapAsync(imported, "nothing was imported")
            guard Self.day(of: capture.startedAt)
                    != Self.day(of: UInt64(Self.collectedAt.timeIntervalSince1970)) else {
                throw BrineStepError("the conversation was filed under the collection day")
            }

        case "Solleva says the recording's own time is not known":
            let resolved = try XCTUnwrapAsync(clock, "no clock reading")
            guard let warning = resolved.warning,
                  warning == PocketRecorderClockPresentation.timeNotReportedLine else {
                throw BrineStepError("an unreadable time produced the warning "
                                        + "\(resolved.warning ?? "(none)") — a recording filed "
                                        + "under an instant the recorder never stated must say "
                                        + "so")
            }

        case "the recording is still brought over":
            _ = try XCTUnwrapAsync(imported, "an unreadable time refused the whole transfer — "
                                     + "the recording is the owner's either way")

        default:
            throw BrineStepError("unknown then: \(phrase)")
        }
    }

    // MARK: Fixture

    static let utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    static func day(of epochSeconds: UInt64) -> String {
        let components = utc.dateComponents([.year, .month, .day],
                                            from: Date(timeIntervalSince1970: TimeInterval(epochSeconds)))
        return String(format: "%04d-%02d-%02d", components.year ?? 0,
                      components.month ?? 0, components.day ?? 0)
    }

    /// THE SAME THREE-SECOND RECORDING THE BRING-OVER SUITE USES, off the same real firmware.
    /// Loaded by path rather than through `Bundle.module` for the same reason that suite does
    /// it: this file is a `.copy` resource of the test target and `#filePath` reaches it
    /// without depending on how the bundle was assembled.
    static func fixtureMP3() throws -> Data {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("fixtures/pocket/pocket-fw16-3s.mp3")
        return try Data(contentsOf: url)
    }

    private func XCTUnwrapAsync<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw BrineStepError(message) }
        return value
    }
}
