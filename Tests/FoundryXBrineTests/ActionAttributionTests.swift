import XCTest
import Foundation
import BrineSwiftCore
@testable import FoundryXKit

/// Actions know who said them (features/action-speaker-attribution.feature):
/// every surfaced action is attributed against the diarized transcript
/// ("You said" / "<name> said" / "Unknown speaker"), the main list holds only
/// owner-uttered actions by default, others-uttered ones collect under a
/// collapsed "Heard from others" group the user can expand and promote, and
/// feedback records carry the speaker so the router learns the distinction.
///
/// The steps drive the REAL kit pieces the views render from — the decision
/// log (AmbientLane.readDecisions wire shape), TranscriptCacheStore-shaped
/// diarization (SpeakerTranscript), ActionPromotionStore, ActionFeedbackStore,
/// and ConversationActionsPresentation.build — file-backed in a temp dir, so
/// "rebuilt from disk" is a genuine re-read.
final class ActionAttributionFeatureTests: XCTestCase {
    func testActionSpeakerAttributionScenarios() async throws {
        let world = AttributionWorld()
        try await BrineFeatureRunner.run(
            "action-speaker-attribution",
            registry: StepRegistry(AttributionSteps.make(world: world)))
    }
}

// MARK: - World

private final class AttributionWorld: @unchecked Sendable {
    let captureId = "conv-attr-1"
    let utterance = "Remind me to send Sarah the numbers section tonight"
    let summary = "Set a reminder to send Sarah the numbers section tonight"

    var dir: URL!
    /// The diarized transcript as the phone currently knows it (nil = not landed).
    var transcript: SpeakerTranscript?
    /// The "Actions from others" toggle (default OFF = owner-first).
    var othersInline = false
    /// The last built presentation (What "I look at the conversation's actions" produced).
    var presentation: ConversationActionsPresentation?

    func reset() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("foundryx-attribution-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        transcript = nil
        othersInline = false
        presentation = nil
        try writeCandidate()
    }

    var decisionsURL: URL { dir.appendingPathComponent("ambient-decisions.jsonl") }

    /// A decision-log line exactly as AmbientLane writes it.
    func writeCandidate() throws {
        let line = """
        {"ts":100,"captureId":"\(captureId)","windowChars":480,"outcome":"candidate","candidate":{"utterance":"\(utterance)","summary":"\(summary)","confidence":0.86},"latencyMs":210}
        """
        try (line + "\n").write(to: decisionsURL, atomically: true, encoding: .utf8)
    }

    /// Diarization "lands": the surfaced line spoken by `speakerName` (nil name
    /// = an unnamed voice), alongside a second speaker so slots are realistic.
    /// `withOwnerIdentified` adds a DIFFERENT slot confirmed as the owner.
    func landDiarization(lineSpokenBy speakerName: String?,
                         status: SpeakerStatus = .confirmed,
                         withOwnerIdentified: Bool = false,
                         lineText: String? = nil) {
        var segments = [
            TranscriptSegment(seq: 0, startMs: 0, endMs: 4_000,
                              text: "Okay let's walk the launch plan.",
                              speaker: "speaker_0"),
            TranscriptSegment(seq: 1, startMs: 4_500, endMs: 11_000,
                              text: lineText ?? utterance, speaker: "speaker_1"),
        ]
        var speakers: [CaptureSpeaker] = [
            CaptureSpeaker(slot: "speaker_0", status: .anonymous),
            speakerName.map {
                CaptureSpeaker(slot: "speaker_1", status: status, name: $0,
                               confirmedSpeakerId: "sp-\($0)")
            } ?? CaptureSpeaker(slot: "speaker_1", status: .anonymous),
        ]
        if withOwnerIdentified {
            segments.append(TranscriptSegment(
                seq: 2, startMs: 12_000, endMs: 16_000,
                text: "Sounds good, I will take the rest of the deck.",
                speaker: "speaker_2"))
            speakers.append(CaptureSpeaker(
                slot: "speaker_2", status: .confirmed, name: "Nick Rinard (me)",
                confirmedSpeakerId: "sp-owner"))
        }
        transcript = SpeakerTranscript(speakers: speakers, segments: segments)
    }

