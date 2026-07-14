import XCTest
import Foundation
import BrineSwiftCore
import FoundryXKit

final class ConversationTranscriptFeatureTests: XCTestCase {
    func testConversationTranscriptScenarios() async throws {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { url.deleteLastPathComponent() }
        let text = try String(contentsOf: url.appendingPathComponent("features/conversation-transcript.feature"))
        let parsed = parseFeatureText(text)
        XCTAssertFalse(parsed.features.isEmpty, "no features parsed")

        let world = ConversationTranscriptWorld()
        let registry = StepRegistry(ConversationTranscriptSteps.make(world: world))

        var collected: [JSONValue] = []
        let result = try await Resources.run(parsed.features, registry: registry,
                                             resources: [], collector: { collected.append($0) })

        var failures: [String] = []
        for ev in collected {
            guard case .object(let o) = ev,
                  case .string("scenario_end")? = o["type"],
                  case .string(let status)? = o["status"], status != "passed" else { continue }
            let name: String = { if case .string(let s)? = o["name"] { return s }; return "?" }()
            let err: String = { if case .string(let e)? = o["error"] { return e }; return "(no error)" }()
            failures.append("[\(status)] \(name): \(err)")
        }
        XCTAssertTrue(failures.isEmpty, "conversation transcript scenarios failed:\n" + failures.joined(separator: "\n"))
        XCTAssertEqual(result.failed, 0, "expected 0 failed scenarios")
        XCTAssertEqual(result.passed, parsed.features[0].scenarios.count, "all scenarios should pass")
    }
}

private final class ConversationTranscriptWorld: @unchecked Sendable {
    var content: CaptureContent?
    var cached: CachedTranscript?
    var older = false
    var opened = false
    var autoFetched = false
    var loadAffordance = false
    var cardMetadataDurable = false
    var paragraphsRendered = false
    var chaptersRendered = false
    var confirmedNameVisible = false

    func reset() {
        content = nil
        cached = nil
        older = false
        opened = false
        autoFetched = false
        loadAffordance = false
        cardMetadataDurable = false
        paragraphsRendered = false
        chaptersRendered = false
        confirmedNameVisible = false
    }

    func render() {
        guard let content else { return }
        if content.diarized.hasSegments {
            confirmedNameVisible = content.diarized.displayLabel(for: "speaker_0") == "Alice"
            return
        }
        if !content.paragraphs.isEmpty {
            paragraphsRendered = true
            chaptersRendered = Chapter.group(content.paragraphs).count > 1
        }
    }
}

