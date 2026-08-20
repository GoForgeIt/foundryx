import XCTest
import Foundation
import BrineSwiftCore
@testable import FoundryXKit

/// features/pocket-sizes-and-durations-are-true.feature
///
/// THIS SUITE HOLDS A PROPERTY, NOT A SPELLING, AND THAT IS THE WHOLE POINT.
///
/// The listing number has now been rendered wrongly twice — as minutes, then as kilobytes — and
/// the second was shipped as the fix for the first. A test that pinned the string "4 KB" would
/// have passed for the entire life of the defect, and a test that forbade the string "44 min"
/// would have passed while "4 KB" was on the screen. What is actually forbidden is the
/// DEPENDENCE: no number a person can see may change when the recorder's listing number
/// changes. Vary it across four orders of magnitude, render everything the surfaces can render,
/// and require the output to be identical.
///
/// The paired-existence half is here too, because "nothing changes" is satisfied perfectly by a
/// page that shows nothing at all: a recording whose REAL byte count is known must state how
/// long it runs, and two different byte counts must state two different lengths.
final class PocketSizesAndDurationsAreTrueFeatureTests: XCTestCase {
    func testPocketSizesAndDurationsAreTrueFeature() async throws {
        let world = SizesAndDurationsWorld()
        let result = try await BrineFeatureRunner.run(
            "pocket-sizes-and-durations-are-true",
            registry: StepRegistry(SizesAndDurationsSteps.make(world)))
        XCTAssertEqual(result.passed, 6)
    }

    // MARK: - The malformed input that used to become a confident answer

    /// A NON-POSITIVE BYTE COUNT MUST RENDER AS SILENCE, NOT AS "0 sec".
    ///
    /// FOUND BY AN ADVERSARIAL CROSS-VENDOR REVIEW, 2026-08-20, and it was live: `.bytes(_:)`
    /// is public and takes any `Int`, and `byteCount` CLAMPED with `max(0, n)`. So
    /// `.bytes(-1)` answered `isMeasured == true` with a count of `0`, and
    /// `PocketRecordingExtentPresentation.line` printed **"0 sec"** — the fourth invented
    /// magnitude on this surface, arriving through the one accessor written to prevent them.
    ///
    /// THE MUTATION THAT MAKES THIS RED: restore `return max(0, n)` in
    /// `PocketRecordingExtent.byteCount`. All three assertions below fail together.
    ///
    /// THE ANTI-VACUITY HALF is the last line: a `byteCount` that returned `nil` for
    /// EVERYTHING would satisfy the three prohibitions above it, and the measured pair off real
    /// hardware asserts the honest case still speaks.
    func testANonPositiveByteCountIsNotAMeasurement() {
        for malformed in [PocketRecordingExtent.bytes(-1), .bytes(0), .bytes(Int.min)] {
            XCTAssertFalse(malformed.isMeasured,
                           "\(malformed) is not a measurement and may not claim to be one")
            XCTAssertNil(malformed.byteCount)
            XCTAssertNil(PocketRecordingExtentPresentation.line(malformed),
                         "\(malformed) must render as silence — a clamp to zero is how "
                         + "\"0 sec\" got onto a row the first time")
        }
        // ANTI-VACUITY: the real measured pair off `PKT01_BLUE_26079bc5` still states a length.
        XCTAssertEqual(PocketRecordingExtentPresentation.line(.bytes(19_770)), "5 sec")
        XCTAssertEqual(PocketRecordingExtentPresentation.line(.bytes(185_078)), "46 sec")
    }
}