    /// The exact build the app's shared ActionFeedbackFlow performs.
    func build() {
        presentation = ConversationActionsPresentation.build(
            captureId: captureId,
            decisions: AmbientLane.readDecisions(at: decisionsURL),
            outcomes: [],
            answers: [],
            userActions: [],
            feedback: ActionFeedbackStore.load(captureId: captureId, baseDir: dir),
            transcript: transcript,
            othersInline: othersInline,
            promotions: ActionPromotionStore.promoted(baseDir: dir))
    }

    func surfacedRow() throws -> ConversationActionsPresentation.Row {
        guard let p = presentation else { throw BrineStepError("actions never built") }
        if let row = (p.rows + p.othersRows).first(where: { $0.kind == .surfaced }) {
            return row
        }
        throw BrineStepError("no surfaced action row anywhere")
    }
}

// MARK: - Steps

private enum AttributionSteps {
    static func make(world w: AttributionWorld) -> [StepDefinition] {
        [
            // MARK: Givens

            defineStep("a conversation where the transcript attributes the surfaced line to me") { ctx, _, _ in
                try w.reset()
                w.landDiarization(lineSpokenBy: "Nick Rinard (me)")
                return ctx
            },
            defineStep("a conversation where the transcript attributes the surfaced line to {string}") { ctx, p, _ in
                try w.reset()
                w.landDiarization(lineSpokenBy: try p.requireString(0))
                return ctx
            },
            defineStep("a conversation where the transcript tentatively attributes the surfaced line to {string}") { ctx, p, _ in
                try w.reset()
                w.landDiarization(lineSpokenBy: try p.requireString(0), status: .inferred)
                return ctx
            },
            defineStep("a conversation where I am identified and an unnamed voice said the surfaced line") { ctx, _, _ in
                try w.reset()
                w.landDiarization(lineSpokenBy: nil, withOwnerIdentified: true)
                return ctx
            },
            defineStep("a conversation where nobody is identified and an unnamed voice said the surfaced line") { ctx, _, _ in
                try w.reset()
                w.landDiarization(lineSpokenBy: nil)
                return ctx
            },
            defineStep("a conversation whose speakers are not identified yet") { ctx, _, _ in
                try w.reset()
                w.transcript = nil   // no diarization landed at all
                return ctx
            },
            defineStep("a conversation with identified speakers whose transcript does not contain the surfaced line") { ctx, _, _ in
                try w.reset()
                w.landDiarization(
                    lineSpokenBy: "Sarah", withOwnerIdentified: true,
                    lineText: "Completely different words about the venue budget approvals")
                return ctx
            },
            defineStep("an action from {string} sits under \"Heard from others\"") { ctx, p, _ in
                try w.reset()
                w.landDiarization(lineSpokenBy: try p.requireString(0))
                w.build()
                guard let pres = w.presentation,
                      pres.othersRows.contains(where: { $0.kind == .surfaced }) else {
                    throw BrineStepError("expected the action under Heard from others")
                }
                return ctx
            },

            // MARK: Whens

            defineStep("I look at the conversation's actions") { ctx, _, _ in
                w.build()
                return ctx
            },
            defineStep("the transcript later attributes the surfaced line to {string}") { ctx, p, _ in
                w.landDiarization(lineSpokenBy: try p.requireString(0))
                return ctx
            },
            defineStep("I promote it to my actions") { ctx, _, _ in
                let row = try w.surfacedRow()
                guard let utterance = row.utterance else {
                    throw BrineStepError("surfaced row lost its utterance")
                }
                // What the sheet's "Move to my actions" does.
                ActionPromotionStore.promote(captureId: w.captureId,
                                             utterance: utterance, baseDir: w.dir)
                w.build()
                return ctx
            },
            defineStep("I turn on \"Actions from others\"") { ctx, _, _ in
                w.othersInline = true
                w.build()
                return ctx
            },
            defineStep("I mark it as not an action") { ctx, _, _ in
                // What ActionFeedbackFlow.record persists on "Not an action" —
                // including the row's attribution at feedback time.
                if w.presentation == nil { w.build() }
                let row = try w.surfacedRow()
                guard let utterance = row.utterance else {
                    throw BrineStepError("surfaced row lost its utterance")
                }
                ActionFeedbackStore.append(
                    ActionFeedbackRecord(captureId: w.captureId,
                                         utterance: utterance, summary: row.label,
                                         kind: .rejected, comment: "",
                                         speaker: row.attribution?.wire,
                                         speakerName: row.attribution?.speakerName),
                    baseDir: w.dir)
                return ctx
            },

            // MARK: Thens

            defineCheck("the action appears in my actions") { _, _, _ in
                if w.presentation == nil { w.build() }   // usable as a Given precondition
                guard let p = w.presentation else { throw BrineStepError("actions never built") }
                guard p.rows.contains(where: { $0.kind == .surfaced }) else {
                    throw BrineStepError(
                        "expected the surfaced action in the MAIN list; main=\(p.rows.map(\.label)) others=\(p.othersRows.map(\.label))")
                }
            },
            defineCheck("the action is not in my actions") { _, _, _ in
                guard let p = w.presentation else { throw BrineStepError("actions never built") }
                if p.rows.contains(where: { $0.kind == .surfaced }) {
                    throw BrineStepError("the surfaced action should NOT be in the main list")
                }
            },
            defineCheck("it appears under \"Heard from others\"") { _, _, _ in
                guard let p = w.presentation else { throw BrineStepError("actions never built") }
                guard p.othersRows.contains(where: { $0.kind == .surfaced }) else {
                    throw BrineStepError("expected the action under Heard from others")
                }
            },
            defineCheck("its attribution reads {string}") { _, p, _ in
                let expected = try p.requireString(0)
                let row = try w.surfacedRow()
                let got = row.attribution?.displayText ?? "(no attribution)"
                guard got == expected else {
                    throw BrineStepError("attribution reads \"\(got)\", expected \"\(expected)\"")
                }
            },
            defineCheck("it stays in my actions when the actions are rebuilt from disk") { _, _, _ in
                w.build()   // a genuine re-read: promotions + feedback come from files
                guard let p = w.presentation,
                      p.rows.contains(where: { $0.kind == .surfaced }) else {
                    throw BrineStepError("promotion did not survive the rebuild")
                }
            },
            defineCheck("the recorded feedback carries the speaker {string}, not me") { _, p, _ in
                let name = try p.requireString(0)
                let records = ActionFeedbackStore.load(baseDir: w.dir)
                guard let last = records.last else { throw BrineStepError("no feedback recorded") }
                guard last.speaker == "other", last.speakerName == name else {
                    throw BrineStepError(
                        "feedback speaker=\(last.speaker ?? "nil") name=\(last.speakerName ?? "nil"), expected other/\(name)")
                }
            },
            defineCheck("the recorded feedback carries my own voice") { _, _, _ in
                let records = ActionFeedbackStore.load(baseDir: w.dir)
                guard let last = records.last else { throw BrineStepError("no feedback recorded") }
                guard last.speaker == "owner" else {
                    throw BrineStepError("feedback speaker=\(last.speaker ?? "nil"), expected owner")
                }
            },
        ]
    }
}

