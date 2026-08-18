import XCTest
import Foundation
import BrineSwiftCore
@testable import FoundryXKit

/// Brine driver for features/a-recording-says-what-is-happening-to-it.feature.
///
/// Every step drives the REAL `CaptureJourney.build` and the REAL `JourneyFigure` — there is no
/// parallel model in this file. The two population scenarios ("every journey this app can build",
/// "every way the surfaced step can end") are the ones that matter most: they hold the claim over
/// the whole set rather than over the spellings a test author happened to think of, which is the
/// failure mode this surface's three invented numbers all shared.
final class CaptureJourneyFeatureTests: XCTestCase {
    func testARecordingSaysWhatIsHappeningToItFeature() async throws {
        try await BrineFeatureRunner.run("a-recording-says-what-is-happening-to-it",
                                         registry: StepRegistry(CaptureJourneySteps.make(world: .init())))
    }
}

private final class JourneyWorld: @unchecked Sendable {
    var journey = CaptureJourney(steps: [])
    /// The step the scenario is talking about when it says "that step".
    var focus: CaptureJourney.Phase = .offTheRecorder
    /// The whole population, for the two scenarios that quantify over it.
    var population: [CaptureJourney] = []
    var readings: [AmbientReading] = []

    var focusStep: CaptureJourney.Step? { journey.step(focus) }

    /// Every sentence a journey puts in front of a person: titles, figure lines and details.
    var everySentence: [String] {
        journey.steps.flatMap { [$0.title, $0.figure.line, $0.detail ?? ""] }
    }
}

private enum CaptureJourneySteps {

    /// The cross-product every "every journey this app can build" claim is held over. It is built
    /// from the axes that can produce a figure at all — a claim about percentages that skipped a
    /// destination or a stream state would be a claim about the half of the space the author
    /// remembered.
    static func everyJourney() -> [CaptureJourney] {
        var out: [CaptureJourney] = []
        // EVERY WAY A TRANSFER CAN BE KNOWN — including `.arrived`, the state whose absence from
        // the first version of this population let a completed transfer render as "waiting"
        // forever on every recording that had already come over.
        let transfers: [RecorderTransfer] = [
            .none,
            .arrived,
            .measured(PullReading(delivered: 0, announced: 1_000_000, finished: false)),
            .measured(PullReading(delivered: 250_000, announced: 1_000_000, finished: false)),
            .measured(PullReading(delivered: 1_000_000, announced: 1_000_000, finished: true)),
            .measured(PullReading(delivered: 250_000, announced: nil, finished: false)),
            .measured(PullReading(delivered: 4_000, announced: 1_000, finished: false)),
            .measured(PullReading(delivered: 5, announced: 0, finished: false)),
        ]
        for destination in CaptureDestination.allCases {
            for wal in [CaptureStage.recording, .savedOnPhone, .savedToComputer] {
                for streaming in [true, false] {
                    for (total, synced) in [(0, 0), (40, 0), (40, 12), (40, 40), (40, 41)] {
                        for door in [CaptureLifecycleStage.stored, .transcribing, .inLore,
                                     .transcribed, .organized, .failed] {
                            for ambient in AmbientReading.everyReading {
                                for transfer in transfers {
                                    out.append(CaptureJourney.build(CaptureJourneyReading(
                                        transfer: transfer,
                                        wal: wal,
                                        streaming: streaming,
                                        totalSegments: total,
                                        syncedSegments: synced,
                                        destination: destination,
                                        door: door,
                                        transcribed: door == .transcribed || door == .organized,
                                        hasTranscript: door == .transcribed || door == .organized,
                                        separatedSpeakers: door == .organized ? 3 : 0,
                                        summarizing: door == .inLore,
                                        hasSummary: door == .organized,
                                        ambient: ambient,
                                        droppedReason: door == .failed ? "noise" : nil)))
                                }
                            }
                        }
                    }
                }
            }
        }
        return out
    }

