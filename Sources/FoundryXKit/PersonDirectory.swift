// PersonDirectory — the "pick an existing person" model + pure pick logic (track
// 20260717T1700_pick_existing_person).
//
// Why this exists (Nick, b232): "when selecting a name in the app, can we select a
// previously created name so we can choose one that exists and handle the dedup right
// there rather than manually typing a new one?" The old tag flow was a free-text field
// whose caption literally said "type a new name to create a person, or an existing
// person's name to assign this voice to them" — so every mistyped/variant spelling
// MINTED A DUPLICATE person (the entity-dedup finding: "the bug as a sentence").
//
// The fix is to make the human-confirm authority CHOOSE an existing durable person
// (binding its opaque `entityId`) instead of typing a string the system then guesses at.
// This file is the PURE layer (no SwiftUI, no network):
//   • KnownPerson — the durable person entity the door proxies (`GET /foundryx/persons`).
//   • PersonPicker — filter/autocomplete + the voiceprint HINT (annotate, never pre-select)
//     + the create-new gate. All deterministic + unit-tested; the sheet renders it.
//
// Voiceprint humility (entity-dedup Decision 9): an inferred (cosine) match may SUGGEST a
// likely person, surfaced as a gentle "likely: Nick" annotation that sorts that person up
// — but it PRE-SELECTS NOTHING. Human confirm is the only signal allowed to bind.

import Foundation

/// A durable person entity from the computer's Lore library, offered as a pick-list row so
/// a confirm binds an EXISTING person (its opaque `entityId`) instead of minting a dupe.
/// Mirrors the door's `GET /foundryx/persons?space=<space>` reply
/// `[{entity_id, display_name, aliases?, last_seen?}]`.
public struct KnownPerson: Decodable, Sendable, Equatable, Identifiable {
    /// The stable OPAQUE person key — never the name. This is what a confirm binds.
    public let entityId: String
    /// The display label (one of possibly many names for this entity).
    public let displayName: String
    /// Other names/spellings this entity is known by — matched by autocomplete so a
    /// variant spelling still finds the existing person.
    public let aliases: [String]
    /// When this person was last heard (epoch ms), used only to sort the pick-list
    /// most-recent-first. `nil` when the door omits it.
    public let lastSeenMs: Int?

    public var id: String { entityId }

    public init(entityId: String, displayName: String,
                aliases: [String] = [], lastSeenMs: Int? = nil) {
        self.entityId = entityId
        self.displayName = displayName
        self.aliases = aliases
        self.lastSeenMs = lastSeenMs
    }

    enum CodingKeys: String, CodingKey {
        case entityId = "entity_id"
        case displayName = "display_name"
        case aliases
        case lastSeen = "last_seen"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Tolerant to the sibling backend's exact key casing: prefer snake_case
        // (`entity_id`), but also accept camelCase (`entityId`) so a shape drift on
        // either side doesn't blank the whole list.
        entityId = (try? c.decode(String.self, forKey: .entityId))
            ?? (try? decoder.container(keyedBy: AltKeys.self).decode(String.self, forKey: .entityId))
            ?? ""
        displayName = (try? c.decode(String.self, forKey: .displayName))
            ?? (try? decoder.container(keyedBy: AltKeys.self).decode(String.self, forKey: .displayName))
            ?? ""
        aliases = (try? c.decode([String].self, forKey: .aliases)) ?? []
        // `last_seen` is under-specified in the contract — accept an epoch-ms number
        // (Int or Double); anything else (e.g. an ISO string) simply yields nil and the
        // row falls back to name ordering. Never fatal.
        if let i = try? c.decodeIfPresent(Int.self, forKey: .lastSeen) {
            lastSeenMs = i
        } else if let d = try? c.decodeIfPresent(Double.self, forKey: .lastSeen) {
            lastSeenMs = Int(d)
        } else {
            lastSeenMs = nil
        }
    }

    /// camelCase fallbacks for a door that didn't snake-case the keys.
    private enum AltKeys: String, CodingKey {
        case entityId
        case displayName
    }
}

/// The door's `GET /foundryx/persons` reply when wrapped in an envelope (`{persons:[…]}`,
/// mirroring `GET /foundryx/models` → `{models:[…]}`). The client accepts EITHER this or a
/// bare top-level array, so it survives whichever shape the sibling backend actually ships.
public struct PersonsResponse: Decodable, Sendable, Equatable {
    public let persons: [KnownPerson]
    public init(persons: [KnownPerson]) { self.persons = persons }
}

/// The pure pick logic: filter/autocomplete over the known-person directory, the voiceprint
/// HINT (annotate + sort, never pre-select), and the create-new fallback gate. No UI, no
/// network — every rule here is deterministic and unit-tested so the sheet and its coverage
/// can never drift.
public enum PersonPicker {