private enum SizesAndDurationsSteps {
    static func make(_ world: SizesAndDurationsWorld) -> [StepDefinition] {
        let givens = [
            "recorders listing one recording with wildly different listing numbers",
            "the two recordings that actually came off the recorder",
            "the recorder's own answer about its storage",
            "this phone is holding the bytes of one listed recording and not the other",
            "the sentences a recording's extent can state",
        ]
        let whens = [
            "I look at the row each of them draws",
            "I open the page about that recording on each of them",
            "the shelf works out how big each listed recording is",
        ]
        let thens = [
            "every row reads exactly the same, whatever the recorder listed",
            "no row states a magnitude at all",
            "there is a row, so this is not a claim about an empty page",
            "every page reads exactly the same, whatever the recorder listed",
            "no page refuses to bring a recording over because of a size nobody measured",
            "each row states the length its measured bytes imply",
            "the page about it states that length too, and stops saying nobody knows",
            "the line says how full it is",
            "it states no amount in bytes, kilobytes, megabytes or gigabytes",
            "the same fullness counted in another unit reads exactly the same",
            "the held recording's row states the length its real bytes imply",
            "the row for the one nobody fetched still states nothing",
            "there is at least one, so this is not a claim about an empty set",
            "every one of them is in the population the recording's page holds its copy over",
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

private actor SizesAndDurationsWorld {

    // MARK: - The device, as it actually answered

    /// One recording, spelled the way the recorder spells it. Fixed across every variant so
    /// that the ONLY thing changing between renderings is the listing number.
    private static let date = "2026-08-07"
    private static let timestamp = "20260807142852"
    private static let id = "\(date)/\(timestamp)"

    /// LISTING NUMBERS ACROSS FOUR ORDERS OF MAGNITUDE, and the last one is chosen.
    ///
    /// 4 and 46 are Nick's two measured files. 7,192 is his largest listing. 262,145 is one
    /// unit past the point where `sizeBytes` (`listing * 1024`) crosses
    /// `PocketBLEClient.maximumDownloadBytes` — the boundary at which the detail page USED to
    /// refuse the bring-over with "This recording is bigger than Solleva can bring over",
    /// which is a claim about size derived from a number that is not a size.
    private static let listingNumbers = [0, 4, 46, 7_192, 262_145]

    /// The two that came off the device, and what `MCU&U&` announced for each.
    private static let measured: [(listing: Int, bytes: Int, length: String)] = [
        (4, 19_770, "5 sec"),      // 19,770 / 4,000 = 4.94 s
        (46, 185_078, "46 sec"),   // 185,078 / 4,000 = 46.27 s
    ]

    /// `MCU&SPA&058767&058992`, verbatim.
    private static let storageUsed = 58_767
    private static let storageTotal = 58_992

    private static let now = Date(timeIntervalSince1970: 1_770_000_000)
    private static let listedAt = Date(timeIntervalSince1970: 1_769_996_400)

    /// A recording nobody has fetched, which is every row on the one device this app was built
    /// for: nineteen listings, none of them brought over.
    private static var listedOnly: PocketRecordingPresence {
        PocketRecordingPresence(
            onRecorder: PocketPlaceReading(answer: .yes, observedAt: listedAt),
            onThisPhone: PocketPlaceReading(answer: .no, observedAt: listedAt),
            safeElsewhere: PocketPlaceReading(answer: .no, observedAt: listedAt))
    }

    private static func recording(listing: Int) -> PocketRecording {
        // THE PRODUCTION UNIT CONVERSION, NOT A SHORT CUT. `PocketBLEClient` stores a listed
        // file as `listing * 1024`, so this is exactly the integer every shipped surface has
        // ever been handed for one of these rows.
        PocketRecording(date: date, timestamp: timestamp, sizeBytes: listing * 1_024)
    }

    private var rows: [StoredFileManifestRowPresentation] = []
    private var pages: [PocketRecordingDetailPage] = []
    private var measuredRows: [StoredFileManifestRowPresentation] = []
    private var storageLine: String?
    /// The sentences an extent can state, held so the scenario can assert the set is non-empty
    /// BEFORE asserting anything about its members.
    private var extentLines: [String] = []

    // MARK: - The custody half: a real store, a real file, real bytes on a real disk

    /// THE ONE RECORDER THIS APP WAS BUILT FOR, as an identity custody can key a file by.
    private static let identity = RecordingDeviceIdentity(shape: .filePull,
                                                          hardwareToken: "PKT01_BLUE_26079bc5")
    /// The recording whose bytes this phone is holding, and the one it is not. Both are
    /// listed by the recorder; only the first has ever been fetched.
    private static let heldTimestamp = "20260807142852"
    private static let unfetchedTimestamp = "PH260811175026"

    private var custodyRoot: URL?
    private var shelfRows: [StoredFileManifestRowPresentation] = []

    // MARK: - Given

    func given(_ phrase: String) async throws {
        switch phrase {

        case "this phone is holding the bytes of one listed recording and not the other":
            // A REAL STORE OVER A REAL DIRECTORY. `PocketRecorderFileStore` is the shipped
            // custody, and the file is written where custody itself says the file lives, so
            // what is being exercised is the production answer to "is this phone holding it"
            // — not a double that returns a URL somebody typed.
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("pocket-extent-\(UUID().uuidString)", isDirectory: true)
            custodyRoot = root
            let store = PocketRecorderFileStore(root: root)
            let held = store.url(for: PocketRecorderFileKey(identity: Self.identity,
                                                            date: Self.date,
                                                            timestamp: Self.heldTimestamp))
            try FileManager.default.createDirectory(at: held.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            // 19,770 BYTES — the exact length of the first file that ever came off a Pocket.
            // At the measured 4,000 B/s that is 4.94 s, which renders "5 sec"; the LISTING for
            // the same recording was 4, which through the old `listing * 1024` arithmetic
            // would render "1 sec". The two disagree, so this row cannot pass by accident.
            try Data(count: Self.measured[0].bytes).write(to: held)

        default:
            try givenTheRest(phrase)
        }
    }

    private func givenTheRest(_ phrase: String) throws {
        switch phrase {
        case "recorders listing one recording with wildly different listing numbers":
            rows = []; pages = []

        case "the two recordings that actually came off the recorder":
            // THE SHIPPED COMPOSITION. `PocketInventoryReader.manifest` is what the recorder
            // page and the live check both build their shelf through, and the extents it is
            // handed are what custody measured — never anything derived from the listing.
            let recordings = Self.measured.map { Self.recording(listing: $0.listing) }
            let extents = Dictionary(uniqueKeysWithValues: Self.measured.enumerated().map {
                ("\(Self.date)/\($0.offset)", PocketRecordingExtent.bytes($0.element.bytes))
            })
            // Distinct ids so two recordings can carry two different measured byte counts.
            let items = recordings.enumerated().map { index, _ in
                StoredFileManifestItem(id: "\(Self.date)/\(index)",
                                       title: "Recording \(index + 1)",
                                       extent: extents["\(Self.date)/\(index)"]!,
                                       presence: Self.listedOnly)
            }
            measuredRows = StoredFileDevicePresentation.manifest(items, now: Self.now).rows

        case "the recorder's own answer about its storage":
            storageLine = RecordingDeviceReadingPresentation.storageFullness(
                used: Self.storageUsed, total: Self.storageTotal)

        case "the sentences a recording's extent can state":
            extentLines = PocketRecordingExtentPresentation.everyLine

        default:
            throw BrineStepError("unknown given: \(phrase)")
        }
    }

    // MARK: - When

    func when(_ phrase: String) async throws {
        switch phrase {

        case "the shelf works out how big each listed recording is":
            // THE PRODUCTION RESOLVER, END TO END, AND IT IS THE ONLY THING THAT CAN PUT A
            // DEFENSIBLE MAGNITUDE ON A ROW. `PocketRecordingExtentReader.extents` is what the
            // authenticated check and the recorder page both call; `PocketInventoryReader.
            // manifest` is what turns recordings plus extents into shelf items; and
            // `StoredFileDevicePresentation.manifest` is what draws them.
            //
            // WITHOUT THIS SCENARIO THE READER HAD NO TEST AT ALL. Every other assertion in
            // this suite hands `PocketRecordingExtent.bytes(…)` to a presenter by hand, so a
            // reader that answered `.listedUnitUnresolved` for every file on the disk would
            // leave all 183 Pocket tests green while no row in the shipped app ever stated a
            // length again — an absence that looks EXACTLY like the correct rendering for a
            // recording nobody has fetched. Measured: with that one-line defect in place the
            // whole Pocket/Recorder/StoredFile/reachability population passed.
            guard let root = custodyRoot else {
                throw BrineStepError("no custody root was prepared")
            }
            let recordings = [
                PocketRecording(date: Self.date, timestamp: Self.heldTimestamp,
                                sizeBytes: Self.measured[0].listing * 1_024),
                PocketRecording(date: Self.date, timestamp: Self.unfetchedTimestamp,
                                sizeBytes: Self.measured[1].listing * 1_024),
            ]
            let extents = await PocketRecordingExtentReader.extents(
                recordings,
                identity: Self.identity,
                custody: PocketRecorderFileStore(root: root))
            let items = PocketInventoryReader.manifest(recordings,
                                                       extents: extents,
                                                       listedAt: Self.listedAt)
            shelfRows = StoredFileDevicePresentation.manifest(items, now: Self.now).rows

        case "I look at the row each of them draws":
            rows = try Self.listingNumbers.map { listing in
                let manifest = PocketInventoryReader.manifest(
                    [Self.recording(listing: listing)],
                    presences: [Self.id: Self.listedOnly],
                    listedAt: Self.listedAt)
                let drawn = StoredFileDevicePresentation.manifest(manifest, now: Self.now)
                guard let row = drawn.rows.first else {
                    throw BrineStepError("listing \(listing) drew no row at all")
                }
                return row
            }

        case "I open the page about that recording on each of them":
            pages = Self.listingNumbers.map { listing in
                PocketRecordingDetailPresentation.page(for: Self.recording(listing: listing),
                                                       presence: Self.listedOnly,
                                                       brain: .myComputer,
                                                       now: Self.now)
            }

        default:
            throw BrineStepError("unknown when: \(phrase)")
        }
    }

    // MARK: - Then

    func then(_ phrase: String) throws {
        switch phrase {

        case "the held recording's row states the length its real bytes imply":
            guard shelfRows.count == 2 else {
                throw BrineStepError("\(shelfRows.count) rows were drawn for two recordings")
            }
            guard shelfRows[0].extentLine == Self.measured[0].length else {
                throw BrineStepError(
                    "the row for a recording this phone is HOLDING states "
                    + "\(shelfRows[0].extentLine.map { "\"\($0)\"" } ?? "nothing") rather than "
                    + "\"\(Self.measured[0].length)\". Its 19,770 bytes are on the disk and "
                    + "custody can see them; at the measured 4,000 B/s that is how long it "
                    + "runs. \"1 sec\" would mean the row measured the listing (4 × 1,024) "
                    + "instead of the file")
            }

        case "the row for the one nobody fetched still states nothing":
            guard shelfRows.count == 2 else {
                throw BrineStepError("\(shelfRows.count) rows were drawn for two recordings")
            }
            guard shelfRows[1].extentLine == nil else {
                throw BrineStepError(
                    "a recording this phone is NOT holding states "
                    + "\"\(shelfRows[1].extentLine ?? "")\" — the only number anybody has for "
                    + "it is the listing's, whose unit was measured and disproved")
            }
            // AND THE TWO ROWS ARE THE SAME SHELF, so this is not one rendering compared with
            // a different one: both came out of a single resolve over a single custody.
            guard shelfRows[0].id != shelfRows[1].id else {
                throw BrineStepError("both rows describe one recording")
            }
            if let root = custodyRoot { try? FileManager.default.removeItem(at: root) }

        case "every row reads exactly the same, whatever the recorder listed":
            let rendered = rows.map(Self.everythingVisible(on:))
            guard Set(rendered).count == 1 else {
                throw BrineStepError(
                    "the row changed with the listing number. Listings "
                    + "\(Self.listingNumbers) drew \(rendered) — a number a person can see is "
                    + "derived from a field whose unit is unresolved (listing 4 was 19,770 "
                    + "bytes, listing 46 was 185,078)")
            }

        case "no row states a magnitude at all":
            for (listing, row) in zip(Self.listingNumbers, rows) {
                let text = Self.claimsAboutTheRecording(on: row)
                if let found = try Self.magnitude(in: text) {
                    throw BrineStepError(
                        "listing \(listing) drew \"\(found)\" — a magnitude about a recording "
                        + "nobody has measured")
                }
                guard row.extentLine == nil else {
                    throw BrineStepError(
                        "listing \(listing) states an extent of \"\(row.extentLine ?? "")\"")
                }
            }

        case "there is a row, so this is not a claim about an empty page":
            guard rows.count == Self.listingNumbers.count, !rows.isEmpty else {
                throw BrineStepError(
                    "\(rows.count) rows were drawn for \(Self.listingNumbers.count) listings — "
                    + "every prohibition above passes vacuously over a shelf with nothing on it")
            }
            // AND THE ROWS SAY SOMETHING. A row rendered entirely blank would satisfy both
            // rules above and is not the answer: the title and the three places stay.
            for row in rows {
                guard !row.title.isEmpty, !row.presenceLabel.isEmpty, row.places.count == 3 else {
                    throw BrineStepError(
                        "a row was rendered with nothing on it — withholding the extent is not "
                        + "licence to withhold the recording")
                }
            }

        case "every page reads exactly the same, whatever the recorder listed":
            guard pages.count == Self.listingNumbers.count else {
                throw BrineStepError("\(pages.count) pages were opened")
            }
            let rendered = pages.map(Self.everythingVisible(on:))
            guard Set(rendered).count == 1 else {
                throw BrineStepError(
                    "the page changed with the listing number. Listings "
                    + "\(Self.listingNumbers) drew \(rendered)")
            }
            for (listing, page) in zip(Self.listingNumbers, pages) {
                if let found = try Self.magnitude(in: Self.claimsAboutTheRecording(on: page)) {
                    throw BrineStepError(
                        "the page for listing \(listing) states \"\(found)\"")
                }
                guard page.notes.contains(
                    PocketRecordingExtentPresentation.unknownUntilBroughtOverLine) else {
                    throw BrineStepError(
                        "the page for listing \(listing) withholds the length and never says "
                        + "why — its notes are \(page.notes)")
                }
            }

        case "no page refuses to bring a recording over because of a size nobody measured":
            // THE CEILING USED TO BE CHECKED AGAINST `listing * 1024`. At 262,145 that clears
            // 256 MB and the page refused the transfer outright — a person told no about a
            // recording that, at the ONE size band anybody has measured, is about 65 seconds
            // of audio.
            for (listing, page) in zip(Self.listingNumbers, pages) {
                guard page.actions.contains(.bringItOver) else {
                    throw BrineStepError(
                        "the page for listing \(listing) does not offer to bring the recording "
                        + "over. Its notes are \(page.notes)")
                }
                guard !page.notes.contains(PocketRecordingDetailPresentation.tooBigLine) else {
                    throw BrineStepError(
                        "listing \(listing) is refused as too big, which is a claim about a "
                        + "size derived from a number that is not a size")
                }
            }
            // AND THE REFUSAL STILL WORKS WHEN THE SIZE IS REAL, so this is not the ceiling
            // being deleted. 512 MB measured is over the 256 MB the transfer will carry.
            let huge = PocketRecordingDetailPresentation.page(
                for: Self.recording(listing: 4), presence: Self.listedOnly, brain: .myComputer,
                extent: .bytes(512 * 1_024 * 1_024), now: Self.now)
            guard huge.notes.contains(PocketRecordingDetailPresentation.tooBigLine),
                  !huge.actions.contains(.bringItOver) else {
                throw BrineStepError(
                    "a recording MEASURED at 512 MB is still offered, so the ceiling cannot "
                    + "refuse anything at all")
            }

        case "each row states the length its measured bytes imply":
            guard measuredRows.count == Self.measured.count else {
                throw BrineStepError("\(measuredRows.count) measured rows were drawn")
            }
            let expected = Self.measured.map(\.length)
            guard measuredRows.map(\.extentLine) == expected else {
                throw BrineStepError(
                    "rows with real byte counts state \(measuredRows.map(\.extentLine)) rather "
                    + "than \(expected) — 32 kbps CBR is 4,000 bytes per second, measured off "
                    + "the frame header 0xFFF348C4 on both files")
            }
            // TWO BYTE COUNTS, TWO LENGTHS. A renderer that printed one constant would satisfy
            // the equality above if the fixture had one row in it.
            guard Set(measuredRows.compactMap(\.extentLine)).count == Self.measured.count else {
                throw BrineStepError(
                    "two different byte counts render the same length, so the length does not "
                    + "depend on the bytes")
            }

        case "the page about it states that length too, and stops saying nobody knows":
            let page = PocketRecordingDetailPresentation.page(
                for: Self.recording(listing: Self.measured[0].listing),
                presence: Self.listedOnly, brain: .myComputer,
                extent: .bytes(Self.measured[0].bytes), now: Self.now)
            guard page.facts.contains(where: {
                $0.label == PocketRecordingDetailPresentation.lengthLabel
                    && $0.value == Self.measured[0].length
            }) else {
                throw BrineStepError(
                    "the page about a measured recording states "
                    + "\(page.facts.map { "\($0.label)=\($0.value)" }) rather than its length")
            }
            guard !page.notes.contains(
                PocketRecordingExtentPresentation.unknownUntilBroughtOverLine) else {
                throw BrineStepError(
                    "the page states the length AND says nobody knows it — two answers to one "
                    + "question, on one screen")
            }

        case "the line says how full it is":
            guard let line = storageLine else {
                throw BrineStepError(
                    "the recorder answered MCU&SPA&058767&058992 and the strip printed nothing")
            }
            // 58,767 / 58,992 is 99.6%, and the recorder is very nearly full. That is the fact
            // a person opens this page for, and it is unit-free.
            guard line == "99% full" else {
                throw BrineStepError("the storage line reads \"\(line)\"")
            }

        case "it states no amount in bytes, kilobytes, megabytes or gigabytes":
            guard let line = storageLine else { throw BrineStepError("no storage line") }
            if let found = try Self.magnitude(in: line) {
                throw BrineStepError(
                    "the storage line states \"\(found)\". It used to read \"225 KB free of "
                    + "57.6 MB\" on a 64 GB recorder, which is wrong however the unit is read")
            }

        case "the same fullness counted in another unit reads exactly the same":
            // THE PROPERTY, FOR STORAGE. Whatever those five digits count, the ratio is the
            // same ratio — so a rendering that depends only on the ratio cannot change when
            // the unit does. One that stated an amount would change by 1,024x here.
            let scaled = RecordingDeviceReadingPresentation.storageFullness(
                used: Self.storageUsed * 1_024, total: Self.storageTotal * 1_024)
            guard scaled == storageLine else {
                throw BrineStepError(
                    "counted 1,024x finer the same recorder reads \"\(scaled ?? "nothing")\" "
                    + "rather than \"\(storageLine ?? "nothing")\" — the line depends on a unit "
                    + "nobody has resolved")
            }
            // AND A RECORDER THAT ANSWERED NOTHING RENDERS NOTHING, rather than "0% full".
            guard RecordingDeviceReadingPresentation.storageFullness(used: 0, total: 0) == nil else {
                throw BrineStepError(
                    "a recorder with no stated capacity is rendered as a percentage anyway")
            }

        case "there is at least one, so this is not a claim about an empty set":
            guard !extentLines.isEmpty else {
                throw BrineStepError(
                    "PocketRecordingExtentPresentation.everyLine is empty, so the claim below "
                    + "is held over nothing and would pass however the page was built")
            }

        case "every one of them is in the population the recording's page holds its copy over":
            // THE UNPROTECTED HALF OF A MERGE CONFLICT. `PocketRecordingDetailPresentation`
            // .everyLine is the WHOLE population this page's copy claims are held over, and on
            // 2026-08-20 two branches each appended a different family to it — the delete
            // consequences and these extent sentences — so git could not merge that line and a
            // human chose. Choosing either side alone compiles and reads plausibly.
            //
            // Dropping the delete half is caught: PocketRemoveFromRecorderFeatureTests requires
            // every consequence to be in this same population. Dropping THIS half was caught by
            // nothing — the extent scenarios above check what the page RENDERS, and a sentence
            // can render perfectly while being absent from the population a later prohibition
            // sweeps. That is a gate that stops asking and looks exactly like a pass.
            // *(Adversarial review, 2026-08-20.)*
            let population = PocketRecordingDetailPresentation.everyLine
            for line in extentLines where !population.contains(line) {
                throw BrineStepError(
                    "\"\(line)\" is a sentence the recording's page can state about its extent "
                    + "and it is not in that page's population, so every claim held over that "
                    + "population silently skips it")
            }

        default:
            throw BrineStepError("unknown then: \(phrase)")
        }
    }

    // MARK: - Everything a person can see, as one string

    /// EVERY user-visible field of a row, joined. Rendering all of them rather than the one
    /// under suspicion is what makes this a property: a magnitude smuggled into the presence
    /// label, or into a note somebody adds next month, fails the same assertion.
    private static func everythingVisible(on row: StoredFileManifestRowPresentation) -> String {
        ([row.title, row.extentLine ?? "", row.presenceLabel]
         + row.places.flatMap { [$0.place, $0.answer, $0.age] }
         + row.presenceBlock.chips.flatMap { [$0.place, $0.answer] }
         + [row.presenceBlock.ageLine ?? ""])
            .joined(separator: " | ")
    }

    private static func everythingVisible(on page: PocketRecordingDetailPage) -> String {
        ([page.title] + page.facts.flatMap { [$0.label, $0.value] }
         + page.places.flatMap { [$0.place, $0.answer, $0.age] }
         + page.actions.map(\.title) + page.notes)
            .joined(separator: " | ")
    }

    /// THE SAME SURFACE MINUS THE AGES, and the exclusion is narrow and deliberate.
    ///
    /// "read 1 hour ago" is a duration, and it is a claim about THIS PHONE'S CLOCK measuring
    /// itself — not about the recorder, and not derived from anything the recorder said. It
    /// stays inside the identity comparison above (an age that moved with the listing number
    /// would still be a red) and comes out of the magnitude scan, because a scan that flagged
    /// it would have to be loosened until it flagged nothing.
    private static func claimsAboutTheRecording(on row: StoredFileManifestRowPresentation) -> String {
        ([row.title, row.extentLine ?? "", row.presenceLabel]
         + row.places.flatMap { [$0.place, $0.answer] }
         + row.presenceBlock.chips.flatMap { [$0.place, $0.answer] })
            .joined(separator: " | ")
    }

    private static func claimsAboutTheRecording(on page: PocketRecordingDetailPage) -> String {
        ([page.title] + page.facts.flatMap { [$0.label, $0.value] }
         + page.places.flatMap { [$0.place, $0.answer] }
         + page.actions.map(\.title) + page.notes)
            .joined(separator: " | ")
    }

    /// ANY MAGNITUDE, IN ANY UNIT THIS APP HAS EVER USED OR MIGHT — including the bare byte
    /// counts and the durations, because the two shipped defects were one of each.
    private static func magnitude(in text: String) throws -> String? {
        let pattern = #"\d+(\.\d+)?\s*(bytes?|B|KB|kB|MB|GB|KiB|MiB|"#
            + #"sec|secs|second|seconds|min|mins|minute|minutes|hr|hrs|hour|hours)\b"#
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let found = Range(match.range, in: text) else { return nil }
        return String(text[found])
    }
}