    static func make(world w: JourneyWorld) -> [StepDefinition] {
        [
            // MARK: - transfer off the recorder

            defineStep("a recorder announced 1,000,000 bytes and 250,000 have arrived") { ctx, _, _ in
                w.focus = .offTheRecorder
                w.journey = CaptureJourney.build(CaptureJourneyReading(
                    transfer: .measured(
                        PullReading(delivered: 250_000, announced: 1_000_000, finished: false)),
                    destination: .vault))
                return ctx
            },
            defineStep("a transfer with 250,000 bytes arrived and no announced total") { ctx, _, _ in
                w.focus = .offTheRecorder
                w.journey = CaptureJourney.build(CaptureJourneyReading(
                    transfer: .measured(
                        PullReading(delivered: 250_000, announced: nil, finished: false)),
                    destination: .vault))
                return ctx
            },
            defineStep("a recorder announced 1,000 bytes and 4,000 have arrived") { ctx, _, _ in
                w.focus = .offTheRecorder
                w.journey = CaptureJourney.build(CaptureJourneyReading(
                    transfer: .measured(
                        PullReading(delivered: 4_000, announced: 1_000, finished: false)),
                    destination: .vault))
                return ctx
            },
            defineCheck("the journey shows how far the transfer has got") { _, _, _ in
                guard let f = w.focusStep?.figure.fraction else {
                    throw BrineStepError("the transfer step has no fraction at all")
                }
                guard abs(f - 0.25) < 0.0001 else {
                    throw BrineStepError("250,000 of 1,000,000 read as \(f), not a quarter")
                }
            },

            // MARK: - segments to the second place

            defineStep("a recording that is still being written to, with 12 of 40 segments acknowledged") { ctx, _, _ in
                w.focus = .secondPlace
                w.journey = CaptureJourney.build(CaptureJourneyReading(
                    wal: .recording, streaming: true,
                    totalSegments: 40, syncedSegments: 12, destination: .vault))
                return ctx
            },
            defineStep("a finished recording with 40 of 40 segments acknowledged") { ctx, _, _ in
                w.focus = .secondPlace
                w.journey = CaptureJourney.build(CaptureJourneyReading(
                    wal: .savedToComputer, streaming: false,
                    totalSegments: 40, syncedSegments: 40, destination: .vault))
                return ctx
            },
            defineCheck("the step for the place this account saves to shows no bar") { _, _, _ in
                guard let step = w.journey.step(.secondPlace) else {
                    throw BrineStepError("there is no second-place step to check")
                }
                if step.figure.showsBar {
                    throw BrineStepError("a growing denominator drew a bar: \(step.figure.line)")
                }
            },
            defineCheck("the step for the place this account saves to shows a bar") { _, _, _ in
                guard let step = w.journey.step(.secondPlace) else {
                    throw BrineStepError("there is no second-place step to check")
                }
                if !step.figure.showsBar {
                    throw BrineStepError("a settled denominator drew no bar: \(step.figure.line)")
                }
            },

            // MARK: - the shared figure checks

            defineCheck("that step shows a bar") { _, _, _ in
                guard let step = w.focusStep else { throw BrineStepError("no step in focus") }
                if !step.figure.showsBar {
                    throw BrineStepError("\(step.phase) drew no bar: \(step.figure.line)")
                }
            },
            defineCheck("that step shows no bar") { _, _, _ in
                guard let step = w.focusStep else { throw BrineStepError("no step in focus") }
                if step.figure.showsBar {
                    throw BrineStepError("\(step.phase) drew a bar: \(step.figure.line)")
                }
            },
            defineCheck("that step's line carries no percentage") { _, _, _ in
                guard let step = w.focusStep else { throw BrineStepError("no step in focus") }
                if step.figure.line.contains("%") || step.figure.percentText != nil {
                    throw BrineStepError("\(step.phase) printed a percentage: \(step.figure.line)")
                }
            },
            defineCheck("that step's line names both numbers") { _, _, _ in
                guard let step = w.focusStep else { throw BrineStepError("no step in focus") }
                guard step.figure.line.contains(" of ") else {
                    throw BrineStepError("\(step.phase) named one number: \(step.figure.line)")
                }
            },

            // MARK: - a transfer that already happened, and one that never did

            defineStep("a recording whose file is already on this phone, with no transfer ever measured") { ctx, _, _ in
                w.focus = .offTheRecorder
                w.journey = CaptureJourney.build(CaptureJourneyReading(
                    transfer: .arrived, wal: .savedToComputer,
                    totalSegments: 4, syncedSegments: 4, destination: .vault))
                return ctx
            },
            defineStep("a recording this phone made with its own microphone") { ctx, _, _ in
                w.journey = CaptureJourney.build(CaptureJourneyReading(
                    transfer: .none, wal: .savedToComputer,
                    totalSegments: 4, syncedSegments: 4, destination: .vault))
                return ctx
            },
            defineCheck("the step for coming off the recorder is marked done") { _, _, _ in
                guard w.journey.step(.offTheRecorder)?.state == .done else {
                    throw BrineStepError(
                        "a finished transfer reads as \(String(describing: w.journey.step(.offTheRecorder)?.state))")
                }
            },
            defineCheck("that step's line names no number") { _, _, _ in
                let line = w.focusStep?.figure.line ?? "?"
                guard line.isEmpty else {
                    throw BrineStepError("a number was produced after the fact: \(line)")
                }
            },
            defineCheck("the journey has no step for coming off a recorder") { _, _, _ in
                if w.journey.step(.offTheRecorder) != nil {
                    throw BrineStepError("a phone recording was given a transfer step")
                }
            },

            // MARK: - the population

            defineStep("every journey this app can build") { ctx, _, _ in
                w.population = everyJourney()
                return ctx
            },
            defineCheck("a step shows a percentage only when it holds a settled denominator") { _, _, _ in
                guard w.population.count > 500 else {
                    throw BrineStepError("the population is too small to be a population: \(w.population.count)")
                }
                for journey in w.population {
                    for step in journey.steps {
                        let printed = step.figure.line.contains("%")
                            || step.figure.percentText != nil
                        if printed != (step.figure.total != nil) {
                            throw BrineStepError(
                                "\(step.phase): percentage=\(printed) but denominator=\(String(describing: step.figure.total)) — \(step.figure.line)")
                        }
                        // AND NO SENTENCE ANYWHERE ELSE ON THE STEP SMUGGLES ONE IN.
                        if (step.detail ?? "").contains("%") {
                            throw BrineStepError("\(step.phase) put a percentage in its detail: \(step.detail ?? "")")
                        }
                    }
                }
            },
            defineCheck("a step shows a bar only when it holds a settled denominator") { _, _, _ in
                for journey in w.population {
                    for step in journey.steps where step.figure.showsBar != (step.figure.total != nil) {
                        throw BrineStepError(
                            "\(step.phase): bar=\(step.figure.showsBar) denominator=\(String(describing: step.figure.total))")
                    }
                }
                // Transcription and summarizing have no denominator on this seam AT ANY TIME.
                for journey in w.population {
                    for step in journey.steps
                    where step.phase == .transcript || step.phase == .summary {
                        if step.figure.showsBar || !step.figure.isLabelOnly {
                            throw BrineStepError("\(step.phase) acquired a figure: \(step.figure.line)")
                        }
                    }
                }
            },

            // MARK: - transcription and summarizing are labels

            defineStep("a recording that has reached the place it is saved and is being transcribed") { ctx, _, _ in
                w.focus = .transcript
                w.journey = CaptureJourney.build(CaptureJourneyReading(
                    wal: .savedToComputer, totalSegments: 40, syncedSegments: 40,
                    destination: .vault, door: .transcribing))
                return ctx
            },
            defineStep("a recording whose transcript exists and whose summary is being written") { ctx, _, _ in
                w.focus = .summary
                w.journey = CaptureJourney.build(CaptureJourneyReading(
                    wal: .savedToComputer, totalSegments: 40, syncedSegments: 40,
                    destination: .vault, door: .inLore, transcribed: true,
                    hasTranscript: true, summarizing: true))
                return ctx
            },
            defineCheck("the transcript step is marked as working") { _, _, _ in
                guard w.journey.step(.transcript)?.state == .working else {
                    throw BrineStepError("transcript step is \(String(describing: w.journey.step(.transcript)?.state))")
                }
            },
            defineCheck("the transcript step shows no bar") { _, _, _ in
                if w.journey.step(.transcript)?.figure.showsBar == true {
                    throw BrineStepError("the transcript step drew a bar")
                }
            },
            defineCheck("the transcript step's line carries no percentage") { _, _, _ in
                let step = w.journey.step(.transcript)
                if (step?.figure.line.contains("%") ?? false) || (step?.detail ?? "").contains("%") {
                    throw BrineStepError("the transcript step printed a percentage")
                }
            },
            defineCheck("the summary step is marked as working") { _, _, _ in
                guard w.journey.step(.summary)?.state == .working else {
                    throw BrineStepError("summary step is \(String(describing: w.journey.step(.summary)?.state))")
                }
            },
            defineCheck("the summary step shows no bar") { _, _, _ in
                if w.journey.step(.summary)?.figure.showsBar == true {
                    throw BrineStepError("the summary step drew a bar")
                }
            },

            // MARK: - the tier

            defineStep("a recording on the phone-only tier") { ctx, _, _ in
                w.journey = CaptureJourney.build(CaptureJourneyReading(
                    wal: .savedOnPhone, totalSegments: 9, syncedSegments: 9,
                    destination: .phone))
                return ctx
            },
            defineStep("a recording saved to a Vault") { ctx, _, _ in
                w.focus = .secondPlace
                w.journey = CaptureJourney.build(CaptureJourneyReading(
                    wal: .savedToComputer, totalSegments: 9, syncedSegments: 9,
                    destination: .vault))
                return ctx
            },
            defineCheck("the journey has no step for a second place") { _, _, _ in
                if w.journey.step(.secondPlace) != nil {
                    throw BrineStepError("the phone-only tier was given a second place")
                }
            },
            defineCheck("the journey has a step for a second place") { _, _, _ in
                if w.journey.step(.secondPlace) == nil {
                    throw BrineStepError("no second-place step")
                }
            },
            defineCheck("no step names a computer") { _, _, _ in
                for s in w.everySentence where s.lowercased().contains("computer") {
                    throw BrineStepError("a step named a computer: \(s)")
                }
            },
            defineCheck("no step names a Vault") { _, _, _ in
                for s in w.everySentence where s.lowercased().contains("vault") {
                    throw BrineStepError("a step named a Vault: \(s)")
                }
            },
            defineCheck("that step names the Vault") { _, _, _ in
                guard w.journey.step(.secondPlace)?.title.contains("Vault") == true else {
                    throw BrineStepError("the second place did not name the Vault")
                }
            },

            // MARK: - speakers

            defineStep("a transcribed recording whose reply carried 3 separated speakers") { ctx, _, _ in
                w.journey = CaptureJourney.build(CaptureJourneyReading(
                    wal: .savedToComputer, totalSegments: 9, syncedSegments: 9,
                    destination: .vault, door: .transcribed, transcribed: true,
                    hasTranscript: true, separatedSpeakers: 3))
                return ctx
            },
            defineStep("a transcribed recording whose reply carried no separated speakers") { ctx, _, _ in
                w.journey = CaptureJourney.build(CaptureJourneyReading(
                    wal: .savedToComputer, totalSegments: 9, syncedSegments: 9,
                    destination: .vault, door: .transcribed, transcribed: true,
                    hasTranscript: true, separatedSpeakers: 0))
                return ctx
            },
            defineCheck("the transcript step says how many speakers were separated") { _, _, _ in
                guard let detail = w.journey.step(.transcript)?.detail,
                      detail.contains("3"), detail.lowercased().contains("speaker") else {
                    throw BrineStepError("no speaker count: \(String(describing: w.journey.step(.transcript)?.detail))")
                }
            },
            defineCheck("no step says anything about speakers") { _, _, _ in
                for s in w.everySentence where s.lowercased().contains("speaker") {
                    throw BrineStepError("an empty speaker list produced a claim: \(s)")
                }
            },

            // MARK: - did anything come out of it

            defineStep("a recording with no transcript yet") { ctx, _, _ in
                w.journey = CaptureJourney.build(CaptureJourneyReading(
                    destination: .vault,
                    ambient: AmbientReading.reading(hasTranscript: false, decisions: [], surfaced: 0)))
                return ctx
            },
            defineStep("a transcribed recording the gate read and found nothing in") { ctx, _, _ in
                w.journey = CaptureJourney.build(CaptureJourneyReading(
                    destination: .vault, door: .transcribed, transcribed: true, hasTranscript: true,
                    ambient: AmbientReading.reading(
                        hasTranscript: true,
                        decisions: [decision(.gatedNo, reason: nil)],
                        surfaced: 0)))
                return ctx
            },
            defineStep("a transcribed recording the gate could not read") { ctx, _, _ in
                w.journey = CaptureJourney.build(CaptureJourneyReading(
                    destination: .vault, door: .transcribed, transcribed: true, hasTranscript: true,
                    ambient: AmbientReading.reading(
                        hasTranscript: true,
                        decisions: [decision(.skipped, reason: "gate_unavailable")],
                        surfaced: 0)))
                return ctx
            },
            defineStep("a transcribed recording that surfaced 2 items") { ctx, _, _ in
                w.journey = CaptureJourney.build(CaptureJourneyReading(
                    destination: .vault, door: .transcribed, transcribed: true, hasTranscript: true,
                    ambient: AmbientReading.reading(hasTranscript: true, decisions: [], surfaced: 2)))
                return ctx
            },
            defineCheck("the surfaced step says nothing has been read yet") { _, _, _ in
                let detail = w.journey.step(.surfaced)?.detail ?? ""
                guard detail == AmbientReading.noTranscriptYet.line else {
                    throw BrineStepError("wrong sentence: \(detail)")
                }
            },
            defineCheck("the surfaced step says it was read and nothing was found") { _, _, _ in
                let detail = w.journey.step(.surfaced)?.detail ?? ""
                guard detail == AmbientReading.readAndFoundNothing.line else {
                    throw BrineStepError("wrong sentence: \(detail)")
                }
            },
            defineCheck("the surfaced step says it could not be read") { _, _, _ in
                let detail = w.journey.step(.surfaced)?.detail ?? ""
                guard detail == AmbientReading.couldNotRead("gate_unavailable").line else {
                    throw BrineStepError("wrong sentence: \(detail)")
                }
            },
            defineCheck("the surfaced step does not say nothing was found") { _, _, _ in
                let detail = w.journey.step(.surfaced)?.detail ?? ""
                if detail == AmbientReading.readAndFoundNothing.line {
                    throw BrineStepError("a failure was reported as an empty result")
                }
            },
            defineCheck("the surfaced step is marked done") { _, _, _ in
                guard w.journey.step(.surfaced)?.state == .done else {
                    throw BrineStepError("surfaced step is \(String(describing: w.journey.step(.surfaced)?.state))")
                }
            },
            defineCheck("the surfaced step is not marked done") { _, _, _ in
                if w.journey.step(.surfaced)?.state == .done {
                    throw BrineStepError("an unread recording was marked done")
                }
            },
            defineCheck("the surfaced step counts 2 items") { _, _, _ in
                let figure = w.journey.step(.surfaced)?.figure
                guard figure?.done == 2, figure?.line.contains("2 items") == true else {
                    throw BrineStepError("wrong count: \(String(describing: figure?.line))")
                }
            },

            // MARK: - the five endings

            defineStep("every way the surfaced step can end") { ctx, _, _ in
                w.readings = AmbientReading.everyReading
                return ctx
            },
            defineCheck("no two of them read the same") { _, _, _ in
                let lines = w.readings.map(\.line)
                guard Set(lines).count == lines.count else {
                    throw BrineStepError("two readings share a sentence: \(lines)")
                }
                guard lines.count == 5 else {
                    throw BrineStepError("the population is \(lines.count), not the five endings")
                }
            },
            defineCheck("only the ones where more may still happen say \"yet\"") { _, _, _ in
                for reading in w.readings {
                    let saysYet = reading.line.lowercased().contains("yet")
                    if saysYet != reading.moreMayHappen {
                        throw BrineStepError("\(reading): says-yet=\(saysYet) more-may-happen=\(reading.moreMayHappen) — \(reading.line)")
                    }
                }
            },
        ]
    }

    private static func decision(_ outcome: AmbientDecision.Outcome,
                                 reason: String?) -> AmbientDecision {
        AmbientDecision(ts: 1, captureId: "c", windowChars: 100, outcome: outcome,
                        candidate: nil, skipReason: reason, latencyMs: 1)
    }
}