// MARK: - Unit tests (the resolver + policy internals)

final class ActionAttributionResolverTests: XCTestCase {

    private func transcript(
        line: String, by slot: String, speakers: [CaptureSpeaker]
    ) -> SpeakerTranscript {
        SpeakerTranscript(speakers: speakers, segments: [
            TranscriptSegment(seq: 0, text: "Morning everyone thanks for joining",
                              speaker: "speaker_0"),
            TranscriptSegment(seq: 1, text: line, speaker: slot),
        ])
    }

    func testSelfNameConvention() {
        XCTAssertTrue(ActionAttributionResolver.isSelfName("Nick Rinard (me)"))
        XCTAssertTrue(ActionAttributionResolver.isSelfName("me"))
        XCTAssertTrue(ActionAttributionResolver.isSelfName("  Me "))
        XCTAssertFalse(ActionAttributionResolver.isSelfName("Sarah"))
        XCTAssertFalse(ActionAttributionResolver.isSelfName("Amelia"))   // contains "me" but isn't
        XCTAssertFalse(ActionAttributionResolver.isSelfName(""))
    }

    func testNoTranscriptIsPending() {
        XCTAssertEqual(
            ActionAttributionResolver.resolve(utterance: "call the vendor", transcript: nil),
            .pending)
        XCTAssertEqual(
            ActionAttributionResolver.resolve(
                utterance: "call the vendor",
                transcript: SpeakerTranscript(speakers: [], segments: [])),
            .pending)
    }

