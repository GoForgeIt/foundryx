import XCTest
import Foundation
import BrineSwiftCore
@testable import FoundryXKit

/// Drives `features/speaker-voice-sample.feature` against REAL seams:
///  • `SpeakerTranscript.voiceSampleWindow(for:)` — the LONGEST-utterance clip window
///    (nil without timestamps ⇒ no "Hear this voice" control).
///  • `DoorClient.captureAudio(captureId:startMs:endMs:)` — the windowed clip fetch,
///    exercised over a URLProtocol stub (200 ⇒ sample plays; 404 ⇒ pruned/unavailable),
///    proving the fetch is scoped to ONLY that speaker's own speaking time.
///  • `SpeakerConfirmQueue.enqueue` + `SpeakerTranscript.displayLabel` — naming applies.
///
/// GAP: the "playback stops when the tag sheet closes" scenario is NOT executed — there
/// is no FoundryXKit audio-player/sheet-lifecycle seam (playback is an AVFoundation
/// concern in the SwiftUI sheet), so it cannot be asserted honestly here. It is filtered
/// out of the run and reported by `testPlaybackStopsOnClose_unimplemented`.
final class SpeakerVoiceSampleFeatureTests: XCTestCase {

    /// The one scenario with no Kit-level seam. Surfaced as an explicit skip.
    func testPlaybackStopsOnClose_unimplemented() throws {
        throw XCTSkip("unimplemented: no FoundryXKit audio-player/sheet-lifecycle seam — " +
                      "'playback stops when the tag sheet closes' is an AVFoundation concern " +
                      "in the SwiftUI tag sheet with no model to drive.")
    }

    func testSpeakerVoiceSampleFeature() async throws {
        let world = VoiceSampleWorld()
        defer { world.cleanup() }
        let registry = StepRegistry(VoiceSampleSteps.make(world: world))

        // Run every scenario EXCEPT the un-seamed playback-stop-on-close one.
        let parsed = parseFeatureText(try Self.featureText())
        XCTAssertFalse(parsed.features.isEmpty, "no features parsed")
        var features = parsed.features
        features[0].scenarios = features[0].scenarios.filter {
            $0.name != "playback stops when the tag sheet closes"
        }

        var collected: [JSONValue] = []
        let result = try await Resources.run(features, registry: registry,
                                             resources: [], collector: { collected.append($0) })
        var failures: [String] = []
        for ev in collected {
            guard case .object(let o) = ev,
                  case .string("scenario_end")? = o["type"],
                  case .string(let status)? = o["status"], status != "passed" else { continue }
            let nm: String = { if case .string(let s)? = o["name"] { return s }; return "?" }()
            let err: String = { if case .string(let e)? = o["error"] { return e }; return "(no error)" }()
            failures.append("[\(status)] \(nm): \(err)")
        }
        XCTAssertTrue(failures.isEmpty, "speaker-voice-sample scenarios failed:\n" + failures.joined(separator: "\n"))
        XCTAssertEqual(result.failed, 0, "expected 0 failed scenarios")
        XCTAssertEqual(result.passed, features[0].scenarios.count, "all wired scenarios should pass")
    }

    private static func featureText() throws -> String {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { root.deleteLastPathComponent() }
        return try String(contentsOf: root.appendingPathComponent("features/speaker-voice-sample.feature"))
    }
}

private final class VoiceSampleWorld: @unchecked Sendable {
    var transcript: SpeakerTranscript?
    var renamed: SpeakerTranscript?
    var captureId = "cap-voice"
    var audioAvailable = true
    var openLabel: String?
    var heardLabel: String?
    var selectedWindow: (startMs: Int, endMs: Int)?
    var sampleData: Data?
    var lastRequestPath: String?
    var dir: URL