    /// Case- and diacritic-insensitive normalization: "Nadège" and "Nadege" match; leading/
    /// trailing whitespace is ignored AND internal whitespace runs collapse to one space, so
    /// a typo like "Nick  Rinard" still resolves to the existing "Nick Rinard" (never mints a
    /// dup via `exactMatch`). The one comparison key every rule below uses.
    public static func normalize(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// How strongly a person matched a query — lower is a stronger match, used to rank.
    private enum MatchRank: Int { case exact = 0, prefix = 1, wordPrefix = 2, substring = 3 }

    /// The best match rank for `q` (already normalized) against one field, or nil if no
    /// match. Exact beats a leading-prefix beats a word-start beats a loose substring.
    private static func rank(_ q: String, field raw: String) -> MatchRank? {
        let f = normalize(raw)
        guard !q.isEmpty, !f.isEmpty else { return nil }
        if f == q { return .exact }
        if f.hasPrefix(q) { return .prefix }
        if f.split(separator: " ").contains(where: { $0.hasPrefix(q) }) { return .wordPrefix }
        if f.contains(q) { return .substring }
        return nil
    }

    /// A person's best rank across its display name + every alias.
    private static func rank(_ q: String, person p: KnownPerson) -> MatchRank? {
        ([p.displayName] + p.aliases)
            .compactMap { rank(q, field: $0) }
            .min(by: { $0.rawValue < $1.rawValue })
    }

    /// Sort key that puts the most-recently-heard person first, then alphabetical — the
    /// stable base ordering for the pick-list ("Nick — heard most recently").
    private static func recencyThenName(_ a: KnownPerson, _ b: KnownPerson) -> Bool {
        let la = a.lastSeenMs ?? Int.min, lb = b.lastSeenMs ?? Int.min
        if la != lb { return la > lb }
        return normalize(a.displayName) < normalize(b.displayName)
    }

    /// Filter + rank the directory for a typed `query`. A blank query returns the whole
    /// directory in recency order (the pick-first list on open); a non-blank query keeps
    /// only matching people, best-match first (exact → prefix → word-start → substring),
    /// ties broken by recency then name. This is the autocomplete — "Do you mean Nick
    /// Rinard?" surfaces the existing entity so the user binds it instead of retyping.
    public static func filter(_ query: String, in persons: [KnownPerson]) -> [KnownPerson] {
        let q = normalize(query)
        guard !q.isEmpty else { return persons.sorted(by: recencyThenName) }
        return persons
            .compactMap { p -> (KnownPerson, MatchRank)? in rank(q, person: p).map { (p, $0) } }
            .sorted { lhs, rhs in
                if lhs.1.rawValue != rhs.1.rawValue { return lhs.1.rawValue < rhs.1.rawValue }
                return recencyThenName(lhs.0, rhs.0)
            }
            .map(\.0)
    }

    /// The voiceprint HINT (entity-dedup Decision 9): the `entityId` of the person the
    /// slot's inferred (cosine) name most likely refers to — surfaced as a gentle
    /// annotation and sorted up, but PRE-SELECTING NOTHING. `inferredName` is the slot's
    /// REVEALED inferred name (already honesty-gated to strong evidence upstream); a nil/
    /// blank name (a weak or unknown slot) yields no hint. Prefers an exact name/alias
    /// match, then a name whose word starts with it. Never invents a hint.
    public static func hintEntityId(inferredName: String?, in persons: [KnownPerson]) -> String? {
        guard let raw = inferredName else { return nil }
        let q = normalize(raw)
        guard !q.isEmpty else { return nil }
        // Exact name/alias match wins; otherwise the strongest word-prefix match. A loose
        // substring is deliberately NOT enough to nudge (a hint must be honest).
        let ranked = persons
            .compactMap { p -> (KnownPerson, MatchRank)? in
                guard let r = rank(q, person: p), r.rawValue <= MatchRank.wordPrefix.rawValue
                else { return nil }
                return (p, r)
            }
            .sorted { lhs, rhs in
                if lhs.1.rawValue != rhs.1.rawValue { return lhs.1.rawValue < rhs.1.rawValue }
                return recencyThenName(lhs.0, rhs.0)
            }
        return ranked.first?.0.entityId
    }

    /// The pick-list ordering on OPEN (no query yet): the base recency order, with the
    /// voiceprint-hinted person floated to the top so "likely: Nick" is easy to reach —
    /// but this is only an ORDER, never a selection. The sheet renders no row as chosen
    /// until the human taps one.
    public static func ordered(persons: [KnownPerson], hintEntityId: String?) -> [KnownPerson] {
        let base = persons.sorted(by: recencyThenName)
        guard let hint = hintEntityId, let idx = base.firstIndex(where: { $0.entityId == hint })
        else { return base }
        var out = base
        let hinted = out.remove(at: idx)
        out.insert(hinted, at: 0)
        return out
    }

    /// Whether the typed `query` EXACTLY matches an existing person (by display name or
    /// alias). Used to gate the create-new fallback: if the name already exists, the user
    /// should bind it, not mint a second one.
    public static func exactMatch(_ query: String, in persons: [KnownPerson]) -> KnownPerson? {
        let q = normalize(query)
        guard !q.isEmpty else { return nil }
        return persons.first { p in
            ([p.displayName] + p.aliases).contains { normalize($0) == q }
        }
    }

    /// Whether to offer "Create new person: <query>". PICK-FIRST: create-new is the
    /// EXCEPTION, shown only when the user typed something AND it matches no existing
    /// person (nothing to bind). A blank query or an exact match hides it.
    public static func showCreateNew(query: String, in persons: [KnownPerson]) -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return false }
        return exactMatch(q, in: persons) == nil
    }
}