    func testOwnerLineResolvesToOwner() {
        let t = transcript(
            line: "Remind me to send Sarah the numbers section tonight",
            by: "speaker_1",
            speakers: [CaptureSpeaker(slot: "speaker_1", status: .confirmed,
                                      name: "Nick Rinard (me)")])
        XCTAssertEqual(
            ActionAttributionResolver.resolve(
                utterance: "Remind me to send Sarah the numbers section tonight",
                transcript: t),
            .owner(name: "Nick Rinard (me)"))
    }

    func testInferredOwnerStillCountsAsOwner() {
        let t = transcript(
            line: "I need to book the flights before Friday",
            by: "speaker_1",
            speakers: [CaptureSpeaker(slot: "speaker_1", status: .inferred,
                                      name: "Nick Rinard (me)", inferScore: 0.9)])
        XCTAssertEqual(
            ActionAttributionResolver.resolve(
                utterance: "I need to book the flights before Friday", transcript: t),
            .owner(name: "Nick Rinard (me)"))
    }

    func testOtherSpeakerResolvesWithName() {
        let t = transcript(
            line: "I should get the venue booked by Friday",
            by: "speaker_1",
            speakers: [CaptureSpeaker(slot: "speaker_1", status: .confirmed, name: "Sarah")])
        XCTAssertEqual(
            ActionAttributionResolver.resolve(
                utterance: "I should get the venue booked by Friday", transcript: t),
            .other(name: "Sarah"))
    }

    func testWordingDriftBetweenSTTEnginesStillMatches() {
        // Live STT vs batch diarization word the same moment slightly differently.
        let t = transcript(
            line: "remind me to send sarah the numbers section tonight okay",
            by: "speaker_1",
            speakers: [CaptureSpeaker(slot: "speaker_1", status: .confirmed, name: "Sarah")])
        XCTAssertEqual(
            ActionAttributionResolver.resolve(
                utterance: "Remind me to send Sarah the numbers section tonight!",
                transcript: t),
            .other(name: "Sarah"))
    }

    func testUnmatchedLineIsUnclearNeverAGuess() {
        let t = transcript(
            line: "Entirely unrelated chatter about the weather this weekend",
            by: "speaker_1",
            speakers: [CaptureSpeaker(slot: "speaker_1", status: .confirmed, name: "Sarah")])
        XCTAssertEqual(
            ActionAttributionResolver.resolve(
                utterance: "Remind me to send the numbers section tonight", transcript: t),
            .unclear)
    }

