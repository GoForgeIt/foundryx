import XCTest
import Foundation
import BrineSwiftCore
@testable import FoundryXKit

/// features/pocket-numbers-were-measured.feature — Step 3 of the pocket delivery plan.
///
/// THIS SUITE IS THE ONLY ONE THAT LOOKS AT THE REPOSITORY'S EVIDENCE AND AT THE PRODUCT'S
/// COPY IN THE SAME BREATH, which is the whole point of Step 3: a bench sitting nobody's code
/// consults is a nice document. The steps below drive the SHIPPED presentation types — the ones
/// `App/DeviceScreen.swift` renders — and resolve every figure they can print against a file
/// under `evidence/pocket` that holds the recorder's own frame, verbatim.
///
/// PLAIN `XCTestCase`, deliberately. Nothing here signs an account in or moves
/// `CaptureAccountScope`; the surfaces under test are pure presentation over injected values,
/// and inheriting `ProcessGlobalStateTestCase` would buy a sandbox nothing needs.
final class PocketMeasuredNumbersFeatureTests: XCTestCase {
    func testPocketNumbersWereMeasuredFeature() async throws {
        let world = MeasuredNumbersWorld()
        let result = try await BrineFeatureRunner.run(
            "pocket-numbers-were-measured",
            registry: StepRegistry(MeasuredNumbersSteps.make(world)))
        XCTAssertEqual(result.passed, 4,
                       "the fast-sync scenario went with the feature on 2026-08-20; four remain")
    }
}

