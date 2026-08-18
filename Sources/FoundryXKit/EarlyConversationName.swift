// EarlyConversationName — A RECORDING GETS A NAME THE MOMENT ANY TRANSCRIPT EXISTS.
//
// WHAT NICK ASKED FOR, in his words: "it would be great for as soon as any one comes in for it to
// generate a title for it based on the first 30s or 60s or so until the full summary and recording
// processing is done".
//
// WHAT HAPPENS TODAY. A recording that came off a recorder is named by the pipeline that produces
// its summary, and until that lands the row carries a time range and nothing else. `RollingTitle`
// already names a LIVE microphone session from its own running transcript — but a recording pulled
// off a Pocket never had a live transcript on this phone, so nothing on that path ever runs. The
// transcript arrives whole, from the door, minutes before the title does, and in that window the
// phone is holding the words and showing none of them.
//
// THE WINDOW IS ONLY A TIME WINDOW WHEN THERE ARE TIMES, and that is the part worth being careful
// about. A diarized reply carries per-segment milliseconds; a paragraph reply carries seconds. On
// either, "the first 45 seconds" is a measurement. A FLAT transcript carries no clock at all — so
// calling its opening "the first 60 seconds" would be a figure with nothing behind it, in a
// program that has printed three of those. A flat transcript is named from its opening WORDS and
// the note says so.
//
// AND THE NOTE NEVER CLAIMS MORE THAN THE RECORDING HAS. A twelve-second recording read whole says
// twelve seconds, not sixty: the number is what was actually covered, not the budget.
//
// THE NAME ITSELF IS NOT A NEW HEURISTIC. It is `WholeConversationTitle.heuristic(from:)` — the
// same pure, already-tested namer the live path uses — handed the window's text. A second naming
// heuristic would be a second thing to be wrong.

import Foundation

public enum EarlyConversationName {

    /// The opening window, in seconds. Nick said "30s or 60s or so"; 60 is the upper end of what
    /// he named, and it is a CAP rather than a claim — see `Basis.seconds`.
    public static let windowSeconds = 60

    /// WHAT THE NAME WAS READ FROM. The two cases are not stylistic: one is entitled to state a
    /// duration and the other is not.
    public enum Basis: Sendable, Equatable {
        /// Timings existed, and this many seconds of them were read. Always the span actually
        /// covered, capped at `windowSeconds` — never the budget.
        case seconds(Int)
        /// No timings existed anywhere in the reply. The opening words were read and no duration
        /// is claimed.
        case openingWords
    }

    /// An early name and the evidence for it.
    public struct Offer: Sendable, Equatable {
        public let name: String
        public let basis: Basis

        public init(name: String, basis: Basis) {
            self.name = name
            self.basis = basis
        }

        /// The line under the name. THE ONLY PLACE A DURATION CAN APPEAR is the `.seconds` arm,
        /// so the claim "no seconds are named without timings" is held over the rendered text.
        public var note: String {
            switch basis {
            case .seconds(let n):
                return n == 1 ? "Early name, from the first second"
                              : "Early name, from the first \(n) seconds"
            case .openingWords:
                return "Early name, from the opening words"
            }
        }
    }

    /// Name a recording from its opening window, or answer nil when there is not enough to name.
    ///
    /// The sources are tried in the order of how much they know: diarized segments (milliseconds),
    /// then paragraphs (seconds), then the flat transcript (no clock). A source counts only when it
    /// actually carries timings — a segment array whose `startMs` is nil throughout knows no more
    /// about time than the flat string does, and is treated accordingly rather than being allowed
    /// to lend its shape to a duration claim.
    public static func offer(segments: [TranscriptSegment] = [],
                             paragraphs: [TranscriptParagraph] = [],
                             flat: String? = nil) -> Offer? {
        if let offer = fromSegments(segments) { return offer }
        if let offer = fromParagraphs(paragraphs) { return offer }
        if let flat, let name = WholeConversationTitle.heuristic(from: flat) {
            return Offer(name: name, basis: .openingWords)
        }
        return nil
    }

