// PassageProgress — "which words of the read-aloud have I actually said?"
//
// The voice-enrolment step asks the owner to read a fixed passage aloud. A byte-count
// progress bar tells them how long is left but not whether they are being HEARD, which
// is the one thing that matters when the output is a voice key. This turns the passage
// itself into the progress indicator: recognised speech is matched against the passage
// word by word, and matched words light up and STAY lit.
//
// Deliberately pure — no Speech, no AVFoundation, no SwiftUI. It consumes whatever text
// `LiveTranscribing` produces (see LiveTranscriber.swift) and produces per-word display
// state, so the whole behaviour is unit-testable with string literals and the UI layer
// is a thin render of `states`. Enrolment must NEVER depend on recognition being
// available: when no transcript arrives this simply stays all-pending and the read-aloud
// works exactly as it did before.

import Foundation

/// The enrolment read-aloud itself. It lives here rather than in the view because the
/// passage is now DATA the matcher is tested against, not just copy: a scenario that
/// reads "the entire passage aloud" has to be able to name it.
///
/// The read doubles as the product introduction — in the ~20 seconds it takes to speak,
/// it teaches what the app does, where the data lives, the agent's name, and the "look
/// that up" ritual. Keep any edit speakable: no abbreviations, no URLs.
public enum OwnerVoicePassage {
    public static let text = """
    “This is my FoundryX. It remembers my voice notes for me, \
    and everything it hears stays on my own devices. \
    When I say something like ‘I’ll have to look that up,’ \
    it can find the answer in my own memory. \
    And when I call my agent — Foundry — it acts for me, \
    and answers to my voice alone. \
    A voice is a kind of key, and this one is mine.”
    """
}

/// Per-word display state for the read-aloud passage.
public enum PassageWordState: Equatable, Sendable {
    /// Not yet reached (render muted).
    case pending
    /// Heard and locked in (render at full strength). Never returns to `pending`.
    case spoken
}

public struct PassageProgress: Equatable, Sendable {
    /// The passage split for display, punctuation and capitalisation intact — render
    /// these, joined by a space, in `states` order.
    public let words: [String]
    /// Match keys for `words`, 1:1 by index (lowercased, punctuation folded away).
    private let keys: [String]
    /// Positions carrying an actual pronounceable word. The passage contains tokens that
    /// are punctuation ALONE — the em dashes around the agent's name — which normalise to
    /// an empty key and so can never be matched. Left in the general population they
    /// permanently stall the lookahead window and make a perfect read register as
    /// incomplete; the reader is not at fault for failing to pronounce a dash.
    private let speakable: [Int]
    /// Display state per word, 1:1 with `words`.
    public private(set) var states: [PassageWordState]
    /// How far into the passage the last successful match landed. Monotonic.
    private var cursor: Int = 0

    /// How many words ahead of the cursor a match may land. A reader who slurs, elides
    /// or re-orders a word should not stall the rest of the passage; a listener hearing
    /// something entirely unrelated should still light nothing up. Four words is wide
    /// enough to step over a dropped article or two, narrow enough that unrelated speech
    /// almost never collides.
    static let lookahead = 4

    /// At what fraction of the passage the read counts as complete. Forgiving on
    /// purpose: recognition drops the odd word even on a clean read, and stranding the
    /// user one word short of "done" would be a lie about their effort.
    public static let completionThreshold = 0.9

    public init(passage: String) {
        let display = passage
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
        words = display
        let k = display.map(PassageProgress.normalize)
        keys = k
        speakable = k.indices.filter { !k[$0].isEmpty }
        states = Array(repeating: .pending, count: display.count)
    }

    /// Feed the transcript recognised SO FAR (the whole thing, not just the new tail).
    ///
    /// Recognisers revise: a volatile tail can be rewritten, shortened, or re-segmented
    /// between callbacks. So each call re-derives a fresh pass from the start and UNIONS
    /// it into the existing state — a word that was lit stays lit even if the recogniser
    /// later changes its mind about it. That makes this safe to call on every partial.
    public mutating func consume(_ recognizedSoFar: String) {
        let heard = recognizedSoFar
            .split(whereSeparator: { $0.isWhitespace })
            .map { PassageProgress.normalize(String($0)) }
            .filter { !$0.isEmpty }
        guard !heard.isEmpty, !speakable.isEmpty else { return }

        // The walk is over SPEAKABLE positions only, so the lookahead window is spent on
        // words the reader could actually have said.
        var fresh = Array(repeating: false, count: keys.count)
        var step = 0
        for word in heard {
            let upper = min(speakable.count, step + PassageProgress.lookahead + 1)
            guard step < upper else { break }
            guard let hit = (step..<upper).first(where: { keys[speakable[$0]] == word }) else { continue }
            fresh[speakable[hit]] = true
            step = hit + 1
        }

        for i in fresh.indices where fresh[i] { states[i] = .spoken }
        cursor = max(cursor, step)

        // Punctuation-only tokens the read has already swept past adopt the spoken look,
        // so the highlight reads as a continuous band rather than one with holes in it.
        let reached = cursor < speakable.count ? speakable[cursor] : keys.count
        for i in 0..<reached where keys[i].isEmpty { states[i] = .spoken }
    }

    /// Fraction of the passage heard, 0…1 — drives the enrolment ring.
    public var fraction: Double {
        guard !speakable.isEmpty else { return 0 }
        let said = speakable.reduce(into: 0) { acc, i in if states[i] == .spoken { acc += 1 } }
        return Double(said) / Double(speakable.count)
    }

    /// The read has covered enough of the passage to call it done.
    public var isComplete: Bool { fraction >= PassageProgress.completionThreshold }

    /// Every single word was heard — a stricter signal than `isComplete`, used by tests
    /// and by nothing in the UI (the UI must not demand a perfect read).
    public var allWordsSpoken: Bool {
        !speakable.isEmpty && speakable.allSatisfy { states[$0] == .spoken }
    }

    /// Match key: case-folded, diacritic-folded, and stripped of the punctuation the
    /// passage carries for readability (curly quotes, commas, the em dash). A recogniser
    /// emits "ill" for the passage's "‘I'll" — both must normalise to the same key.
    static func normalize(_ raw: String) -> String {
        let folded = raw.folding(options: [.diacriticInsensitive, .caseInsensitive],
                                 locale: Locale(identifier: "en_US"))
        return String(folded.unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0)
        })
    }
}
