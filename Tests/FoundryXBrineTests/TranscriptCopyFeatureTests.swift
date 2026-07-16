import XCTest
import Foundation
import BrineSwiftCore
@testable import FoundryXKit

/// Drives `features/transcript-copy.feature` against the REAL copy seam:
/// `CaptureContent.diarized.plainText` (labelled speaker turns in spoken order) for a
/// diarized conversation, and the flat `CaptureContent.transcript` otherwise — the exact
/// flat-vs-labelled decision the detail view makes when the user taps Copy. Hermetic:
/// no pasteboard, no network — the assertions are on the STRING the copy-builder yields.
final class TranscriptCopyFeatureTests: XCTestCase {
    func testTranscriptCopyFeature() async throws {
        let world = TranscriptCopyWorld()
        try await BrineFeatureRunner.run("transcript-copy",
                                         registry: StepRegistry(TranscriptCopySteps.make(world: world)))
    }
}

private final class TranscriptCopyWorld: @unchecked Sendable {
    var content: CaptureContent?
    var copied: String?
    var copyOffered: Bool?

    func reset() { content = nil; copied = nil; copyOffered = nil }

    /// What the Copy action puts on the clipboard: labelled speaker turns for a diarized
    /// conversation (`plainText`), else the flat transcript. Mirrors the detail view's
    /// branch; both sides are REAL FoundryXKit outputs.
    static func copyText(_ c: CaptureContent) -> String {
        c.diarized.hasSegments ? c.diarized.plainText : c.transcript
    }

    /// The Copy affordance is only offered once there is transcript text to copy.
    static func copyOffered(_ c: CaptureContent) -> Bool {
        guard c.found else { return false }
        return !copyText(c).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

private enum TranscriptCopySteps {
    static func make(world w: TranscriptCopyWorld) -> [StepDefinition] {
        [
            defineStep("a conversation whose transcript has no speaker labels") { ctx, _, _ in
                w.reset()
                w.content = CaptureContent(transcript: "the whole thing, plainly, with no speakers",
                                           capturedAt: 1, found: true)
                return ctx
            },
            defineStep("a conversation with two identified speakers") { ctx, _, _ in
                w.reset()
                let segments = [
                    TranscriptSegment(seq: 0, text: "Hey, did it work?", speaker: "speaker_0"),
                    TranscriptSegment(seq: 1, text: "Yeah, all green.", speaker: "speaker_1"),
                    TranscriptSegment(seq: 2, text: "Nice.", speaker: "speaker_0"),
                ]
                w.content = CaptureContent(
                    transcript: "Hey, did it work? Yeah, all green. Nice.",
                    capturedAt: 1, found: true,
                    segments: segments,
                    speakers: [
                        CaptureSpeaker(slot: "speaker_0", status: .confirmed, name: "Alice"),
                        CaptureSpeaker(slot: "speaker_1", status: .confirmed, name: "Bob"),
                    ])
                return ctx
            },
            defineStep("a conversation whose transcript has not loaded yet") { ctx, _, _ in
                w.reset()
                // The door 404s with {found:false} until Lore has transcribed it.
                w.content = CaptureContent(transcript: "", capturedAt: 0, found: false)
                return ctx
            },
            defineStep("I copy the transcript") { ctx, _, _ in
                guard let c = w.content else { throw BrineStepError("no conversation seeded") }
                w.copied = TranscriptCopyWorld.copyText(c)
                return ctx
            },
            defineStep("I open the conversation") { ctx, _, _ in
                guard let c = w.content else { throw BrineStepError("no conversation seeded") }
                w.copyOffered = TranscriptCopyWorld.copyOffered(c)
                return ctx
            },
            defineCheck("the clipboard holds the full transcript text") { _, _, _ in
                guard let c = w.content, let copied = w.copied else { throw BrineStepError("nothing copied") }
                guard copied == c.transcript, !copied.isEmpty else {
                    throw BrineStepError("flat copy was not the full transcript text: \(copied)")
                }
            },
            defineCheck("the clipboard holds each speaker turn labelled by speaker") { _, _, _ in
                guard let c = w.content, let copied = w.copied else { throw BrineStepError("nothing copied") }
                guard copied == c.diarized.plainText else {
                    throw BrineStepError("copy did not match the labelled plainText: \(copied)")
                }
                guard copied.contains("Alice: Hey, did it work?"),
                      copied.contains("Bob: Yeah, all green.") else {
                    throw BrineStepError("turns were not labelled by speaker: \(copied)")
                }
            },
            defineCheck("the turns are in spoken order") { _, _, _ in
                guard let copied = w.copied,
                      let firstAlice = copied.range(of: "Alice:"),
                      let bob = copied.range(of: "Bob:"),
                      let lastAlice = copied.range(of: "Alice:", options: .backwards) else {
                    throw BrineStepError("could not locate speaker turns")
                }
                // seq 0 (Alice) → seq 1 (Bob) → seq 2 (Alice): spoken order preserved.
                guard firstAlice.lowerBound < bob.lowerBound, bob.lowerBound < lastAlice.lowerBound else {
                    throw BrineStepError("turns were not in spoken order: \(w.copied ?? "")")
                }
            },
            defineCheck("I am not offered a copy action") { _, _, _ in
                guard w.copyOffered == false else {
                    throw BrineStepError("a copy action was offered with no transcript loaded")
                }
            },
        ]
    }
}
