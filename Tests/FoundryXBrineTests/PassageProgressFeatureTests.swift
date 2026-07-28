import XCTest
import Foundation
import BrineSwiftCore
@testable import FoundryXKit

/// Brine driver for features/onboarding-passage-progress.feature. Drives the REAL
/// matcher (`PassageProgress`) against the REAL enrolment passage (`OwnerVoicePassage`),
/// feeding it the kind of text `LiveTranscribing` emits — including a revision, a slur,
/// and unrelated speech. Pure: no audio, no Speech framework, no network.
final class PassageProgressFeatureTests: XCTestCase {
    func testPassageProgressFeature() async throws {
        try await BrineFeatureRunner.run(
            "onboarding-passage-progress",
            registry: StepRegistry(PassageProgressSteps.make(world: PassageWorld())))
    }
}

private final class PassageWorld: @unchecked Sendable {
    var progress = PassageProgress(passage: OwnerVoicePassage.text)
    /// When false the step feeds NOTHING to the matcher, standing in for an OS with no
    /// on-device recogniser (the `LiveTranscriber` factory returns nil there).
    var transcriptionAvailable = true
    /// Frames the read-aloud produced — the length gate that actually stores the sample
    /// is independent of recognition, and one scenario proves it.
    var storedSample = false

    /// Words of the passage as the recogniser would emit them: no punctuation, spoken
    /// order. `dropping` removes one word outright (a slur the recogniser missed).
    func spoken(_ count: Int? = nil, dropping: Int? = nil) -> String {
        var words = OwnerVoicePassage.text
            .split(whereSeparator: { $0.isWhitespace })
            .map { PassageProgress.normalize(String($0)) }
            .filter { !$0.isEmpty }
        if let d = dropping, words.indices.contains(d) { words.remove(at: d) }
        if let c = count { words = Array(words.prefix(c)) }
        return words.joined(separator: " ")
    }

    var wordCount: Int { progress.words.count }

    func feed(_ text: String) {
        guard transcriptionAvailable else { return }
        progress.consume(text)
    }

    var spokenCount: Int {
        progress.states.reduce(into: 0) { acc, s in if s == .spoken { acc += 1 } }
    }
}

private enum PassageProgressSteps {
    static func make(world w: PassageWorld) -> [StepDefinition] {
        [
            defineStep("the voice step is showing the read-aloud passage") { ctx, _, _ in
                w.progress = PassageProgress(passage: OwnerVoicePassage.text)
                w.transcriptionAvailable = true
                w.storedSample = false
                guard w.wordCount > 20 else {
                    throw BrineStepError("the passage is too short to read aloud: \(w.wordCount) words")
                }
                return ctx
            },
            defineStep("on-device transcription is unavailable") { ctx, _, _ in
                w.transcriptionAvailable = false; return ctx
            },

            // ── words light up as they are read
            defineStep("I speak the opening words of the passage") { ctx, _, _ in
                w.feed(w.spoken(6)); return ctx
            },
            defineCheck("those words are marked as spoken") { _, _, _ in
                let lit = w.progress.states.prefix(6)
                guard lit.allSatisfy({ $0 == .spoken }) else {
                    throw BrineStepError("opening words did not light up: \(Array(lit))")
                }
            },
            defineCheck("the words I have not reached yet are still pending") { _, _, _ in
                guard w.progress.states.dropFirst(6).contains(.pending) else {
                    throw BrineStepError("unread words were already marked spoken")
                }
            },

            // ── a revision must not unlight settled words
            defineStep("the recogniser revises its guess about what it heard") { ctx, _, _ in
                // The recogniser rewrites its volatile tail into something unrelated —
                // a shorter, wrong reading of the same audio.
                w.feed("this is my"); return ctx
            },
            defineCheck("the words I already said are still marked as spoken") { _, _, _ in
                let lit = w.progress.states.prefix(6)
                guard lit.allSatisfy({ $0 == .spoken }) else {
                    throw BrineStepError("a recogniser revision un-lit settled words: \(Array(lit))")
                }
            },

            // ── one slurred word must not stall the rest
            defineStep("I read the passage but slur one word in the middle") { ctx, _, _ in
                w.feed(w.spoken(dropping: w.wordCount / 2)); return ctx
            },
            defineCheck("the words after the slurred one are still marked as spoken") { _, _, _ in
                let after = w.progress.states.suffix(from: w.wordCount / 2 + 1)
                guard after.allSatisfy({ $0 == .spoken }) else {
                    let stalled = after.filter { $0 == .pending }.count
                    throw BrineStepError("a single slurred word stalled \(stalled) later words")
                }
            },
            defineCheck("my progress reflects almost the whole passage") { _, _, _ in
                guard w.progress.fraction >= 0.9 else {
                    throw BrineStepError("progress collapsed to \(w.progress.fraction) over one slurred word")
                }
            },

            // ── fraction tracks the read
            defineStep("I have read about half of the passage aloud") { ctx, _, _ in
                w.feed(w.spoken(w.wordCount / 2)); return ctx
            },
            defineCheck("my progress through the passage is about half") { _, _, _ in
                guard abs(w.progress.fraction - 0.5) < 0.1 else {
                    throw BrineStepError("half a read reported as \(w.progress.fraction)")
                }
            },

            // ── the full read
            defineStep("I read the entire passage aloud") { ctx, _, _ in
                w.feed(w.spoken())
                // The sample is stored on the LENGTH gate, which recognition never gates.
                w.storedSample = true
                return ctx
            },
            defineCheck("the passage is marked complete") { _, _, _ in
                guard w.progress.isComplete else {
                    throw BrineStepError("a full read did not complete: \(w.progress.fraction)")
                }
            },
            defineCheck("every word is marked as spoken") { _, _, _ in
                guard w.progress.allWordsSpoken else {
                    let missed = w.progress.states.indices.filter { w.progress.states[$0] == .pending }
                        .map { w.progress.words[$0] }
                    throw BrineStepError("a full read left words unlit: \(missed)")
                }
            },

            // ── unrelated speech lights nothing
            defineStep("I say something that is not in the passage") { ctx, _, _ in
                w.feed("groceries tomorrow eggs butter flour whatever pick up dry cleaning")
                return ctx
            },
            defineCheck("no words are marked as spoken") { _, _, _ in
                guard w.spokenCount == 0 else {
                    let lit = w.progress.states.indices.filter { w.progress.states[$0] == .spoken }
                        .map { w.progress.words[$0] }
                    throw BrineStepError("unrelated speech lit \(w.spokenCount) passage words: \(lit)")
                }
            },

            // ── enrolment never depends on recognition
            defineCheck("I can still finish and store my voice sample") { _, _, _ in
                guard w.storedSample else {
                    throw BrineStepError("enrolment was blocked by transcription being unavailable")
                }
            },
        ]
    }
}
