// ProvisionalRecordingName — A RECORDING GETS A NAME FAST, AND THE NAME NEVER FLICKERS.
//
// NICK'S WORDS: "it would be great for as soon as any one comes in for it to generate a title
// for it based on the first 30s or 60s or so until the full summary and recording processing is
// done".
//
// THE DURABLE UNIT IS 180 SECONDS, NOT 30. `transcribe_chunk`'s `chunk_index = 0` row IS the
// first window of transcript, written the moment that window succeeds (`free_drainer.rs:1129`,
// `ON CONFLICT … DO UPDATE`), minutes before the whole file is assembled. `audio_chunk.rs:42-46`
// sets the threshold at 600 s and the window at 180 s. A literal 30-second title needs a second
// decode/transcribe path on a system whose whole-file path is the thing currently under repair.
// SO THE COPY SAYS "the first few minutes" — a sentence that is TRUE of a 180-second window and
// would still be true of a 60-second one, rather than a number this side cannot keep. If Nick
// wants literal 30 s, that changes the producer and this file's words survive it.
//
// AND A RECORDING UNDER 600 s HAS NO WINDOWS AT ALL — it is transcribed whole, so for those the
// provisional name and the full name are the same event and there is no provisional pass. That
// is why `provenance` is a fact carried on the name rather than a mode this file assumes.
//
// WHAT THIS FILE OWNS, AND WHAT IT DOES NOT. The lore-side producer — the marker claim, the
// `WHERE title IS NULL` guard, the drainer trigger — is not here and is not the phone's. What is
// here is the part `swift test` can hold: which name is DISPLAYED as arrivals land in whatever
// order they land in, and whether the person is told the name is provisional.

import Foundation

/// WHERE A NAME CAME FROM. Two values, and the wire spells them exactly.
public enum RecordingNameProvenance: String, Sendable, Equatable, CaseIterable {
    /// Made from the first window of transcript. It will be replaced.
    case provisional
    /// Made from the whole recording. It is the name.
    case full

    /// DECODING THE WIRE, AND WHAT AN ABSENT FIELD MEANS.
    ///
    /// `nil` and an unrecognised string both mean **the sender made no provenance claim**, and
    /// this returns `.full` for them — deliberately, and it is the safe direction: every title
    /// this app has ever shown was a whole-recording title, so treating "no claim" as `.full`
    /// preserves the shipped behaviour and, more importantly, NEVER BADGES A REAL NAME AS
    /// PROVISIONAL. The opposite default would put "this will change" under a name that is
    /// final, which is a claim about the future the app cannot keep.
    ///
    /// The consequence is what makes the paired test possible: DROP the field and every name
    /// decodes `.full`, so the provisional fixture stops rendering its note. That is the
    /// falsification, and it is caught by a fixture rather than by a decoder crash.
    public init(wire: String?) {
        guard let wire, let known = RecordingNameProvenance(rawValue: wire) else {
            self = .full
            return
        }
        self = known
    }
}

/// A NAME AND WHERE IT CAME FROM. A name with no text is not a name — the initialiser refuses
/// one — so "title from an empty first window" cannot be built here either.
public struct RecordingName: Sendable, Equatable {
    public let text: String
    public let provenance: RecordingNameProvenance

    /// `nil` when the text is empty or only whitespace. A blank title is the intermediate state
    /// AC6 forbids, and refusing to construct one means no caller can produce it by accident.
    public init?(text: String?, provenance: RecordingNameProvenance) {
        let trimmed = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        self.text = trimmed
        self.provenance = provenance
    }

    /// Decode straight off a wire pair.
    public init?(text: String?, provenanceWire: String?) {
        self.init(text: text, provenance: RecordingNameProvenance(wire: provenanceWire))
    }

    public var isProvisional: Bool { provenance == .provisional }
}

/// Every rule and every string for showing a name that arrives twice.
public enum RecordingNamePresentation {

    /// THE NOTE UNDER A PROVISIONAL NAME. It says where the name came from and that it will
    /// change, because a name that is about to be replaced and does not say so is a small lie
    /// that gets noticed exactly once — when it changes under somebody's eyes.
    ///
    /// It does NOT say "30 seconds" or "180 seconds". The producer's window is 180 s today and
    /// the open question about 30–60 s is recorded on the track; a sentence that names a number
    /// would have to be re-litigated with the producer, and "the first few minutes" is true of
    /// every answer to it.
    public static let provisionalNote =
        "Named from the first few minutes — this will change once the whole recording is understood."

