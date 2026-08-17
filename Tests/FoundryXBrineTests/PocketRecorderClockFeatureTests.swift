import XCTest
import BrineSwiftCore
@testable import FoundryXKit

/// STEP 11 — THE CLOCK STOPS BEING DEAD IN BOTH HALVES.
///
/// ## The defect this holds
///
/// `PocketConversationClock.resolve` took a `lastClockSet: Date?` trust point and treated
/// `nil` — "we have never set this recorder's clock" — as EVIDENCE THAT THE CLOCK WAS WRONG:
///
/// ```swift
/// let beforeTrust = lastClockSet.map { reported < $0 } ?? true
/// ```
///
/// Nothing in the repository ever passed that argument. `PocketCaptureImport.makeConversation`
/// defaulted it to `nil` and its one production caller never overrode the default, so
/// `beforeTrust` was `true` for EVERY recording that has ever come off a recorder, and every one
/// of them earned "Time reported by recorder — device clock may have drifted". Nick's own
/// recorder is holding 19 recordings; all 19 would have been labelled suspect, including the
/// ones whose stamps are visibly correct.
///
/// The other half was worse: `PocketImportedCapture.clockWarning` was READ BY NOTHING. It was
/// returned into a struct that `PocketBringOver.conversation` discarded. A warning nobody could
/// see, computed from a trust point nobody could set.
///
/// ## Why this ships as a READ and not as a write
///
/// The obvious repair is `APP&T` — set the recorder's clock, record the instant, and the trust
/// point becomes real. It was NOT taken, and the reason is measured rather than argued:
///
///   * **The recorder has no clock-READ verb.** The 2026-08-16 hardware probe enumerated the
///     firmware-1.6 verb set (`foundry-hearth/reference/pocket-ble-protocol.md`) and there is no
///     command that answers with the device's own time. `APP&T` is write-only.
///   * **"Time: Synced to host" is not a device readback.** `pocket-libre`'s `status` prints
///     that line as an unconditional literal (`cli.py:403`) immediately after issuing a blind
///     `set_time()` (`cli.py:394`). It reports what the CLI just did, not what the device said.
///     Nothing in the protocol lets a recorder say its clock is adrift.
///
/// So the only device-sourced proof of drift that EXISTS is a recording the recorder stamps
/// LATER than the moment this phone received it — a time no recording can honestly have. That
/// is the one thing the warning is now allowed to fire on, and the trust point that nothing
/// could produce is gone rather than left defaulting to a lie.
///
/// **Stated limit, on purpose:** a recorder whose clock is stuck in the PAST is not detectable
/// this way, and this build does not claim to detect it. Detecting it needs a clock-read verb
/// the firmware does not have, or the `APP&T` write, which has never been issued to any real
/// device. That is the honest boundary and it is written into the source it constrains.
final class PocketRecorderClockFeatureTests: XCTestCase {
    func testPocketRecorderClockFeature() async throws {
        let world = PocketRecorderClockWorld()
        let result = try await BrineFeatureRunner.run(
            "pocket-recorder-clock", registry: .init(PocketRecorderClockSteps.make(world)))
        XCTAssertEqual(result.passed, 6)
    }
}

private enum PocketRecorderClockSteps {
    static func make(_ world: PocketRecorderClockWorld) -> [StepDefinition] {
        let givens = [
            "a recording the recorder dates before the moment it was brought over",
            "a recording the recorder dates after the moment it was brought over",
            "a brought-over recording whose recorder time is impossible",
            "a brought-over recording whose recorder time is ordinary",
            "a shelf of recordings the recorder dates across several days before they were fetched",
            "the shipped source of the app and of its kit",
        ]
        let whens = [
            "it is brought over",
            "the result of that bring-over is put into words",
            "every one of them is brought over",
            "the clock warning is traced from where it is written to where it is read",
        ]
        let thens = [
            "it keeps the recorder's own time and carries no clock warning",
            "it is filed under the day it arrived, the recorder's reported time is kept, and the warning says the recorder is ahead",
            "the words say the recording landed and then say the recorder's clock is ahead",
            "the words are exactly the ordinary landing sentence and nothing more",
            "not one of them carries a clock warning",
            "it has at least one writer and at least one reader, and nothing is left that only a deleted trust point could have produced",
        ]
        return givens.map { p in defineStep(p) { c, _, _ in try await world.given(p); return c } }
            + whens.map { p in defineStep(p) { c, _, _ in try await world.when(p); return c } }
            + thens.map { p in defineCheck(p) { _, _, _ in try await world.then(p) } }
    }
}

