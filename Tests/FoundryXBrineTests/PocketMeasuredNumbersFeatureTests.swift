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
        XCTAssertEqual(result.passed, 5)
    }
}

private enum MeasuredNumbersSteps {
    static func make(_ world: MeasuredNumbersWorld) -> [StepDefinition] {
        let givens = [
            "the figures Solleva can print about a recorder",
            "a recorder that lists two recordings with the sizes it stated",
            "the words Solleva uses to offer fast sync",
            "the bench sitting held on the recorder",
        ]
        let whens = [
            "I open that recorder's page",
        ]
        let thens = [
            "each printed figure names an observation taken off a recorder",
            "each of those observations is on file, naming the recorder and the firmware it ran",
            "at least one figure is printed",
            "each row shows the size that came off the recorder",
            "no row says how long a recording lasts",
            "none of them claim it is faster",
            "they say what it actually does instead",
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

    /// The two sizes on `MCU&F&2026-08-07&…`, in the unit the recorder states them in.
    /// 2,648 KB and 1,712 KB — two real rows from the real shelf, not round numbers.
    private static let statedKilobytes = [2_648, 1_712]

    private var figures: [PocketFigure] = []
    private var manifest: StoredFileManifestPresentation?
    private var fastSyncCopy: [String] = []
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

        case "a recorder that lists two recordings with the sizes it stated":
            // Kilobytes as the wire carries them, turned into the bytes the manifest item
            // declares. The shelf's own unit conversion is under test, so it is not short-cut.
            figures = PocketMeasuredFigures.all

        case "the words Solleva uses to offer fast sync":
            fastSyncCopy = PocketFastSyncPresentation.everyLine

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
                Self.statedKilobytes.enumerated().map { index, kilobytes in
                    StoredFileManifestItem(id: "2026-08-07/\(index)",
                                           title: "Recording \(index + 1)",
                                           sizeBytes: kilobytes * 1_024,
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
                        value: RecordingDeviceReadingPresentation.freeSpace(
                            usedKilobytes: 58_767, capacityKilobytes: 58_992),
                        observedAt: now),
            ], now: now)
            guard lines.allSatisfy(\.wasRead), lines.count == 3 else {
                throw BrineStepError("the readings strip did not print the three measured facts")
            }
            guard lines.contains(where: { $0.value == "58%" }),
                  lines.contains(where: { $0.value == "1.6" }),
                  lines.contains(where: { ($0.value ?? "").contains("225 KB free of") }) else {
                throw BrineStepError(
                    "the strip printed \(lines.compactMap(\.value)), not the recorder's own numbers")
            }

        case "each row shows the size that came off the recorder":
            guard let rows = manifest?.rows, rows.count == Self.statedKilobytes.count else {
                throw BrineStepError("the page drew \(manifest?.rows.count ?? 0) rows")
            }
            let expected = Self.statedKilobytes.map {
                RecordingDeviceReadingPresentation.size(kilobytes: $0)
            }
            guard rows.map(\.size) == expected else {
                throw BrineStepError("rows show \(rows.map(\.size)), not \(expected)")
            }

        case "no row says how long a recording lasts":
            guard let rows = manifest?.rows else { throw BrineStepError("no page was opened") }
            // A duration in this app's own vocabulary: "44 min", "1 hr 12 min", "22 sec".
            let duration = try NSRegularExpression(pattern: #"\d+\s*(sec|min|hr)\b"#)
            for row in rows {
                let text = ([row.title, row.size, row.presenceLabel]
                            + row.places.flatMap { [$0.place, $0.answer, $0.age] })
                    .joined(separator: " ")
                let range = NSRange(text.startIndex..., in: text)
                if duration.firstMatch(in: text, range: range) != nil {
                    throw BrineStepError(
                        "a row states a duration — \"\(text)\" — and no recorder has ever "
                        + "told this app how long a recording is")
                }
            }

        case "none of them claim it is faster":
            guard !fastSyncCopy.isEmpty else {
                throw BrineStepError("the fast-sync family enumerates no copy at all")
            }
            // COMPARATIVES, NOT THE WORD "FAST". "Fast sync" is the feature's NAME; "much
            // faster" is an unmeasured claim about a leg nobody has ever timed.
            let claims = ["faster", "quicker", "speedier", "fastest", "times as fast", "150"]
            for line in fastSyncCopy {
                let lowered = line.lowercased()
                if let claim = claims.first(where: { lowered.contains($0) }) {
                    throw BrineStepError(
                        "fast-sync copy claims \"\(claim)\" in \"\(line)\" — the transfer has "
                        + "never been performed and neither leg has ever been timed")
                }
            }

        case "they say what it actually does instead":
            let joined = fastSyncCopy.joined(separator: " ").lowercased()
            guard joined.contains("wifi") || joined.contains("wi-fi") else {
                throw BrineStepError("fast-sync copy never says it uses the recorder's WiFi")
            }
            guard joined.contains("leaves its normal network")
                    || joined.contains("normal wifi") else {
                throw BrineStepError("fast-sync copy never says the phone leaves its network")
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
            guard !PocketMeasuredFigures.shelfRowMayStateDuration,
                  !PocketMeasuredFigures.fastSyncOfferMayClaimSpeed,
                  !PocketMeasuredFigures.deleteMayClaimReclaimedSpace else {
                throw BrineStepError("a surface is permitted to print an unmeasured figure")
            }

        case "each withheld figure says why nobody has measured it yet":
            for figure in PocketMeasuredFigures.withheld {
                guard let reason = figure.withheldBecause, reason.count > 40 else {
                    throw BrineStepError("\(figure.id) is withheld without saying why")
                }
                guard reason.contains("Closed by:") else {
                    throw BrineStepError(
                        "\(figure.id) says why it is withheld but not what would settle it")
                }
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