private enum MeasuredNumbersSteps {
    static func make(_ world: MeasuredNumbersWorld) -> [StepDefinition] {
        let givens = [
            "the figures Solleva can print about a recorder",
            "a recorder that lists two recordings whose real sizes were measured later",
            "the bench sitting held on the recorder",
        ]
        let whens = [
            "I open that recorder's page",
        ]
        let thens = [
            "each printed figure names an observation taken off a recorder",
            "each of those observations is on file, naming the recorder and the firmware it ran",
            "at least one figure is printed",
            "no row states a size or a length drawn from the listing",
            "a row whose real byte count is known does state how long it runs",
            "every figure resting on a planning guess is withheld",
            "each withheld figure says why nobody has measured it yet",
            "the recorder's answer about its network credentials is recorded exactly as it came back",
            "the recorder's answer about deleting a file that cannot exist is recorded exactly as it came back",
            "what nobody measured is written down beside it, so it cannot be quoted as a result",
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

private actor MeasuredNumbersWorld {

    // MARK: - What the bench actually saw, as the recorder said it

    /// THE TWO LISTING NUMBERS WHOSE REAL SIZE IS KNOWN, and they are the whole argument.
    ///
    /// `MCU&F&<date>&<stamp>&<n>` said 4 and 46 for these two recordings. Both files came off
    /// `PKT01_BLUE_26079bc5` on 2026-08-18 and `MCU&U&` announced **19,770** and **185,078**
    /// bytes. As bytes the listing is out by 4,943x then 4,023x; as kibibytes the real file is
    /// 4.83x then 3.93x larger. A unit off by a VARYING factor is not a unit.
    ///
    /// This suite used to carry `statedKilobytes = [2_648, 1_712]` and assert the rows printed
    /// "2.6 MB" and "1.7 MB" from them. That is the assertion this scenario now forbids.
    private static let listingNumbers = [4, 46]
    private static let announcedBytes = [19_770, 185_078]

    private var figures: [PocketFigure] = []
    private var manifest: StoredFileManifestPresentation?
    private var artifacts: [String: String] = [:]

    // MARK: - Where the evidence lives

    /// Repo root is three parents up from this file, the same `#filePath` mechanism
    /// `BrineFeatureRunner` uses for `features/` — and for the same reason: these artifacts are
    /// `exclude`d in `Package.swift` rather than copied into a bundle, because evidence is a
    /// repository fact, not an app resource.
    private static func evidenceRoot() -> URL {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { root.deleteLastPathComponent() }
        return root.appendingPathComponent(PocketMeasuredFigures.evidenceDirectory)
    }

    private static func read(_ artifact: String) throws -> String {
        let url = evidenceRoot().appendingPathComponent(artifact)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw BrineStepError(
                "no observation on file at \(PocketMeasuredFigures.evidenceDirectory)/\(artifact)")
        }
        return text
    }

    // MARK: - Given

    func given(_ phrase: String) throws {
        switch phrase {
        case "the figures Solleva can print about a recorder":
            figures = PocketMeasuredFigures.all

        case "a recorder that lists two recordings whose real sizes were measured later":
            figures = PocketMeasuredFigures.all

        case "the bench sitting held on the recorder":
            artifacts[PocketMeasuredFigures.verbProbeArtifact] =
                try Self.read(PocketMeasuredFigures.verbProbeArtifact)
            artifacts[PocketMeasuredFigures.benchArtifact] =
                try Self.read(PocketMeasuredFigures.benchArtifact)

        default:
            throw BrineStepError("unknown given: \(phrase)")
        }
    }

    // MARK: - When

    func when(_ phrase: String) throws {
        switch phrase {
        case "I open that recorder's page":
            // THE SHIPPED RENDERER, not a copy of its arithmetic. `App/DeviceScreen.swift`
            // draws exactly these rows.
            manifest = StoredFileDevicePresentation.manifest(
                Self.listingNumbers.indices.map { index in
                    StoredFileManifestItem(id: "2026-08-07/\(index)",
                                           title: "Recording \(index + 1)",
                                           // A recording nobody has fetched. The listing DID
                                           // state a number; there is nowhere to put it.
                                           extent: .listedUnitUnresolved,
                                           presence: .nothingAsked)
                })
        default:
            throw BrineStepError("unknown when: \(phrase)")
        }
    }

    // MARK: - Then

    func then(_ phrase: String) throws {
        switch phrase {

        case "each printed figure names an observation taken off a recorder":
            for figure in figures where figure.isPrinted {
                guard case .recorderSaidSo(_, let frame) = figure.support else {
                    throw BrineStepError("\(figure.id) is printed but names no frame")
                }
                guard frame.hasPrefix("MCU&") else {
                    throw BrineStepError(
                        "\(figure.id) names \"\(frame)\", which is not a frame a recorder sent")
                }
            }

        case "each of those observations is on file, naming the recorder and the firmware it ran":
            for figure in figures where figure.isPrinted {
                guard case .recorderSaidSo(let artifact, let frame) = figure.support else { continue }
                let text = try Self.read(artifact)
                // VERBATIM, AND THE WHOLE FRAME. `MCU&D&ERR` shares a prefix with `MCU&DIRS`,
                // `MCU&DIRS_SUM` and a delete ack; a substring check on a prefix would call
                // four different frames the same observation.
                guard text.contains(frame) else {
                    throw BrineStepError("\(artifact) does not hold \(frame) verbatim")
                }
                guard text.contains(PocketMeasuredFigures.benchDeviceIdentifier) else {
                    throw BrineStepError("\(artifact) never names the recorder it came off")
                }
                guard text.contains(PocketMeasuredFigures.benchFirmwareVersion) else {
                    throw BrineStepError("\(artifact) never names the firmware it was running")
                }
            }

        case "at least one figure is printed":
            // THE PAIRED EXISTENCE ASSERTION. Every prohibition above passes vacuously over an
            // empty register; this is the line that stops the scan passing by printing nothing.
            guard !PocketMeasuredFigures.printed.isEmpty else {
                throw BrineStepError("no figure is printed at all — the scan passed vacuously")
            }
            // And they are printed BY THE SHIPPED STRIP, not merely registered. The two the
            // recorder answered on 2026-08-16 go through the real reading presentation.
            let now = Date(timeIntervalSince1970: 1_770_000_000)
            let lines = RecordingDeviceReadingPresentation.lines([
                RecordingDeviceCapabilityKey.batteryLevel.rawValue:
                    RecordingDeviceReading(value: "58%", observedAt: now),
                RecordingDeviceCapabilityKey.firmwareVersion.rawValue:
                    RecordingDeviceReading(value: "1.6", observedAt: now),
                RecordingDeviceCapabilityKey.freeSpace.rawValue:
                    RecordingDeviceReading(
                        value: RecordingDeviceReadingPresentation.storageFullness(
                            used: 58_767, total: 58_992) ?? "",
                        observedAt: now),
            ], now: now)
            guard lines.allSatisfy(\.wasRead), lines.count == 3 else {
                throw BrineStepError("the readings strip did not print the three measured facts")
            }
            // A RATIO, NOT AN AMOUNT. This used to require "225 KB free of" — which is what a
            // 64 GB recorder rendered on Nick's phone, and is wrong however the unit is read.
            // `used / total` cancels the unit the recorder never told us.
            guard lines.contains(where: { $0.value == "58%" }),
                  lines.contains(where: { $0.value == "1.6" }),
                  lines.contains(where: { $0.value == "99% full" }) else {
                throw BrineStepError(
                    "the strip printed \(lines.compactMap(\.value)), not the recorder's own numbers")
            }

        case "no row states a size or a length drawn from the listing":
            guard let rows = manifest?.rows, rows.count == Self.listingNumbers.count else {
                throw BrineStepError("the page drew \(manifest?.rows.count ?? 0) rows")
            }
            // ANY MAGNITUDE, NOT ONE SPELLING OF ONE. "4 KB" and "44 min" are the same defect
            // in two units, and the second was shipped as the fix for the first.
            let magnitude = try NSRegularExpression(
                pattern: #"\d+(\.\d+)?\s*(B|KB|MB|GB|bytes|sec|secs|min|mins|hr|hrs|hours?)\b"#)
            for row in rows {
                let text = ([row.title, row.extentLine ?? "", row.presenceLabel]
                            + row.places.flatMap { [$0.place, $0.answer, $0.age] })
                    .joined(separator: " ")
                let range = NSRange(text.startIndex..., in: text)
                if magnitude.firstMatch(in: text, range: range) != nil {
                    throw BrineStepError(
                        "a row states a magnitude — \"\(text)\" — for a recording whose only "
                        + "number is the listing's, and the listing's unit is unresolved: "
                        + "listing 4 was 19,770 bytes and listing 46 was 185,078")
                }
            }

        case "a row whose real byte count is known does state how long it runs":
            // THE PAIRED-EXISTENCE HALF. "No row states a magnitude" is satisfied by a shelf
            // that can never state one, and a shelf that can never say how long anything is
            // is not the goal — it is the same silence with a different cause.
            let measured = StoredFileDevicePresentation.manifest(
                Self.announcedBytes.enumerated().map { index, bytes in
                    StoredFileManifestItem(id: "2026-08-07/\(index)",
                                           title: "Recording \(index + 1)",
                                           extent: .bytes(bytes),
                                           presence: .nothingAsked)
                })
            // 19,770 / 4,000 = 4.94 s; 185,078 / 4,000 = 46.27 s. The divisor is measured:
            // both files decode MPEG-2 Layer III, 32 kbps, 16 kHz, mono (header 0xFFF348C4).
            guard measured.rows.map(\.extentLine) == ["5 sec", "46 sec"] else {
                throw BrineStepError(
                    "rows with real byte counts state \(measured.rows.map(\.extentLine)) "
                    + "rather than the lengths 4,000 bytes/second implies")
            }

        case "every figure resting on a planning guess is withheld":
            guard !PocketMeasuredFigures.withheld.isEmpty else {
                throw BrineStepError("nothing is withheld — this scan proves nothing")
            }
            for figure in PocketMeasuredFigures.withheld where figure.isPrinted {
                throw BrineStepError("\(figure.id) rests on a guess and is printed anyway")
            }
            // AND PRODUCTION AGREES. The three questions the shipped surfaces ask this
            // register, asserted here so a surface that stops asking is a red, not a shrug.
            guard !PocketMeasuredFigures.mayStateAnExtentFromTheListing,
                  !PocketMeasuredFigures.storageMayStateAnAmount,
                  !PocketMeasuredFigures.fastSyncOfferMayClaimSpeed,
                  !PocketMeasuredFigures.deleteMayClaimReclaimedSpace else {
                throw BrineStepError("a surface is permitted to print an unmeasured figure")
            }
            // AND THE TWO THAT ARE PERMITTED, so this is a register that can still say yes.
            guard PocketMeasuredFigures.mayStateLengthFromAMeasuredByteCount,
                  PocketMeasuredFigures.mayStateHowFullTheRecorderIs else {
                throw BrineStepError(
                    "the register permits nothing, so every prohibition above is vacuous")
            }

        case "each withheld figure says why nobody has measured it yet":
            // TWO REASONS A FIGURE IS WITHHELD, AND THEY OWE DIFFERENT THINGS. The rule used to
            // be one — "say why, and say what would close it" — because withheld could only mean
            // unmeasured. A figure we measured ourselves and still refuse to print (a rate taken
            // once, on one unit, at one distance) has nothing left to close, and demanding a
            // settlement clause from it would force a fiction. So the obligation SPLITS, and the
            // measured branch owes MORE rather than less: the evidence standard of a printed
            // figure, on a figure that is still not printed.
            var measuredWithheld = 0
            for figure in PocketMeasuredFigures.withheld {
                guard let reason = figure.withheldBecause, reason.count > 40 else {
                    throw BrineStepError("\(figure.id) is withheld without saying why")
                }
                switch figure.support {
                case .recorderSaidSo:
                    throw BrineStepError("\(figure.id) is withheld while naming a recorder frame")

                case .planningGuess:
                    guard reason.contains("Closed by:") else {
                        throw BrineStepError(
                            "\(figure.id) says why it is withheld but not what would settle it")
                    }

                case .weMeasured(let artifact, let method):
                    measuredWithheld += 1
                    guard method.count > 40 else {
                        throw BrineStepError("\(figure.id) was measured but names no method")
                    }
                    // THE SAME EVIDENCE BAR A PRINTED FIGURE CLEARS. A measurement nobody can
                    // find is a claim, and this register exists because claims were being
                    // rendered as results.
                    let text = try Self.read(artifact)
                    guard text.contains(PocketMeasuredFigures.benchDeviceIdentifier) else {
                        throw BrineStepError("\(artifact) never names the recorder it came off")
                    }
                    guard text.contains(PocketMeasuredFigures.benchFirmwareVersion) else {
                        throw BrineStepError("\(artifact) never names the firmware it was running")
                    }
                }
            }
            // PAIRED EXISTENCE for the new branch: with no measured-but-withheld figure at all,
            // every rule in that arm passes over an empty loop.
            guard measuredWithheld >= 1 else {
                throw BrineStepError(
                    "no figure is measured-but-withheld, so that arm is vacuous")
            }

        case "the recorder's answer about its network credentials is recorded exactly as it came back":
            try requireVerbatim("MCU&WIFI&PKT01_BLUE_26079bc5&PD9QQDJ6")

        case "the recorder's answer about deleting a file that cannot exist is recorded exactly as it came back":
            try requireVerbatim("MCU&D&ERR")
            // The frame that PROVOKED it, so the refusal cannot be read as a delete that
            // happened to something real.
            guard artifacts[PocketMeasuredFigures.benchArtifact]?
                .contains("APP&D&1970-01-01&19700101000000") == true else {
                throw BrineStepError("the bench never records which frame drew MCU&D&ERR")
            }

        case "what nobody measured is written down beside it, so it cannot be quoted as a result":
            guard let bench = artifacts[PocketMeasuredFigures.benchArtifact] else {
                throw BrineStepError("the bench write-up was never read")
            }
            guard bench.contains("NOT MEASURED") else {
                throw BrineStepError("the bench write-up has no section for what was not measured")
            }
            for absence in ["BLE throughput", "WiFi transfer", "endpoint", "150"] {
                guard bench.contains(absence) else {
                    throw BrineStepError("the bench never records \"\(absence)\" as unmeasured")
                }
            }

        default:
            throw BrineStepError("unknown then: \(phrase)")
        }
    }

    /// A frame has to appear, character for character, in BOTH the raw capture and the
    /// write-up — because a write-up that paraphrases the raw capture is the mechanism by
    /// which `PD9QQDJ6` becomes `PD9QQDJ8` somewhere between the bench and the reader.
    private func requireVerbatim(_ frame: String) throws {
        for (name, text) in artifacts {
            guard text.contains(frame) else {
                throw BrineStepError("\(name) does not hold \(frame) verbatim")
            }
        }
        guard artifacts.count == 2 else {
            throw BrineStepError("only \(artifacts.count) artifact(s) were read")
        }
    }
}
