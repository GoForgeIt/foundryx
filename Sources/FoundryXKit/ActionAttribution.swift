// ActionAttribution — WHO said a surfaced action (features/
// action-speaker-attribution.feature): the pure attribution model, the
// utterance→speaker resolver over the diarized transcript, the owner-first
// surfacing policy, and the durable promotion store.
//
// TIMING REALITY (why `pending` exists): the ambient lane gates the LIVE
// SpeechAnalyzer transcript while recording — plain text, no speaker labels.
// Diarization (segments + slots + inferred/confirmed names) arrives LATER, via
// the door's `/content` fetch, and is cached in transcript.json. So attribution
// is DERIVED, never stored: every surface re-resolves it from whatever
// diarization exists locally at render time. The moment diarization lands, the
// same build re-files others-uttered actions out of the main list — that IS the
// reconcile, with no persisted state to migrate and speaker renames/confirms
// healing automatically.
//
// OWNER IDENTITY: the phone has no structural "this slot is the owner" marker —
// the diarized speakers are just named. The working convention (the voiceprint
// pipeline + the speaker-naming UI) is that the user names themself with a
// "(me)" marker ("Nick Rinard (me)"). `isSelfName` encodes that convention in
// ONE place.
//
// HONESTY RULES:
//   • pending  — no diarization yet (or a phone-only tier that never gets any):
//     the action stays in the MAIN list, labeled. Nothing is hidden on silence.
//   • unclear  — diarization landed but the moment couldn't be located (live-STT
//     vs batch-STT drift), matched two speakers equally (a tie is not evidence),
//     or matched an unnamed voice with no CONFIRMED owner to distinguish it
//     from: stays in the MAIN list, labeled. Re-filing happens ONLY on positive
//     evidence someone else spoke.
//   • otherTentative — an INFERRED (unconfirmed) non-self name: the label may
//     say "Possibly Sarah said", but a tentative voiceprint guess NEVER moves
//     an action out of the main list (mirrors the transcript UI's
//     no-propagation-until-confirmed rule).
//   • other    — positive evidence: a CONFIRMED non-self speaker, or an unnamed
//     voice on a different slot than the CONFIRMED owner.

import Foundation

// MARK: - The attribution

/// Who said a surfaced action, as well as the phone can honestly know.
public enum ActionAttribution: Equatable, Sendable {
    /// Diarization hasn't landed for this conversation yet — may still resolve.
    case pending
    /// The owner (a self-named speaker) said it. `name` is the diarized name.
    case owner(name: String)
    /// Someone else CONFIRMEDLY said it. `nil` name = an unnamed voice on a
    /// different slot than the confirmed owner ("Unknown speaker").
    case other(name: String?)
    /// An INFERRED (unconfirmed) non-self voiceprint match — labels the row,
    /// never re-files it (a guess is not evidence).
    case otherTentative(name: String)
    /// Diarization landed but the moment couldn't be placed — never re-filed on
    /// a guess.
    case unclear

    /// The attribution line the action row renders.
    public var displayText: String {
        switch self {
        case .pending: return "Speaker not identified yet"
        case .owner: return "You said"
        case .other(.some(let name)): return "\(name) said"
        case .other(nil): return "Unknown speaker"
        case .otherTentative(let name): return "Possibly \(name) said"
        case .unclear: return "Speaker unclear"
        }
    }

    /// The compact wire word feedback records carry (the router's training
    /// signal): pending | owner | other | other_tentative | unclear.
    public var wire: String {
        switch self {
        case .pending: return "pending"
        case .owner: return "owner"
        case .other: return "other"
        case .otherTentative: return "other_tentative"
        case .unclear: return "unclear"
        }
    }

    /// The diarized speaker name, when one is known.
    public var speakerName: String? {
        switch self {
        case .owner(let name): return name
        case .other(let name): return name
        case .otherTentative(let name): return name
        case .pending, .unclear: return nil
        }
    }

    /// POSITIVE evidence someone other than the owner said it — the only state
    /// that re-files an action out of the main list.
    public var isFromOther: Bool {
        if case .other = self { return true }
        return false
    }
}

