import XCTest
import Foundation
import BrineSwiftCore
@testable import FoundryXKit

/// Brine driver for features/a-recording-gets-a-name-fast.feature — the REAL
/// `EarlyConversationName.offer` and the REAL `ConversationNameOnTheRow` latch.
final class EarlyConversationNameFeatureTests: XCTestCase {
    func testARecordingGetsANameFastFeature() async throws {
        try await BrineFeatureRunner.run("a-recording-gets-a-name-fast",
                                         registry: StepRegistry(EarlyNameSteps.make(world: .init())))
    }
}

private final class EarlyNameWorld: @unchecked Sendable {
    var segments: [TranscriptSegment] = []
    var paragraphs: [TranscriptParagraph] = []
    var flat: String?
    var offer: EarlyConversationName.Offer?
    var row = ConversationNameOnTheRow()
}

private enum EarlyNameSteps {

    /// Enough substantive words for the shared namer to have something to name, and the same
    /// sentence in both timed cases so a difference in the note is a difference in the CLOCK and
    /// not in the words.
    static let opening = "We should get the roof quote from Martin before Friday "
        + "because the estimate expires"

    static func make(world w: EarlyNameWorld) -> [StepDefinition] {
        [
            defineStep("a diarized transcript whose first 60 seconds are about the roof quote") { ctx, _, _ in
                w.segments = [
                    TranscriptSegment(seq: 0, startMs: 0, endMs: 20_000,
                                      text: opening, speaker: "S1"),
                    TranscriptSegment(seq: 1, startMs: 20_000, endMs: 50_000,
                                      text: "and the deposit is due the same week", speaker: "S2"),
                    // BEYOND THE WINDOW. If this leaked in, the note's seconds would be a claim
                    // about a span the window never read.
                    TranscriptSegment(seq: 2, startMs: 300_000, endMs: 320_000,
                                      text: "anyway the cat knocked the plant over again", speaker: "S1"),
                ]
                w.paragraphs = []; w.flat = nil
                return ctx
            },
            defineStep("a diarized transcript that is only 12 seconds long") { ctx, _, _ in
                w.segments = [
                    TranscriptSegment(seq: 0, startMs: 0, endMs: 12_000,
                                      text: opening, speaker: "S1"),
                ]
                w.paragraphs = []; w.flat = nil
                return ctx
            },
            defineStep("a flat transcript with no timings at all") { ctx, _, _ in
                w.segments = []; w.paragraphs = []
                w.flat = opening
                return ctx
            },
            defineStep("a transcript of three words") { ctx, _, _ in
                w.segments = []; w.paragraphs = []
                w.flat = "roof quote Friday"
                return ctx
            },
            defineStep("the recording is named early") { ctx, _, _ in
                w.offer = EarlyConversationName.offer(segments: w.segments,
                                                      paragraphs: w.paragraphs,
                                                      flat: w.flat)
                return ctx
            },

            defineCheck("it has an early name") { _, _, _ in
                guard let name = w.offer?.name, !name.isEmpty else {
                    throw BrineStepError("no early name was offered")
                }
            },
            defineCheck("it has no early name") { _, _, _ in
                if let offer = w.offer {
                    throw BrineStepError("named anyway: \(offer.name)")
                }
            },
            defineCheck("the early name is marked as early") { _, _, _ in
                guard let note = w.offer?.note, note.lowercased().contains("early") else {
                    throw BrineStepError("the note does not say the name is early: \(String(describing: w.offer?.note))")
                }
            },
            defineCheck("the note says how many seconds it read") { _, _, _ in
                guard let offer = w.offer else { throw BrineStepError("no offer") }
                guard case .seconds(let n) = offer.basis else {
                    throw BrineStepError("the basis is not a duration: \(offer.basis)")
                }
                guard offer.note.contains("\(n)") , offer.note.contains("second") else {
                    throw BrineStepError("the note does not state its seconds: \(offer.note)")
                }
                // AND THE NUMBER IS THE SPAN THE TRANSCRIPT ITSELF STATED. A note may not name a
                // duration longer than the window it actually read.
                let covered = w.segments.filter { ($0.startMs ?? 0) < 60_000 }
                    .map { $0.endMs ?? $0.startMs ?? 0 }.max() ?? 0
                let expected = EarlyConversationName.seconds(fromMilliseconds: covered)
                guard n == expected else {
                    throw BrineStepError("the note says \(n)s; the transcript covered \(expected)s")
                }
            },
            defineCheck("the note does not claim 60 seconds") { _, _, _ in
                guard let note = w.offer?.note else { throw BrineStepError("no offer") }
                if note.contains("60") {
                    throw BrineStepError("a 12-second recording claimed the whole window: \(note)")
                }
            },
            defineCheck("the note says it read the opening words") { _, _, _ in
                guard let offer = w.offer else { throw BrineStepError("no offer") }
                guard case .openingWords = offer.basis else {
                    throw BrineStepError("a clockless transcript claimed a duration: \(offer.basis)")
                }
                guard offer.note.lowercased().contains("words") else {
                    throw BrineStepError("the note does not name its basis: \(offer.note)")
                }
            },
            defineCheck("the note claims no seconds") { _, _, _ in
                guard let note = w.offer?.note else { throw BrineStepError("no offer") }
                if note.lowercased().contains("second") {
                    throw BrineStepError("a clockless transcript named seconds: \(note)")
                }
            },

            // MARK: - the row, and the one-way latch

            defineStep("a row showing an early name") { ctx, _, _ in
                w.row = ConversationNameOnTheRow()
                w.row.adopt(early: "Roof quote from Martin", settled: nil)
                return ctx
            },
            defineStep("a row showing the settled name") { ctx, _, _ in
                w.row = ConversationNameOnTheRow()
                w.row.adopt(early: "Roof quote from Martin", settled: nil)
                w.row.adopt(early: "Roof quote from Martin", settled: "Roof replacement quote")
                return ctx
            },
            defineStep("a row that has been offered neither name") { ctx, _, _ in
                w.row = ConversationNameOnTheRow()
                w.row.adopt(early: nil, settled: nil)
                return ctx
            },
            defineStep("the settled name arrives") { ctx, _, _ in
                w.row.adopt(early: "Roof quote from Martin", settled: "Roof replacement quote")
                return ctx
            },
            defineStep("a later reading carries no settled name") { ctx, _, _ in
                w.row.adopt(early: "Roof quote from Martin", settled: nil)
                return ctx
            },
            defineStep("a different early name is offered") { ctx, _, _ in
                w.row.adopt(early: "Something else entirely", settled: nil)
                return ctx
            },
            defineCheck("the row shows the settled name") { _, _, _ in
                guard w.row.name == "Roof replacement quote" else {
                    throw BrineStepError("the row shows \(String(describing: w.row.name))")
                }
            },
            defineCheck("the row still shows the settled name") { _, _, _ in
                guard w.row.name == "Roof replacement quote", !w.row.isProvisional else {
                    throw BrineStepError("the row fell back to \(String(describing: w.row.name)) provisional=\(w.row.isProvisional)")
                }
            },
            defineCheck("the row no longer marks the name as early") { _, _, _ in
                if w.row.isProvisional {
                    throw BrineStepError("the settled name is still marked early")
                }
            },
            defineCheck("the row shows no name") { _, _, _ in
                if let name = w.row.name {
                    throw BrineStepError("the row invented \(name)")
                }
            },
            defineCheck("the row does not mark a name as early") { _, _, _ in
                if w.row.isProvisional {
                    throw BrineStepError("an empty row is marked provisional")
                }
            },
        ]
    }
}