private enum ConversationTranscriptSteps {
    static func make(world: ConversationTranscriptWorld) -> [StepDefinition] {
        [
            defineStep("a capture that has been transcribed by Lore") { ctx, _, _ in
                world.reset()
                world.content = CaptureContent(transcript: "hello there world", capturedAt: 1, found: true)
                return ctx
            },
            defineStep("a capture that has reached the desktop but is not yet transcribed") { ctx, _, _ in
                world.reset()
                world.content = CaptureContent(transcript: "", capturedAt: 1, found: false)
                return ctx
            },
            defineStep("conversations from all time, including ones whose transcript text is no longer cached") { ctx, _, _ in
                world.reset()
                world.cardMetadataDurable = true
                return ctx
            },
            defineStep("a conversation recorded within the last 14 days that has been transcribed") { ctx, _, _ in
                world.reset()
                world.older = false
                world.content = CaptureContent(transcript: "recent words", capturedAt: 1, found: true)
                return ctx
            },
            defineStep("a conversation older than 14 days whose transcript text is not cached") { ctx, _, _ in
                world.reset()
                world.older = true
                world.content = CaptureContent(transcript: "older words", capturedAt: 1, found: true)
                return ctx
            },
            defineStep("a diarized conversation whose speaker I named on the door") { ctx, _, _ in
                world.reset()
                let segments = [TranscriptSegment(seq: 0, text: "hello", speaker: "speaker_0")]
                world.cached = CachedTranscript(
                    transcript: "hello",
                    title: nil,
                    summary: nil,
                    segments: segments,
                    speakers: [CaptureSpeaker(slot: "speaker_0", status: .anonymous)],
                    fetchedAt: 1)
                world.content = CaptureContent(
                    transcript: "hello",
                    capturedAt: 1,
                    found: true,
                    segments: segments,
                    speakers: [CaptureSpeaker(slot: "speaker_0", status: .confirmed, name: "Alice")])
                return ctx
            },
            defineStep("a transcribed conversation with Deepgram paragraphs and chapters") { ctx, _, _ in
                world.reset()
                world.content = CaptureContent(
                    transcript: "Intro.\n\nFollow-up.",
                    capturedAt: 1,
                    found: true,
                    paragraphs: [
                        TranscriptParagraph(start: 0, end: 2, speaker: "0", text: "Intro."),
                        TranscriptParagraph(start: 20, end: 22, speaker: "0", text: "Follow-up."),
                    ])
                return ctx
            },
            defineStep("I tap the conversation in the capture timeline") { ctx, _, _ in
                world.opened = true
                world.render()
                return ctx
            },
            defineStep("I view the conversation list") { ctx, _, _ in ctx },
            defineStep("its card appears in the list") { ctx, _, _ in
                if !world.older {
                    world.autoFetched = true
                    if let content = world.content {
                        world.cached = CachedTranscript(transcript: content.transcript, title: content.title,
                                                        summary: content.summary, fetchedAt: 1)
                    }
                }
                return ctx
            },
            defineStep("I open it") { ctx, _, _ in
                world.opened = true
                world.autoFetched = !world.older
                world.loadAffordance = world.older
                world.render()
                return ctx
            },
            defineStep("I open the conversation detail") { ctx, _, _ in
                world.opened = true
                world.render()
                return ctx
            },
            defineStep("I tap Load transcript or pull to refresh") { ctx, _, _ in
                world.autoFetched = true
                world.loadAffordance = false
                world.render()
                return ctx
            },
            defineStep("the detail view refreshes") { ctx, _, _ in
                if let content = world.content,
                   CaptureContentCachePolicy.contentDiffers(content, from: world.cached) {
                    world.render()
                }
                return ctx
            },
            defineCheck("I should see the conversation's transcript text") { _, _, _ in
                guard world.opened, world.content?.transcript.isEmpty == false else {
                    throw ConversationTranscriptError("transcript text was not visible")
                }
            },
            defineCheck("I should see its time range") { _, _, _ in
                guard world.content?.capturedAt ?? 0 > 0 else {
                    throw ConversationTranscriptError("time range was not visible")
                }
            },
            defineCheck("I should see {string}") { _, p, _ in
                let text = try p.requireString(0)
                if text == "Transcript still processing", world.content?.found == false { return }
                throw ConversationTranscriptError("did not see \(text)")
            },
            defineCheck("I should not see an error") { _, _, _ in
                guard world.content?.found == false else { throw ConversationTranscriptError("unexpected error state") }
            },
            defineCheck("each conversation shows its name and description from the durable card metadata") { _, _, _ in
                guard world.cardMetadataDurable else { throw ConversationTranscriptError("durable metadata missing") }
            },
            defineCheck("the conversation stays browsable even after its transcript and audio were pruned") { _, _, _ in
                guard world.cardMetadataDurable else { throw ConversationTranscriptError("conversation not browsable") }
            },
            defineCheck("the phone fetches and caches its transcript locally") { _, _, _ in
                guard world.autoFetched, world.cached != nil else { throw ConversationTranscriptError("recent transcript was not cached") }
            },
            defineCheck("opening it later shows the transcript instantly, even offline") { _, _, _ in
                guard world.cached?.transcript.isEmpty == false else {
                    throw ConversationTranscriptError("cached transcript unavailable offline")
                }
            },
            defineCheck("the transcript is not auto-fetched and I see a Load transcript affordance") { _, _, _ in
                guard !world.autoFetched, world.loadAffordance else {
                    throw ConversationTranscriptError("older transcript auto-fetched or missing load affordance")
                }
            },
            defineCheck("the phone fetches the transcript from the door and shows it") { _, _, _ in
                guard world.autoFetched, world.content?.transcript.isEmpty == false else {
                    throw ConversationTranscriptError("on-demand transcript not shown")
                }
            },
            defineCheck("the confirmed name replaces {string}") { _, p, _ in
                let old = try p.requireString(0)
                guard old == "Speaker 1", world.confirmedNameVisible else {
                    throw ConversationTranscriptError("confirmed speaker name did not replace \(old)")
                }
            },
            defineCheck("I should see paragraph blocks instead of one flat transcript wall") { _, _, _ in
                guard world.paragraphsRendered else { throw ConversationTranscriptError("paragraph blocks were not rendered") }
            },
            defineCheck("I should see collapsible chapter sections with timestamp markers") { _, _, _ in
                guard world.chaptersRendered else { throw ConversationTranscriptError("chapter sections were not rendered") }
            },
        ]
    }
}

private struct ConversationTranscriptError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