    init() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("vs-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    func cleanup() { try? FileManager.default.removeItem(at: dir) }

    func reset() {
        transcript = nil; renamed = nil; audioAvailable = true
        openLabel = nil; heardLabel = nil; selectedWindow = nil
        sampleData = nil; lastRequestPath = nil
    }

    /// "Speaker N" → the slot Nth in first-spoken order (what displayLabel shows).
    func slot(forLabel label: String) throws -> String {
        guard let t = transcript else { throw BrineStepError("no transcript seeded") }
        let digits = label.filter(\.isNumber)
        guard let n = Int(digits), n >= 1, n <= t.orderedSlots.count else {
            throw BrineStepError("no slot for label \(label) (ordered: \(t.orderedSlots))")
        }
        return t.orderedSlots[n - 1]
    }

    func firstSampleableSlot() throws -> String {
        guard let t = transcript else { throw BrineStepError("no transcript seeded") }
        for slot in t.orderedSlots where t.voiceSampleWindow(for: slot) != nil { return slot }
        throw BrineStepError("no timestamped (sampleable) slot")
    }

    func session() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: cfg)
    }

    /// Fetch the windowed clip for `slot` through the real DoorClient over the stub.
    func fetchSample(slot: String) async throws {
        guard let t = transcript else { throw BrineStepError("no transcript seeded") }
        let window = t.voiceSampleWindow(for: slot)
        selectedWindow = window
        StubURLProtocol.reset()
        let avail = audioAvailable
        StubURLProtocol.handler = { [weak self] req in
            self?.lastRequestPath = (req.url?.path ?? "") + (req.url?.query.map { "?" + $0 } ?? "")
            return avail ? (200, Data([0x4f, 0x67, 0x67, 0x53])) : (404, Data())
        }
        let client = DoorClient(
            target: DoorTarget(baseURL: URL(string: "http://door.test")!, bearer: "tok"),
            session: session())
        if let win = window {
            sampleData = try await client.captureAudio(captureId: captureId,
                                                       startMs: win.startMs, endMs: win.endMs)
        } else {
            sampleData = nil
        }
    }
}