    func testAnonymousVoiceWithIdentifiedOwnerIsOther() {
        let t = SpeakerTranscript(
            speakers: [
                CaptureSpeaker(slot: "speaker_1", status: .anonymous),
                CaptureSpeaker(slot: "speaker_2", status: .confirmed,
                               name: "Nick Rinard (me)"),
            ],
            segments: [
                TranscriptSegment(seq: 0, text: "Someone should file the permit today",
                                  speaker: "speaker_1"),
                TranscriptSegment(seq: 1, text: "Agreed, and I will draft the note",
                                  speaker: "speaker_2"),
            ])
        XCTAssertEqual(
            ActionAttributionResolver.resolve(
                utterance: "Someone should file the permit today", transcript: t),
            .other(name: nil))
    }

    func testAnonymousVoiceWithoutIdentifiedOwnerIsUnclear() {
        // The unnamed voice COULD be the not-yet-inferred owner — never re-file.
        let t = SpeakerTranscript(
            speakers: [CaptureSpeaker(slot: "speaker_1", status: .anonymous)],
            segments: [TranscriptSegment(seq: 0,
                                         text: "Someone should file the permit today",
                                         speaker: "speaker_1")])
        XCTAssertEqual(
            ActionAttributionResolver.resolve(
                utterance: "Someone should file the permit today", transcript: t),
            .unclear)
    }

    func testStopwordOverlapNeverMatches() {
        // Review case: shared function words ("it", "to", "me") must not place
        // the utterance on an unrelated turn.
        let t = transcript(
            line: "give it to me right now I need to go",
            by: "speaker_1",
            speakers: [CaptureSpeaker(slot: "speaker_1", status: .confirmed, name: "Sarah")])
        XCTAssertEqual(
            ActionAttributionResolver.resolve(
                utterance: "Remind me to send it to me", transcript: t),
            .unclear)
    }

    func testDuplicateWordsDoNotInflateTheScore() {
        // Review case: repeats of a matched word must count once, and a match
        // resting on a single content word is no match.
        let t = transcript(
            line: "the deck is done",
            by: "speaker_1",
            speakers: [CaptureSpeaker(slot: "speaker_1", status: .confirmed, name: "Sarah")])
        XCTAssertEqual(
            ActionAttributionResolver.resolve(
                utterance: "the deck the numbers the plan", transcript: t),
            .unclear)
    }

    func testCrossSpeakerTieIsUnclear() {
        // Two DIFFERENT speakers scoring identically is not evidence.
        let line = "Book the venue for the launch by Friday"
        let t = SpeakerTranscript(
            speakers: [
                CaptureSpeaker(slot: "speaker_0", status: .confirmed, name: "Sarah"),
                CaptureSpeaker(slot: "speaker_1", status: .confirmed, name: "Dana"),
            ],
            segments: [
                TranscriptSegment(seq: 0, text: line, speaker: "speaker_0"),
                TranscriptSegment(seq: 1, text: line, speaker: "speaker_1"),
            ])
        XCTAssertEqual(
            ActionAttributionResolver.resolve(utterance: line, transcript: t),
            .unclear)
    }

    func testInferredNonSelfIsTentativeNeverRefiled() {
        // An unconfirmed voiceprint guess labels the row but must not move it
        // (the transcript UI's no-propagation-until-confirmed rule).
        let t = transcript(
            line: "I should get the venue booked by Friday",
            by: "speaker_1",
            speakers: [CaptureSpeaker(slot: "speaker_1", status: .inferred,
                                      name: "Sarah", inferScore: 0.8)])
        let a = ActionAttributionResolver.resolve(
            utterance: "I should get the venue booked by Friday", transcript: t)
        XCTAssertEqual(a, .otherTentative(name: "Sarah"))
        XCTAssertEqual(a.displayText, "Possibly Sarah said")
        XCTAssertFalse(ActionSurfacePolicy.belongsInOthersGroup(
            attribution: a, othersInline: false, promoted: false))
    }