// MARK: - The resolver

/// Resolves a surfaced utterance to a diarized speaker. Pure; conservative by
/// construction — below-threshold matches, cross-speaker ties, and
/// stopword-only overlap all answer `unclear`, never a guess.
public enum ActionAttributionResolver {
    /// The fraction of the utterance's CONTENT words a speaker's turn must
    /// contain to claim the moment. The live-STT utterance and the
    /// batch-diarized text come from DIFFERENT engines, so exact matching would
    /// never fire; content-word containment at 0.6 tolerates
    /// punctuation/casing/small wording drift while refusing half-matches.
    public static let matchThreshold = 0.6
    /// A match must rest on at least this many DISTINCT content words — one
    /// shared word is coincidence, not placement.
    public static let minMatchedWords = 2

    /// Function words carry no placement evidence — "remind me to send it"
    /// overlaps every turn that says "give it to me". Scoring counts only the
    /// words that survive this filter (review finding: stopword-dense lines
    /// were matching unrelated turns).
    static let stopwords: Set<String> = [
        "the", "an", "and", "or", "but", "if", "so", "to", "of", "in", "on",
        "at", "by", "for", "with", "as", "is", "are", "was", "were", "be",
        "been", "being", "am", "do", "does", "did", "have", "has", "had",
        "will", "would", "can", "could", "should", "shall", "may", "might",
        "must", "me", "my", "we", "us", "our", "you", "your", "he", "she",
        "it", "its", "they", "them", "his", "her", "their", "this", "that",
        "these", "those", "there", "here", "not", "no", "yes", "just", "up",
        "out", "get", "got", "go", "going", "gonna", "let", "lets", "need",
        "want", "okay", "ok", "oh", "um", "uh", "yeah", "well", "right",
        "now", "then", "than", "too", "very", "really", "like", "also",
        // Contraction fragments the tokenizer splits off ("I'll" → "ll").
        "ll", "ve", "re", "don", "didn", "isn", "aren", "wasn", "weren",
        "won", "couldn", "shouldn", "wouldn",
    ]

    /// THE self-name convention, in one place: a speaker named with a "(me)"
    /// marker — or literally "me" — is the owner.
    public static func isSelfName(_ name: String) -> Bool {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return n == "me" || n.contains("(me)")
    }

    /// Attribute one surfaced utterance against the diarized transcript.
    /// `nil`/segment-less transcript ⇒ `.pending` (diarization hasn't landed).
    public static func resolve(
        utterance: String, transcript: SpeakerTranscript?
    ) -> ActionAttribution {
        guard let transcript, transcript.hasSegments else { return .pending }
        let want = Set(tokens(utterance))
        // Too little content to place anywhere honestly.
        guard want.count >= minMatchedWords else { return .unclear }

        // Best score per SLOT across its turns (order-insensitive content-word
        // containment — robust to the two STT engines wording the same moment
        // slightly differently).
        var bestBySlot: [String: Double] = [:]
        for turn in transcript.turns {
            let have = Set(tokens(turn.text))
            let hits = want.intersection(have).count
            guard hits >= minMatchedWords else { continue }
            let score = Double(hits) / Double(want.count)
            if score > (bestBySlot[turn.slot] ?? 0) { bestBySlot[turn.slot] = score }
        }
        let ranked = bestBySlot
            .filter { $0.value >= matchThreshold }
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
        guard let top = ranked.first else { return .unclear }
        // Two DIFFERENT speakers tied at the top — a tie is not evidence.
        if ranked.count > 1, ranked[1].value == top.value { return .unclear }

        let speaker = transcript.speaker(for: top.key)
        if let name = speaker.name, !name.isEmpty, speaker.status != .anonymous {
            if isSelfName(name) { return .owner(name: name) }
            // Only a CONFIRMED identity is evidence enough to re-file; an
            // inferred match labels tentatively and stays in the main list
            // (the transcript UI's no-propagation-until-confirmed rule).
            return speaker.status == .confirmed
                ? .other(name: name)
                : .otherTentative(name: name)
        }
        // An unnamed voice: it is only POSITIVE evidence of "someone else" when
        // the owner is CONFIRMED in this conversation on a DIFFERENT slot.
        // Otherwise the unnamed voice could be the (not-yet-inferred) owner —
        // answer `unclear` and keep the action in the main list.
        let confirmedOwnerSlots = transcript.speakers
            .filter { sp in
                guard let n = sp.name, !n.isEmpty, sp.status == .confirmed else { return false }
                return isSelfName(n)
            }
            .map(\.slot)
        if !confirmedOwnerSlots.isEmpty, !confirmedOwnerSlots.contains(top.key) {
            return .other(name: nil)
        }
        return .unclear
    }

