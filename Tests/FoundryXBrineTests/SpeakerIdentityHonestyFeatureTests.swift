import XCTest
import Foundation
import BrineSwiftCore
@testable import FoundryXKit

/// Drives `features/speaker-identity-honesty.feature` against the REAL rendering seams:
///  • `SpeakerTranscript.displayLabel` — the transcript-face label (also what
///    `plainText` copies out), now tier-gated so a weak inferred name never renders.
///  • `SpeakerConfidence` — the single source of the inline hint + sheet copy, with
///    NO percentage anywhere.
/// Hermetic: pure model types, no network, no SwiftUI.
final class SpeakerIdentityHonestyFeatureTests: XCTestCase {

    func testSpeakerIdentityHonestyFeature() async throws {
        let world = IdentityHonestyWorld()
        let registry = StepRegistry(IdentityHonestySteps.make(world: world))
        try await BrineFeatureRunner.run("speaker-identity-honesty", registry: registry)
    }
}

// MARK: - world

private final class IdentityHonestyWorld: @unchecked Sendable {
    let slot = "speaker_1"
    let guessedName = "Govinda"
    var transcript: SpeakerTranscript?

    /// Every string the transcript/sheet actually renders for the tentative slot — the
    /// surfaces a percentage or a leaked name could hide in. Each is DERIVED THROUGH the
    /// centralized gate (`CaptureSpeaker.revealedName`) exactly as the views now build
    /// it, so "the guessed name is not shown anywhere" genuinely constrains the two
    /// confirm affordances that previously leaked it.
    func renderedStrings() -> [String] {
        guard let t = transcript else { return [] }
        var out: [String] = []
        let sp = t.speaker(for: slot)
        out.append(t.displayLabel(for: slot))          // transcript face + copy label
        out.append(t.plainText)                          // paste-ready transcript

        // The inline hint only renders for a STRONG (name-revealing) match.
        if sp.isInferred, sp.revealedName != nil {
            out.append(SpeakerConfidence.inlineStrongHint)
        }
        // Inline "Confirm <name>" affordance (SpeakerTurnRow) — only when a name is
        // revealed; weak → no affordance at all.
        if sp.isInferred, let name = sp.revealedName {
            out.append("Confirm \(name)")
            out.append("Confirming \(name)…")
        }
        // Tag-sheet: the caption + the confirm button, both gated on the revealed name.
        if sp.isInferred, let name = sp.revealedName {
            out.append(SpeakerConfidence.sheetCopy(name: name, score: sp.inferScore))
            out.append("Confirm \(name)")
        } else {
            // Weak/anonymous take the tag flow — no name-bearing string.
            out.append("This voice isn't named yet. Who is it?")
        }
        return out
    }

    func seed(score: Double) {
        transcript = SpeakerTranscript(
            speakers: [CaptureSpeaker(slot: slot, status: .inferred,
                                      name: guessedName, inferScore: score,
                                      inferredSpeakerId: "spk_g")],
            segments: [TranscriptSegment(seq: 0, text: "hey there", speaker: slot)])
    }
}

// MARK: - steps

private enum IdentityHonestySteps {
    static func make(world w: IdentityHonestyWorld) -> [StepDefinition] {
        [
            defineStep("a conversation whose voice is only weakly matched to a known person") { ctx, _, _ in
                w.seed(score: 0.78)   // below the 0.85 strong floor
                return ctx
            },
            defineStep("a conversation whose voice is strongly matched to a known person") { ctx, _, _ in
                w.seed(score: 0.93)   // at/above the strong floor
                return ctx
            },
            defineStep("I look at that speaker in the transcript") { ctx, _, _ in
                guard w.transcript != nil else { throw BrineStepError("no transcript seeded") }
                return ctx
            },
            defineStep("the speaker reads as an unnamed numbered speaker") { ctx, _, _ in
                let label = w.transcript?.displayLabel(for: w.slot) ?? ""
                guard label.hasPrefix("Speaker ") else {
                    throw BrineStepError("weak match should read 'Speaker N', got '\(label)'")
                }
                return ctx
            },
            defineStep("the guessed name is not shown anywhere in the transcript") { ctx, _, _ in
                for s in w.renderedStrings() where s.contains(w.guessedName) {
                    throw BrineStepError("weak guessed name leaked into: '\(s)'")
                }
                return ctx
            },
            defineStep("the speaker reads with the person's name") { ctx, _, _ in
                let label = w.transcript?.displayLabel(for: w.slot) ?? ""
                guard label == w.guessedName else {
                    throw BrineStepError("strong match should read '\(w.guessedName)', got '\(label)'")
                }
                return ctx
            },
            defineStep("the match is flagged as a suggestion") { ctx, _, _ in
                let sp = w.transcript!.speaker(for: w.slot)
                guard SpeakerConfidence.tier(for: sp.inferScore) == .strong else {
                    throw BrineStepError("strong match should tier as .strong")
                }
                guard SpeakerConfidence.inlineStrongHint == "suggested" else {
                    throw BrineStepError("inline hint should read 'suggested'")
                }
                return ctx
            },
            defineStep("no rendered text shows a percentage") { ctx, _, _ in
                for s in w.renderedStrings() where s.contains("%") {
                    throw BrineStepError("a percent sign leaked into rendered text: '\(s)'")
                }
                return ctx
            },
        ]
    }
}