private actor PocketRecorderClockWorld {

    // MARK: - Fixtures

    /// The SAME real MPEG-2 Layer III the bring-over scenarios use — see
    /// `fixtures/pocket/PROVENANCE.txt`. A synthesised buffer would not survive
    /// `PocketAudioTranslator`, and an import that never decodes proves nothing about the
    /// import path.
    private static func fixtureMP3() -> Data {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("fixtures/pocket/pocket-fw16-3s.mp3")
        return (try? Data(contentsOf: root)) ?? Data()
    }

    private let identity = RecordingDeviceIdentity(shape: .filePull, hardwareToken: "peripheral")

    private var reported: [Date] = []
    private var broughtOverAt = Date(timeIntervalSince1970: 1_800_000_000)
    private var imported: [PocketImportedCapture] = []
    private var outcome: PocketBringOverOutcome?
    private var words: String?
    private var scan: ClockWarningScan?
    private var scratch: URL?

    // MARK: - Given

    func given(_ phrase: String) throws {
        reported = []; imported = []; outcome = nil; words = nil; scan = nil
        switch phrase {
        case "a recording the recorder dates before the moment it was brought over":
            reported = [broughtOverAt.addingTimeInterval(-86_400 * 3)]
        case "a recording the recorder dates after the moment it was brought over":
            reported = [broughtOverAt.addingTimeInterval(7_200)]
        case "a brought-over recording whose recorder time is impossible":
            outcome = .broughtOver(bytes: 42, captureID: "pkt-1",
                                   clockWarning: PocketRecorderClockPresentation.recorderAheadLine)
        case "a brought-over recording whose recorder time is ordinary":
            outcome = .broughtOver(bytes: 42, captureID: "pkt-1", clockWarning: nil)
        case "a shelf of recordings the recorder dates across several days before they were fetched":
            reported = (1...19).map { broughtOverAt.addingTimeInterval(-86_400 * Double($0)) }
        case "the shipped source of the app and of its kit":
            scan = try ClockWarningScan.read()
        default: throw BrineStepError("Unhandled Given: \(phrase)")
        }
    }

    // MARK: - When

    func when(_ phrase: String) throws {
        switch phrase {
        case "it is brought over", "every one of them is brought over":
            imported = try reported.map { try importOne(reportedAs: $0) }
        case "the result of that bring-over is put into words":
            guard let outcome else { throw BrineStepError("no bring-over to describe") }
            words = PocketBringOverPresentation.message(for: outcome)
        case "the clock warning is traced from where it is written to where it is read":
            break   // the trace IS the Given's read; the Then is what it must show
        default: throw BrineStepError("Unhandled When: \(phrase)")
        }
    }

    /// THE REAL IMPORT, not a call to the clock rule on its own. This writes a capture
    /// directory through the shipped `PocketCaptureImport.makeConversation` — the same function
    /// `PocketBringOver` calls — so the warning under assertion is one PRODUCTION code produced.
    private func importOne(reportedAs instant: Date) throws -> PocketImportedCapture {
        let base = scratchDirectory()
        let file = base.appendingPathComponent("recording-\(UUID().uuidString).mp3")
        try Self.fixtureMP3().write(to: file)
        let library = base.appendingPathComponent("captures", isDirectory: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        return try PocketCaptureImport.makeConversation(
            fromHeldFile: file, recorder: identity, displayName: "PKT01",
            recorderReported: instant, broughtOverAt: broughtOverAt,
            binding: nil, baseDir: library, log: nil)
    }

    private func scratchDirectory() -> URL {
        if let scratch { return scratch }
        let made = FileManager.default.temporaryDirectory
            .appendingPathComponent("pocket-clock-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: made, withIntermediateDirectories: true)
        scratch = made
        return made
    }

    // MARK: - Then

    func then(_ phrase: String) throws {
        switch phrase {
        case "it keeps the recorder's own time and carries no clock warning":
            let one = try requireOne()
            XCTAssertEqual(one.startedAt, UInt64(reported[0].timeIntervalSince1970),
                           "a recording the recorder dated sensibly was re-dated anyway")
            XCTAssertNil(one.clockWarning,
                         "a recording with nothing wrong with its time was warned about: "
                             + "\"\(one.clockWarning ?? "")\"")

        case "it is filed under the day it arrived, the recorder's reported time is kept, and "
            + "the warning says the recorder is ahead":
            let one = try requireOne()
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = .current
            XCTAssertEqual(one.startedAt,
                           UInt64(calendar.startOfDay(for: broughtOverAt).timeIntervalSince1970),
                           "a recording the recorder could not have made yet kept its "
                               + "impossible date")
            // THE REPORTED VALUE IS NOT LOST — the clock rule carries it, and the row's own
            // label is still spelled from the recorder's digits.
            let resolved = PocketConversationClock.resolve(reported: reported[0],
                                                           broughtOver: broughtOverAt,
                                                           calendar: calendar)
            XCTAssertEqual(resolved.recorderReported, reported[0],
                           "the recorder's own reported instant was discarded rather than kept")
            XCTAssertEqual(one.clockWarning, PocketRecorderClockPresentation.recorderAheadLine)

        case "the words say the recording landed and then say the recorder's clock is ahead":
            let said = try requireWords()
            XCTAssertTrue(said.hasPrefix(PocketBringOverPresentation.broughtOverLine),
                          "the person is told about the clock before being told the recording "
                              + "landed: \"\(said)\"")
            XCTAssertTrue(said.contains(PocketRecorderClockPresentation.recorderAheadLine),
                          "the clock warning never reached the person who asked for the "
                              + "recording: \"\(said)\"")

        case "the words are exactly the ordinary landing sentence and nothing more":
            XCTAssertEqual(try requireWords(), PocketBringOverPresentation.broughtOverLine,
                           "a recording with no clock trouble made the app say something extra")

        case "not one of them carries a clock warning":
            XCTAssertEqual(imported.count, 19, "the shelf did not import")
            let warned = imported.compactMap(\.clockWarning)
            XCTAssertEqual(warned, [],
                           "\(warned.count) of \(imported.count) recordings were warned about "
                               + "wholesale — the warning that fires on everything says nothing")

        case "it has at least one writer and at least one reader, and nothing is left that only "
            + "a deleted trust point could have produced":
            let found = try requireScan()
            // EXISTENCE FIRST, so the prohibition below cannot pass on a blank pane.
            XCTAssertGreaterThan(found.filesScanned, 100,
                                 "the source scan read \(found.filesScanned) files — it is "
                                     + "looking at the wrong tree, and every claim under it is "
                                     + "vacuous")
            XCTAssertFalse(found.declarations.isEmpty,
                           "`clockWarning` is not declared anywhere — this gate is asserting "
                               + "nothing")
            XCTAssertFalse(found.writers.isEmpty,
                           "`clockWarning` exists with NO PRODUCER: nothing anywhere assigns "
                               + "it. That is half the defect this step was opened for")
            XCTAssertFalse(found.readers.isEmpty,
                           "`clockWarning` exists with NO CONSUMER: nothing anywhere reads it. "
                               + "That is the other half")
            // AND THE READER IS NOT THE DECLARATION'S OWN FILE. A struct that only reads its
            // own stored property is not a consumer of it.
            XCTAssertFalse(found.readers.allSatisfy { found.declaringFiles.contains($0) },
                           "the only place `clockWarning` is read is the file that declares "
                               + "it — \(found.declaringFiles.joined(separator: ", "))")
            // THE PROHIBITION, over the same population the existence claims were made over.
            XCTAssertEqual(found.trustPointSites, [],
                           "`lastClockSet` is back in \(found.trustPointSites.joined(separator: ", "))"
                               + " — a trust point nothing in this repository can produce, which "
                               + "is exactly what made every recording look suspect")
        default: throw BrineStepError("Unhandled Then: \(phrase)")
        }
    }

    private func requireOne() throws -> PocketImportedCapture {
        guard imported.count == 1, !reported.isEmpty else {
            throw BrineStepError("expected exactly one imported recording, got \(imported.count)")
        }
        return imported[0]
    }
    private func requireWords() throws -> String {
        guard let words else { throw BrineStepError("the bring-over was never put into words") }
        return words
    }
    private func requireScan() throws -> ClockWarningScan {
        guard let scan else { throw BrineStepError("the source was never read") }
        return scan
    }
}

/// THE SOURCE-SCAN ASSERTION AC1 ASKS FOR, over `Sources/` AND `App/` together.
///
/// Comments are stripped before anything is counted (`AppSourceTree.withoutComments`): the
/// doc-comment above this very file names both identifiers repeatedly, and a gate that a
/// paragraph of prose can satisfy is not a gate. String literals are kept, because a line that
/// spells the field inside a literal would still be a spelling this scan should see.
private struct ClockWarningScan {
    var filesScanned = 0
    /// Files holding `let clockWarning` / `var clockWarning` — the declaration.
    var declaringFiles: [String] = []
    var declarations: [String] = []
    /// Lines that ASSIGN or PASS it: `clockWarning:` at a call or initialiser, off a
    /// declaration line.
    var writers: [String] = []
    /// Files holding a member READ — `.clockWarning` — anywhere.
    var readers: [String] = []
    /// Any surviving mention of the trust point nothing could produce.
    var trustPointSites: [String] = []

    static func read() throws -> ClockWarningScan {
        var scan = ClockWarningScan()
        for directory in ["Sources", "App", "Widget"] {
            let base = AppSourceTree.repoRoot.appendingPathComponent(directory, isDirectory: true)
            guard let walk = FileManager.default.enumerator(
                at: base, includingPropertiesForKeys: [.isRegularFileKey]) else { continue }
            for case let url as URL in walk where url.pathExtension == "swift" {
                guard let raw = try? String(contentsOf: url, encoding: .utf8) else { continue }
                scan.filesScanned += 1
                let path = AppSourceTree.relativePath(url)
                var declaresHere = false
                for line in AppSourceTree.withoutComments(of: raw).split(separator: "\n",
                                                                        omittingEmptySubsequences: false) {
                    let text = String(line)
                    if text.contains("lastClockSet") { scan.trustPointSites.append(path) }
                    // A DECLARATION CARRIES A TYPE. `let clockWarning:` is a stored property;
                    // `let clockWarning)` is an enum pattern BINDING inside a `switch`, which
                    // is a read and was miscounted as a declaration on the first run — it made
                    // the file that consumes the warning look like the file that owns it.
                    let isDeclaration = text.contains("let clockWarning:")
                        || text.contains("var clockWarning:")
                    if isDeclaration {
                        declaresHere = true
                        scan.declarations.append(path)
                        continue
                    }
                    if text.contains("clockWarning:") { scan.writers.append(path) }
                    if text.contains(".clockWarning") { scan.readers.append(path) }
                }
                if declaresHere { scan.declaringFiles.append(path) }
            }
        }
        scan.trustPointSites = Array(Set(scan.trustPointSites)).sorted()
        scan.readers = Array(Set(scan.readers)).sorted()
        scan.writers = Array(Set(scan.writers)).sorted()
        return scan
    }
}