private enum VoiceSampleSteps {
    static func make(world w: VoiceSampleWorld) -> [StepDefinition] {
        [
            defineStep("a recorded conversation with diarized speakers") { ctx, _, _ in
                w.reset()
                w.transcript = SpeakerTranscript(
                    speakers: [
                        CaptureSpeaker(slot: "speaker_0", status: .anonymous),
                        CaptureSpeaker(slot: "speaker_1", status: .anonymous),
                    ],
                    segments: [
                        TranscriptSegment(seq: 0, startMs: 0, endMs: 2_000, text: "hi", speaker: "speaker_0"),
                        TranscriptSegment(seq: 1, startMs: 5_000, endMs: 13_000,
                                          text: "this is the longer one", speaker: "speaker_1"),
                        TranscriptSegment(seq: 2, startMs: 14_000, endMs: 15_000, text: "ok", speaker: "speaker_0"),
                    ])
                return ctx
            },
            defineStep("speaker {string} has timestamped utterances") { ctx, p, _ in
                let label = try p.requireString(0)
                let slot = try w.slot(forLabel: label)
                guard w.transcript?.voiceSampleWindow(for: slot) != nil else {
                    throw BrineStepError("\(label) has no timestamped utterance")
                }
                return ctx
            },
            defineStep("a recorded conversation where {string} spoke three times") { ctx, p, _ in
                w.reset()
                _ = try p.requireString(0)   // "Speaker 1" → the only (first-spoken) slot
                w.transcript = SpeakerTranscript(
                    speakers: [CaptureSpeaker(slot: "speaker_0", status: .anonymous)],
                    segments: [
                        TranscriptSegment(seq: 0, startMs: 0, endMs: 1_000, text: "one", speaker: "speaker_0"),
                        TranscriptSegment(seq: 1, startMs: 2_000, endMs: 9_000,
                                          text: "the long middle turn", speaker: "speaker_0"),
                        TranscriptSegment(seq: 2, startMs: 10_000, endMs: 11_000, text: "three", speaker: "speaker_0"),
                    ])
                return ctx
            },
            defineStep("a recorded conversation where {string} has no utterance timestamps") { ctx, p, _ in
                w.reset()
                _ = try p.requireString(0)   // "Speaker 3" → the third slot, untimestamped
                w.transcript = SpeakerTranscript(
                    speakers: [],
                    segments: [
                        TranscriptSegment(seq: 0, startMs: 0, endMs: 1_000, text: "a", speaker: "speaker_0"),
                        TranscriptSegment(seq: 1, startMs: 2_000, endMs: 3_000, text: "b", speaker: "speaker_1"),
                        TranscriptSegment(seq: 2, text: "c", speaker: "speaker_2"),
                        TranscriptSegment(seq: 3, text: "d", speaker: "speaker_2"),
                    ])
                return ctx
            },
            defineStep("a recorded conversation whose audio has been pruned from the desktop") { ctx, _, _ in
                w.reset()
                w.audioAvailable = false   // the door /audio 404s once the desktop pruned it
                w.transcript = SpeakerTranscript(
                    speakers: [],
                    segments: [
                        TranscriptSegment(seq: 0, startMs: 0, endMs: 4_000, text: "hello", speaker: "speaker_0"),
                    ])
                return ctx
            },
            defineStep("I just heard {string}'s voice sample") { ctx, p, _ in
                w.reset()
                w.heardLabel = try p.requireString(0)
                w.transcript = SpeakerTranscript(
                    speakers: [
                        CaptureSpeaker(slot: "speaker_0", status: .anonymous),
                        CaptureSpeaker(slot: "speaker_1", status: .anonymous),
                    ],
                    segments: [
                        TranscriptSegment(seq: 0, startMs: 0, endMs: 2_000, text: "hi", speaker: "speaker_0"),
                        TranscriptSegment(seq: 1, startMs: 5_000, endMs: 12_000,
                                          text: "the sample", speaker: "speaker_1"),
                    ])
                let slot = try w.slot(forLabel: w.heardLabel!)
                try await w.fetchSample(slot: slot)
                guard w.sampleData != nil else { throw BrineStepError("sample did not play") }
                return ctx
            },
            defineStep("I open the tag sheet for {string}") { ctx, p, _ in
                w.openLabel = try p.requireString(0)
                return ctx
            },
            defineStep("I tap {string}") { ctx, p, _ in
                _ = try p.requireString(0)   // "Hear this voice"
                guard let label = w.openLabel else { throw BrineStepError("no open tag sheet") }
                try await w.fetchSample(slot: try w.slot(forLabel: label))
                return ctx
            },
            defineStep("I tap {string} for {string}") { ctx, p, _ in
                _ = try p.requireString(0)   // "Hear this voice"
                let label = try p.requireString(1)
                try await w.fetchSample(slot: try w.slot(forLabel: label))
                return ctx
            },
            defineStep("I tap {string} for a speaker") { ctx, p, _ in
                _ = try p.requireString(0)   // "Hear this voice"
                try await w.fetchSample(slot: try w.firstSampleableSlot())
                return ctx
            },
            defineStep("I enter {string} as the speaker name and save") { ctx, p, _ in
                let name = try p.requireString(0)
                guard let t = w.transcript else { throw BrineStepError("no transcript") }
                let slot = try w.slot(forLabel: w.heardLabel ?? "Speaker 2")
                // The durable confirm intent (survives a hub blip) — the real save seam.
                SpeakerConfirmQueue.enqueue(captureId: w.captureId, slot: slot, name: name, baseDir: w.dir)
                // The transcript the view re-renders after the confirm lands: that slot now
                // carries the confirmed name, so displayLabel/plainText show it.
                var speakers = t.speakers.filter { $0.slot != slot }
                speakers.append(CaptureSpeaker(slot: slot, status: .confirmed, name: name))
                w.renamed = SpeakerTranscript(speakers: speakers, segments: t.segments)
                return ctx
            },
            defineCheck("a short audio sample of {string} plays") { _, p, _ in
                _ = try p.requireString(0)
                guard let data = w.sampleData, !data.isEmpty, w.selectedWindow != nil else {
                    throw BrineStepError("no audio sample played")
                }
            },
            defineCheck("the sample covers only that speaker's own speaking time") { _, _, _ in
                guard let win = w.selectedWindow, let t = w.transcript, let label = w.openLabel else {
                    throw BrineStepError("no sample window")
                }
                let slot = try w.slot(forLabel: label)
                // The window is derived from THIS slot's own segments (never the whole recording),
                // and the fetch was scoped to that window over the wire.
                let owns = t.segments.contains {
                    $0.speaker == slot && ($0.startMs ?? -1) <= win.startMs && ($0.endMs ?? -1) >= win.startMs
                }
                guard owns else { throw BrineStepError("window \(win) is not within \(slot)'s speaking time") }
                guard let path = w.lastRequestPath,
                      path.contains("start_ms=\(win.startMs)"), path.contains("end_ms=\(win.endMs)") else {
                    throw BrineStepError("fetch was not scoped to the speaker's window: \(w.lastRequestPath ?? "nil")")
                }
            },
            defineCheck("the sample played is {string}'s longest utterance") { _, p, _ in
                let label = try p.requireString(0)
                let slot = try w.slot(forLabel: label)
                guard let win = w.selectedWindow else { throw BrineStepError("no sample window") }
                // Longest speaker_0 utterance is seq 1 (2000–9000).
                guard win.startMs == 2_000, win.endMs == 9_000 else {
                    throw BrineStepError("expected the longest utterance (2000–9000), got \(win) for \(slot)")
                }
            },
            defineCheck("there is no {string} control") { _, p, _ in
                _ = try p.requireString(0)   // "Hear this voice"
                guard let label = w.openLabel else { throw BrineStepError("no open tag sheet") }
                let slot = try w.slot(forLabel: label)
                guard w.transcript?.voiceSampleWindow(for: slot) == nil else {
                    throw BrineStepError("\(label) unexpectedly offered a voice sample")
                }
            },
            defineCheck("I see that the voice sample is unavailable") { _, _, _ in
                guard w.sampleData == nil else {
                    throw BrineStepError("expected the sample to be unavailable (pruned audio)")
                }
            },
            defineCheck("the tag sheet remains usable for naming") { _, _, _ in
                // Naming is unaffected by the missing audio: the durable confirm still records.
                let slot = try w.firstSampleableSlotOrAny()
                SpeakerConfirmQueue.enqueue(captureId: w.captureId, slot: slot, name: "Namer", baseDir: w.dir)
                guard SpeakerConfirmQueue.pending(baseDir: w.dir).contains(where: { $0.slot == slot }) else {
                    throw BrineStepError("naming path was not usable")
                }
            },
            defineCheck("the conversation shows {string} where {string} appeared") { _, p, _ in
                let name = try p.requireString(0)
                let oldLabel = try p.requireString(1)
                guard let renamed = w.renamed else { throw BrineStepError("rename not applied") }
                let slot = try w.slot(forLabel: oldLabel)
                guard renamed.displayLabel(for: slot) == name else {
                    throw BrineStepError("slot \(slot) shows \(renamed.displayLabel(for: slot)), expected \(name)")
                }
                guard SpeakerConfirmQueue.pending(baseDir: w.dir).contains(where: { $0.slot == slot && $0.name == name }) else {
                    throw BrineStepError("the confirm intent for \(name) was not durably queued")
                }
            },
        ]
    }
}

private extension VoiceSampleWorld {
    /// A slot to attach a name to when there is no sampleable slot (pruned-audio case).
    func firstSampleableSlotOrAny() throws -> String {
        if let s = try? firstSampleableSlot() { return s }
        guard let s = transcript?.orderedSlots.first else { throw BrineStepError("no slot") }
        return s
    }
}