    func testAnonymousVoiceWithOnlyInferredOwnerIsUnclear() {
        // The owner must be CONFIRMED before an unnamed voice on another slot
        // counts as "someone else".
        let t = SpeakerTranscript(
            speakers: [
                CaptureSpeaker(slot: "speaker_1", status: .anonymous),
                CaptureSpeaker(slot: "speaker_2", status: .inferred,
                               name: "Nick Rinard (me)", inferScore: 0.9),
            ],
            segments: [
                TranscriptSegment(seq: 0, text: "Someone should file the permit today",
                                  speaker: "speaker_1"),
                TranscriptSegment(seq: 1, text: "Agreed, and I will draft the note",
                                  speaker: "speaker_2"),
            ])
        XCTAssertEqual(
            ActionAttributionResolver.resolve(
                utterance: "Someone should file the permit today", transcript: t),
            .unclear)
    }

    func testPolicyOnlyRefilesOnPositiveOtherEvidence() {
        for a: ActionAttribution in [.pending, .unclear, .owner(name: "Nick (me)"),
                                     .otherTentative(name: "Sarah")] {
            XCTAssertFalse(ActionSurfacePolicy.belongsInOthersGroup(
                attribution: a, othersInline: false, promoted: false), "\(a)")
        }
        XCTAssertTrue(ActionSurfacePolicy.belongsInOthersGroup(
            attribution: .other(name: "Sarah"), othersInline: false, promoted: false))
        XCTAssertTrue(ActionSurfacePolicy.belongsInOthersGroup(
            attribution: .other(name: nil), othersInline: false, promoted: false))
        // The toggle and a promotion both put the action inline.
        XCTAssertFalse(ActionSurfacePolicy.belongsInOthersGroup(
            attribution: .other(name: "Sarah"), othersInline: true, promoted: false))
        XCTAssertFalse(ActionSurfacePolicy.belongsInOthersGroup(
            attribution: .other(name: "Sarah"), othersInline: false, promoted: true))
    }

    func testDisplayTexts() {
        XCTAssertEqual(ActionAttribution.owner(name: "Nick Rinard (me)").displayText, "You said")
        XCTAssertEqual(ActionAttribution.other(name: "Sarah").displayText, "Sarah said")
        XCTAssertEqual(ActionAttribution.other(name: nil).displayText, "Unknown speaker")
        XCTAssertEqual(ActionAttribution.pending.displayText, "Speaker not identified yet")
        XCTAssertEqual(ActionAttribution.unclear.displayText, "Speaker unclear")
    }

    func testFeedbackRecordSpeakerFieldsRoundTripAndOldLinesDecode() throws {
        let rec = ActionFeedbackRecord(
            captureId: "c1", utterance: "u", summary: "s", kind: .rejected,
            comment: "", speaker: "other", speakerName: "Sarah")
        let data = try JSONEncoder().encode(rec)
        let back = try JSONDecoder().decode(ActionFeedbackRecord.self, from: data)
        XCTAssertEqual(back.speaker, "other")
        XCTAssertEqual(back.speakerName, "Sarah")

        // A pre-attribution line (no speaker fields) still decodes.
        let old = Data("""
        {"ts":1,"captureId":"c1","utterance":"u","summary":"s","kind":"rejected","comment":""}
        """.utf8)
        let legacy = try JSONDecoder().decode(ActionFeedbackRecord.self, from: old)
        XCTAssertNil(legacy.speaker)
        XCTAssertNil(legacy.speakerName)
    }

    func testPromotionStoreRoundTrip() {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("foundryx-promotions-\(UUID().uuidString)", isDirectory: true)
        XCTAssertTrue(ActionPromotionStore.promoted(baseDir: dir).isEmpty)
        ActionPromotionStore.promote(captureId: "c1", utterance: "do the thing", baseDir: dir)
        ActionPromotionStore.promote(captureId: "c1", utterance: "do the thing", baseDir: dir)
        let keys = ActionPromotionStore.promoted(baseDir: dir)
        XCTAssertEqual(keys, [ActionPromotionStore.key(captureId: "c1", utterance: "do the thing")])
    }
}