    private static func fromSegments(_ segments: [TranscriptSegment]) -> Offer? {
        let timed = segments.filter { $0.startMs != nil }
        guard !timed.isEmpty else { return nil }
        let cap = windowSeconds * 1_000
        // KEPT BY WHERE IT STARTS. A segment that begins inside the window and runs past it is
        // read whole, and the note then reports the window rather than its true end — so the
        // note can UNDERSTATE what was read and never overstate it. That asymmetry is the
        // deliberate one: a claim smaller than the evidence is not a claim nobody can defend.
        let kept = timed.filter { ($0.startMs ?? 0) < cap }
        guard !kept.isEmpty else { return nil }
        let text = kept.map(\.text).joined(separator: " ")
        guard let name = WholeConversationTitle.heuristic(from: text) else { return nil }
        // THE SPAN ACTUALLY COVERED. `endMs` when the reply carries it, else the last start —
        // either way a number the transcript stated, capped at the window.
        let lastMs = kept.map { $0.endMs ?? $0.startMs ?? 0 }.max() ?? 0
        return Offer(name: name, basis: .seconds(seconds(fromMilliseconds: lastMs)))
    }

    private static func fromParagraphs(_ paragraphs: [TranscriptParagraph]) -> Offer? {
        guard !paragraphs.isEmpty else { return nil }
        let cap = Double(windowSeconds)
        let kept = paragraphs.filter { $0.start < cap }
        guard !kept.isEmpty else { return nil }
        let text = kept.map(\.text).joined(separator: " ")
        guard let name = WholeConversationTitle.heuristic(from: text) else { return nil }
        let lastSeconds = kept.map { max($0.end, $0.start) }.max() ?? 0
        return Offer(name: name,
                     basis: .seconds(seconds(fromMilliseconds: Int((lastSeconds * 1_000).rounded()))))
    }

    /// Whole seconds, rounded UP so a 11.4-second read is not reported as 11 — and never past the
    /// window, and never zero (a name read from something is read from at least a second).
    static func seconds(fromMilliseconds ms: Int) -> Int {
        let raw = Int((Double(max(0, ms)) / 1_000).rounded(.up))
        return min(windowSeconds, max(1, raw))
    }
}

/// WHAT NAME THE ROW SHOWS, AND WHY IT CANNOT FLIP BACK.
///
/// Nick's constraint, in his words: the early title runs "until the full summary and recording
/// processing is done" — so there are two names for one recording, arriving minutes apart, and a
/// row that shows whichever arrived most recently would rename itself in front of somebody twice.
///
/// THE RULE IS ONE-WAY. An early name is adopted only while no settled name has EVER been seen; a
/// settled name, once adopted, is never given back — not to a later reading that carries no title
/// (a status poll after a transcript prune returns none, and the door 404s with `{found:false}`
/// routinely), and not to a fresh early name derived from a re-fetched transcript.
///
/// AND THE CHANGE IS NEVER SILENT. `isProvisional` is true for exactly as long as the early name is
/// showing, so the row that is about to be renamed is the row that has been saying it is early.
/// The replacement is then the thing the person was told to expect, which is the difference between
/// a rename and a glitch.
///
/// It is a value with a mutating `adopt` rather than a rule in a view for the usual reason: a
/// SwiftUI body cannot be executed by `swift test`, and "it never flips back" is precisely the kind
/// of claim that needs executing.
public struct ConversationNameOnTheRow: Sendable, Equatable {

    public enum Shown: Sendable, Equatable {
        case none
        case early(String)
        case settled(String)
    }

    public private(set) var shown: Shown
    /// True once a settled name has been seen — the latch that makes the rule one-way.
    public private(set) var everSettled: Bool

    public init() {
        shown = .none
        everSettled = false
    }

    /// The name to render, or nil when there is nothing honest to render.
    public var name: String? {
        switch shown {
        case .none: return nil
        case .early(let n), .settled(let n): return n
        }
    }

    /// Whether the name showing is the early one, and must be marked as such.
    public var isProvisional: Bool {
        if case .early = shown { return true }
        return false
    }

    /// Take a reading. Empty and whitespace-only strings are treated as absent, so a door that
    /// answers `""` cannot latch the row onto a blank name.
    public mutating func adopt(early: String?, settled: String?) {
        if let settled = clean(settled) {
            shown = .settled(settled)
            everSettled = true
            return
        }
        if everSettled { return }          // ONE-WAY: a settled row never goes back.
        if let early = clean(early) { shown = .early(early) }
    }

    private func clean(_ s: String?) -> String? {
        guard let s else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