    /// Lowercased alphanumeric CONTENT words: ≥2 chars, stopwords dropped.
    static func tokens(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 2 && !stopwords.contains($0) }
    }
}

// MARK: - Surfacing policy

/// The owner-first surfacing policy (the feature's spine): by DEFAULT only
/// owner-uttered actions surface in the main list; others-uttered ones collect
/// under a collapsed "Heard from others" group. A first-class Settings toggle
/// ("Actions from others") puts everyone inline — no hidden env knobs.
public enum ActionSurfacePolicy {
    /// The Settings toggle's key. Default (unset/false) = owner-only main list.
    public static let othersInlineKey = "foundryx.ambient.othersInline"

    public static func othersInline() -> Bool {
        AccountPreferences.value(
            AccountPreferenceCatalog.ambientOthersInline,
            default: false)
    }

    public static func othersInline(defaults: UserDefaults) -> Bool {
        othersInline(compatibility: .init(defaults: defaults))
    }

    public static func othersInline(
        compatibility: AccountPreferenceCompatibilityStore
    ) -> Bool {
        compatibility.read(AccountPreferenceCatalog.ambientOthersInline)
            == .value(true)
    }

    @discardableResult
    public static func setOthersInline(
        _ enabled: Bool
    ) -> AccountPreferenceWriteResult {
        AccountPreferences.write(
            enabled,
            for: AccountPreferenceCatalog.ambientOthersInline)
    }

    @discardableResult
    public static func setOthersInline(
        _ enabled: Bool,
        compatibility: AccountPreferenceCompatibilityStore
    ) -> AccountPreferenceWriteResult {
        compatibility.write(
            enabled,
            for: AccountPreferenceCatalog.ambientOthersInline)
    }

    /// Whether an action belongs in the collapsed "Heard from others" group.
    /// Only POSITIVE other-speaker evidence re-files; pending/unclear stay in
    /// the main list (nothing hidden without evidence), and a promoted action
    /// stays put wherever the user moved it.
    public static func belongsInOthersGroup(
        attribution: ActionAttribution, othersInline: Bool, promoted: Bool
    ) -> Bool {
        guard !othersInline, !promoted else { return false }
        return attribution.isFromOther
    }
}

// MARK: - Promotion store

/// Durable record of the actions the user PROMOTED out of "Heard from others"
/// into their main list. One small JSON set beside the pipeline's other logs;
/// keys join by the same utterance truncation every pipeline join shares.
public enum ActionPromotionStore {
    public static let filename = "action-promotions.json"

    static func url(baseDir: URL) -> URL {
        baseDir.appendingPathComponent(filename)
    }

    /// The promotion key for one surfaced action.
    public static func key(captureId: String, utterance: String) -> String {
        "\(captureId)#\(ConversationActions.utteranceKey(utterance))"
    }

    /// Every promoted action key. Missing/unreadable file reads as none.
    public static func promoted(baseDir: URL) -> Set<String> {
        guard let data = try? Data(contentsOf: url(baseDir: baseDir)),
              let keys = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return Set(keys)
    }

    /// Promote one action (idempotent; atomic write).
    public static func promote(captureId: String, utterance: String, baseDir: URL) {
        var keys = promoted(baseDir: baseDir)
        keys.insert(key(captureId: captureId, utterance: utterance))
        try? FileManager.default.createDirectory(at: baseDir,
                                                 withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(keys.sorted()) else { return }
        try? data.write(to: url(baseDir: baseDir), options: [.atomic])
    }
}