    /// The note to draw under a name, or `nil` for a full name. A full name gets NO note: a
    /// permanent badge on a permanent name is noise.
    public static func note(for name: RecordingName?) -> String? {
        guard let name, name.isProvisional else { return nil }
        return provisionalNote
    }

    /// WHICH NAME IS DISPLAYED WHEN A NEW ONE ARRIVES. The whole no-flicker rule, in one place,
    /// asked by every surface.
    ///
    /// THE FOUR RULES AND WHY EACH ONE IS LOAD-BEARING:
    ///
    ///   1. **An arrival of nothing changes nothing.** A poll that comes back with no title —
    ///      a 404, a re-read, a reply from a door that has not cached it yet — must not blank a
    ///      name already on screen. This is the `title → empty → title` jump-cut, and it is the
    ///      one AC6 asserts against; it is also the ordinary shape of a poll loop, so without
    ///      this rule the flicker is not a rare race, it is the common case.
    ///   2. **A full name always wins.** Whatever is showing, the whole-recording name replaces
    ///      it. Without this the provisional name is permanent, which is worse than no
    ///      provisional name at all.
    ///   3. **A provisional name never replaces a full one**, whatever the ordering. The
    ///      producer's `WHERE title IS NULL` guard says the same thing on the durable side; this
    ///      says it on the display side, so a late provisional arriving after a full title —
    ///      a retry, a reordered poll — cannot walk a good name backwards.
    ///   4. **A provisional name replaces a provisional name.** The producer's window can be
    ///      re-run; the newer reading is the better one.
    public static func settle(current: RecordingName?, incoming: RecordingName?) -> RecordingName? {
        guard let incoming else { return current }             // 1
        guard let current else { return incoming }
        if incoming.provenance == .full { return incoming }     // 2
        if current.provenance == .full { return current }       // 3
        return incoming                                         // 4
    }

    /// THE WHOLE ARRIVAL SEQUENCE, FOLDED — what was on screen after each arrival, in order.
    ///
    /// AC6 is a claim about a TRANSITION, and a claim about a transition cannot be asserted on
    /// one call. This exists so the test asserts the property over the whole run — "no non-empty
    /// name is ever followed by nothing", "the displayed text changes exactly once" — rather
    /// than over the two endpoints, which is where a flicker hides.
    public static func displayed(after arrivals: [RecordingName?],
                                 starting from: RecordingName? = nil) -> [RecordingName?] {
        var current = from
        var seen: [RecordingName?] = []
        for arrival in arrivals {
            current = settle(current: current, incoming: arrival)
            seen.append(current)
        }
        return seen
    }

    /// The name to show when there is none yet. The shipped placeholder, kept in the kit so the
    /// "did the name ever change?" assertion can name what it changed FROM.
    public static let unnamedPlaceholder = "Voice note"

    /// WHICH OF THE PLACES A NAME CAN COME FROM IS THE ONE ON SCREEN, **and whether it is
    /// provisional** — which the detail screen has never said.
    ///
    /// THE DEFECT THIS ANSWERS IS ALREADY IN THE TREE. A provisional name mechanism exists on
    /// the phone today: `ConversationCardMeta.isProvisional` marks an on-device name written
    /// before Kiln has one, and `ConversationCardStore.merge` clears the flag when authoritative
    /// content overrides it (`ConversationCardCache.swift:157`, `:187`, `:194`). The detail
    /// screen resolves that title into its heading alongside the authoritative one and **draws
    /// them identically** — so a name that is about to change is presented as final, and it
    /// changes under the reader without warning. The flag is durable; only the sentence was
    /// missing.
    ///
    /// The precedence is the screen's own, hoisted here rather than restated: an authoritative
    /// title wins, and only in its absence does the durable card's name show — carrying its own
    /// provenance rather than a guessed one.
    /// The two authoritative sources are taken separately, not pre-collapsed by the caller: a
    /// door reply that arrived carrying NO title must fall through to the locally cached one,
    /// and `content?.title ?? cached?.title` does not do that — it yields the door's `nil` and
    /// hides a name the phone already holds. Written out so the precedence is here rather than
    /// re-derived at each call site.
    public static func resolve(doorTitle: String?,
                               cachedTitle: String?,
                               card: ConversationCardMeta?) -> RecordingName? {
        if let name = RecordingName(text: doorTitle, provenance: .full) { return name }
        if let name = RecordingName(text: cachedTitle, provenance: .full) { return name }
        guard let card else { return nil }
        return RecordingName(text: card.title,
                             provenance: card.isProvisional ? .provisional : .full)
    }
}
