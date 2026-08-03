// KilnLibraryModel.swift — the ONE node model the phone renders Kiln's shared conversation
// library from, ported FAITHFULLY from the Kiln desktop's `chatLibraryModel.ts` and
// `importRender.ts`.
//
// FIDELITY IS THE REQUIREMENT, not elegance. The phone and the desktop rail must group,
// collapse and order the same library the same way, or "pick it up wherever I am" is a lie
// the moment the two disagree about what a row IS. Where the TypeScript has a quirk — a
// STRING comparison over timestamps, a falsy empty string, a recomputed `lastActivity` that
// ignores a field the server sends — the quirk is reproduced here on purpose and named in a
// comment. A "cleaner" version is a divergence.
//
// Everything here is pure, so Brine drives it with no UI and no network.

import Foundation

// ─────────────────────────────────────────────────────────────────────────────
// Falsiness — the small thing that keeps the two surfaces honest
// ─────────────────────────────────────────────────────────────────────────────

/// JavaScript truthiness for an optional string: `null`, `undefined` AND `""` are all falsy.
/// The desktop leans on this everywhere (`!r.project_id`, `!r.loop_id`,
/// `r.continued_from_harness ? … : …`), and the store really does write `""` for some of
/// these, so an `Optional`-only check here would silently diverge.
@inline(__always)
func kilnTruthy(_ s: String?) -> String? {
    guard let s, !s.isEmpty else { return nil }
    return s
}

// ─────────────────────────────────────────────────────────────────────────────
// Timestamps
// ─────────────────────────────────────────────────────────────────────────────

/// RFC-3339 / ISO-8601 parsing for the library's timestamps, hand-rolled on purpose.
///
/// The live store emits BOTH `2026-08-03T23:17:46.351889+00:00` (six fractional digits, an
/// offset) and `2026-08-03T23:10:18.072Z`. `ISO8601DateFormatter` is picky about the former
/// and allocating a formatter inside a sort comparator over thousands of rows is a hazard of
/// its own, so this is plain arithmetic: total, deterministic, locale-free and fast.
///
/// Returns milliseconds since the epoch — the unit the desktop compares in — or `nil` for a
/// missing or unparsable value. A `nil` NEVER becomes `0` here; callers decide what an
/// unknown time means for them (`recencyKey` sinks it, `sortNodes` sinks it).
public enum KilnTimestamp {

    public static func millis(_ raw: String?) -> Double? {
        guard let raw, !raw.isEmpty else { return nil }
        let b = Array(raw.utf8)
        // YYYY-MM-DDTHH:MM:SS is the shortest accepted form.
        guard b.count >= 19 else { return nil }

        func digits(_ from: Int, _ count: Int) -> Int? {
            var out = 0
            for i in from..<(from + count) {
                guard i < b.count, b[i] >= 48, b[i] <= 57 else { return nil }
                out = out * 10 + Int(b[i] - 48)
            }
            return out
        }
        guard let year = digits(0, 4), b[4] == UInt8(ascii: "-"),
              let month = digits(5, 2), b[7] == UInt8(ascii: "-"),
              let day = digits(8, 2),
              b[10] == UInt8(ascii: "T") || b[10] == UInt8(ascii: " "),
              let hour = digits(11, 2), b[13] == UInt8(ascii: ":"),
              let minute = digits(14, 2), b[16] == UInt8(ascii: ":"),
              let second = digits(17, 2)
        else { return nil }
        guard month >= 1, month <= 12, day >= 1, day <= 31 else { return nil }

        var i = 19
        var fractionMs = 0.0
        if i < b.count, b[i] == UInt8(ascii: ".") {
            i += 1
            var scale = 0.1
            while i < b.count, b[i] >= 48, b[i] <= 57 {
                fractionMs += Double(b[i] - 48) * scale * 1000
                scale /= 10
                i += 1
            }
        }

        var offsetSeconds = 0
        if i < b.count {
            let c = b[i]
            if c == UInt8(ascii: "Z") || c == UInt8(ascii: "z") {
                offsetSeconds = 0
            } else if c == UInt8(ascii: "+") || c == UInt8(ascii: "-") {
                guard let oh = digits(i + 1, 2) else { return nil }
                // `+HH:MM` and `+HHMM` both occur in the wild.
                let minuteStart = (i + 3 < b.count && b[i + 3] == UInt8(ascii: ":")) ? i + 4 : i + 3
                let om = digits(minuteStart, 2) ?? 0
                offsetSeconds = (oh * 3600 + om * 60) * (c == UInt8(ascii: "-") ? -1 : 1)
            }
        }

        let days = daysFromCivil(year: year, month: month, day: day)
        let seconds = Double(days) * 86_400 + Double(hour * 3600 + minute * 60 + second)
        return (seconds - Double(offsetSeconds)) * 1000 + fractionMs
    }

    /// Howard Hinnant's civil-from-days, inverted — days since 1970-01-01 for a proleptic
    /// Gregorian date. No Calendar, no locale, no DST: these timestamps are absolute.
    static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    /// Midnight of the LOCAL calendar day containing `ms`. The Time lens's buckets are
    /// calendar-day aligned so "Today" means today, not "the last 24 hours".
    public static func startOfLocalDay(_ ms: Double) -> Double {
        let date = Date(timeIntervalSince1970: ms / 1000)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone.current
        let start = cal.startOfDay(for: date)
        return start.timeIntervalSince1970 * 1000
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// The node model
// ─────────────────────────────────────────────────────────────────────────────

/// One conversation, normalized. Built once from the API rows; every lens groups THESE.
/// A node's identity (`id`) never changes when the lens changes — only its grouping does.
public struct ChatNode: Equatable, Sendable, Identifiable {

    public enum State: String, Equatable, Sendable { case active, archived }

    /// Stable identity — never changes across lenses or filters.
    public let id: String
    public let title: String
    /// ISO ts of last interaction (falls back to creation). `nil` = never.
    public let lastActivity: String?
    public let projectId: String?
    /// Resolved project name, or `nil` for a project-less quick chat.
    public let projectName: String?
    /// Human source label: "Kiln", "FoundryX", "Claude Code", "Codex", or an unrecognised
    /// origin passed through verbatim.
    public let source: String
    public let state: State
    /// The model that answers this chat — the `a:` filter axis. `nil` = unset.
    public let agent: String?
    /// FORK LINEAGE parent (`parent_chat_id`), NOT a subagent parent.
    public let forkParentId: String?
    public let forkFromSeq: Int?
    /// The SUBAGENT parent that spawned this session. A node carrying one is never a
    /// top-level row — `toNodes` drops it. Kept for completeness.
    public let parentTaskId: String?
    /// The recurring-job key when this node stands for a SERIES of firings; `nil` otherwise.
    public let loopId: String?
    /// How many firings this node stands for. `1` for an ordinary chat, so a caller can
    /// render "N×" on exactly the rows where N > 1 without a second lookup.
    public let seriesRuns: Int
    /// The originating row, for everything that still needs the raw shape.
    public let row: LibraryChatRow

    public init(
        id: String, title: String, lastActivity: String?, projectId: String?,
        projectName: String?, source: String, state: State, agent: String?,
        forkParentId: String?, forkFromSeq: Int?, parentTaskId: String?,
        loopId: String?, seriesRuns: Int, row: LibraryChatRow
    ) {
        self.id = id
        self.title = title
        self.lastActivity = lastActivity
        self.projectId = projectId
        self.projectName = projectName
        self.source = source
        self.state = state
        self.agent = agent
        self.forkParentId = forkParentId
        self.forkFromSeq = forkFromSeq
        self.parentTaskId = parentTaskId
        self.loopId = loopId
        self.seriesRuns = seriesRuns
        self.row = row
    }
}

/// The pure port of the desktop rail's node/provenance model.
public enum KilnLibrary {

    // ── toNodes ───────────────────────────────────────────────────────────────

    /// Normalize API rows into the one node model. A faithful port of
    /// `chatLibraryModel.ts:151-213`. Three behaviours are load-bearing:
    ///
    /// 1. A SUBAGENT CHILD (a row whose `parent_task_session_id` is set) is DROPPED from
    ///    the top-level node set. On the desktop it renders nested under its spawning
    ///    parent; surfacing it here too would duplicate it as a loose top-level row. Fork
    ///    lineage (`parent_chat_id`) is unaffected — a fork IS a top-level node.
    ///
    /// 2. A RECURRING JOB collapses to ONE row. Every firing of a scheduled task is its own
    ///    session, so an hourly monitor put 706 loose rows in the rail and buried the
    ///    conversations actually had. The survivor is the MOST RECENT firing (a series row
    ///    should answer "how is this job doing now"), and `seriesRuns` carries the count so
    ///    a caller can say how many the row stands for. The comparison is a STRING
    ///    comparison over `last_message_at ?? started_at ?? ""` — lexicographic, NOT
    ///    date-parsed. That is what the desktop does, and it is kept so the two surfaces
    ///    pick the SAME survivor even on a malformed timestamp.
    ///
    /// 3. An IMPORTED row with no Kiln project gets a SYNTHETIC project keyed by its source
    ///    working directory (`import-cwd:<root>`), labelled with that directory's basename.
    ///    This is what keeps imported conversations out of the Inbox.
    public static func toNodes(
        rows: [LibraryChatRow],
        projects: [KilnProjectRow] = []
    ) -> [ChatNode] {
        var nameById: [String: String] = [:]
        for p in projects { nameById[p.id] = p.name }

        var runsByLoop: [String: Int] = [:]
        var newestByLoop: [String: LibraryChatRow] = [:]
        // The series key the desktop compares on — STRING, deliberately.
        func at(_ x: LibraryChatRow) -> String { x.lastMessageAt ?? x.startedAt ?? "" }
        for r in rows {
            guard let key = kilnTruthy(r.loopId), kilnTruthy(r.parentTaskSessionId) == nil else { continue }
            runsByLoop[key, default: 0] += 1
            if let held = newestByLoop[key] {
                // Strictly greater keeps the FIRST row on a tie — the same as the desktop's
                // `!held || at(r) > at(held)`.
                if at(r) > at(held) { newestByLoop[key] = r }
            } else {
                newestByLoop[key] = r
            }
        }

        return rows
            .filter { kilnTruthy($0.parentTaskSessionId) == nil }
            .filter { r in
                guard let loop = kilnTruthy(r.loopId) else { return true }
                return newestByLoop[loop]?.id == r.id
            }
            .map { r in
                let importCwd = kilnTruthy(r.importProjectRoot)
                let ownProject = kilnTruthy(r.projectId)
                let syntheticProjectId = (ownProject == nil && importCwd != nil)
                    ? "import-cwd:\(importCwd!)" : nil
                let projectId = ownProject ?? syntheticProjectId
                let projectName: String? = {
                    if let ownProject { return nameById[ownProject] ?? ownProject }
                    if let importCwd { return basename(importCwd) }
                    return nil
                }()
                let loopId = kilnTruthy(r.loopId)
                return ChatNode(
                    id: r.id,
                    title: chatTitle(r),
                    // Recomputed from `last_message_at ?? started_at`. The server ALSO sends
                    // `last_activity_at`, and the desktop deliberately IGNORES it — an import
                    // writes `started_at = now` while carrying the real `last_message_at`, and
                    // keying recency off the wrong one is exactly what floated a two-year-old
                    // Codex transcript above this morning's work. Matched so the two surfaces
                    // order identically.
                    lastActivity: r.lastMessageAt ?? r.startedAt,
                    projectId: projectId,
                    projectName: projectName,
                    // A CONTINUED native session wears its ORIGIN-HARNESS badge; its `origin`
                    // stays native so it is never treated as read-only.
                    source: kilnTruthy(r.continuedFromHarness).map(sourceLabel) ?? sourceLabel(r.origin),
                    state: r.archived != 0 ? .archived : .active,
                    agent: r.model,
                    forkParentId: r.parentChatId,
                    forkFromSeq: r.forkFromSeq,
                    parentTaskId: r.parentTaskSessionId,
                    loopId: loopId,
                    seriesRuns: loopId.flatMap { runsByLoop[$0] } ?? 1,
                    row: r)
            }
    }

    /// The last path segment of a working directory, for the imported Project group label.
    static func basename(_ path: String) -> String {
        var trimmed = path
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard let idx = trimmed.lastIndex(of: "/") else { return trimmed }
        let tail = String(trimmed[trimmed.index(after: idx)...])
        return tail.isEmpty ? trimmed : tail
    }

    /// A chat's display title — its stored title, or a short fallback from the session id.
    public static func chatTitle(_ c: LibraryChatRow) -> String {
        let t = (c.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { return t }
        return "Chat \(c.id.prefix(8))"
    }

    /// The set of session ids that SPAWNED at least one subagent child — every value some
    /// row names in its `parent_task_session_id`. A top-level row whose id is in this set
    /// HAS children; the phone cannot expand them (that needs `GET /sessions/:id/children`,
    /// which the door does not proxy), so a caller must say so honestly rather than offer a
    /// disclosure control that opens onto nothing.
    public static func parentSessionIds(_ rows: [LibraryChatRow]) -> Set<String> {
        var ids = Set<String>()
        for r in rows {
            if let p = kilnTruthy(r.parentTaskSessionId) { ids.insert(p) }
        }
        return ids
    }

    // ── Provenance (chatLibraryModel.ts:734-773) ─────────────────────────────

    /// The recognized foreign-harness origins (the `origin` values imported rows carry).
    static let importHarnessLabels: [String: String] = [
        "claude-code": "Claude Code",
        "codex-cli": "Codex",
    ]

    /// Map a row's `origin` to its human source label. An unknown origin passes through
    /// UNCHANGED — fail-loud: an unrecognised origin surfaces its raw value, never a
    /// silently-wrong "Kiln".
    public static func sourceLabel(_ origin: String) -> String {
        if origin == "foundryx" { return "FoundryX" }
        if origin == "kiln" { return "Kiln" }
        return importHarnessLabels[origin] ?? origin
    }

    /// True when a node was imported from a foreign harness (not born in Kiln/FoundryX).
    ///
    /// This answers PROVENANCE only — "where did this conversation come from" — which is
    /// PERMANENT: a resumed row is still imported and still wears its harness badge. It does
    /// NOT answer writability; that is `isReadOnlyChat`.
    public static func isImportedOrigin(_ origin: String) -> Bool {
        importHarnessLabels[origin] != nil
    }

    /// RESUME-IN-PLACE — true when a conversation may NOT be typed into: imported foreign
    /// history that has not been continued yet.
    ///
    /// Continuing an imported conversation flips THIS SAME ROW from read-only to live
    /// (`resumed: true`) — it keeps its id, its `origin`, its transcript and its provenance;
    /// nothing is copied and no second chat is minted. So writability is a two-field question
    /// and `resumed` must never be folded into `isImportedOrigin`: doing that would strip the
    /// harness badge off a conversation whose provenance is a permanent fact.
    public static func isReadOnlyChat(_ row: LibraryChatRow) -> Bool {
        isImportedOrigin(row.origin) && !row.resumed
    }

    /// A conversation's SOURCE as a compact row badge: a 2-3 char tag plus the full label.
    public static func sourceTag(_ source: String) -> (short: String, label: String) {
        switch source {
        case "FoundryX": return ("FDX", "FoundryX")
        case "Kiln": return ("KLN", "Kiln")
        case "Claude Code": return ("CC", "Claude Code")
        case "Codex": return ("CDX", "Codex")
        default:
            return (String(source.prefix(3)).uppercased(), source.isEmpty ? "Unknown" : source)
        }
    }

    // ── The source-gone asymmetry (importRender.ts:33-54) ────────────────────

    /// The `source_state` values that affirmatively mean "the source file is not there".
    static let sourceGoneStates: Set<String> = ["missing", "evicted", "absent", "deleted", "gone"]

    /// Is this conversation's native source transcript KNOWN to be gone?
    ///
    /// ASYMMETRIC BY DESIGN, and this asymmetry is the whole point of the function:
    ///   * an affirmative gone value is BELIEVED — nothing reports a file missing by accident;
    ///   * `"present"`, an unrecognised value, and an ABSENT field all return false, which
    ///     means "we do not know", NOT "the file is there". **No caller may turn a `false`
    ///     here into an assurance.**
    ///
    /// The measured reason: on 2026-08-02 the live store reported `source_state = 'present'`
    /// for all 10,043 imported rows naming a source file, while 2,302 of those files (22.9%)
    /// no longer existed, because the engine never called the eviction observer. Trusting
    /// `'present'` would have told 2,302 conversations their transcript was safely on disk.
    /// Trusting only the affirmative direction is wrong-but-quiet while the bug persists, and
    /// correct the moment it is fixed — never loud-and-wrong in either state.
    ///
    /// Do NOT "simplify" this into a symmetric present/absent flag.
    public static func sourceIsGone(_ row: LibraryChatRow) -> Bool {
        let state = (row.sourceState ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return sourceGoneStates.contains(state)
    }

    /// The partial-import marker text for a row, or `nil` when the import was clean.
    ///
    /// HONESTY INVARIANT: when `import_partial` is true this MUST return a non-nil,
    /// reason-bearing string. A partial import that returned `nil` here would render as if
    /// it were complete — a silent omission. Even a missing reason still surfaces the FACT
    /// of partiality.
    public static func partialMarker(_ row: LibraryChatRow) -> String? {
        guard row.importPartial else { return nil }
        let reason = (row.importPartialReason ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return reason.isEmpty
            ? "Partial import — some source content could not be rendered"
            : "Partial import — \(reason)"
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// What one conversation is allowed to say about itself
// ─────────────────────────────────────────────────────────────────────────────

/// The honest posture of an open conversation: where it came from, whether it can be typed
/// into, whether the import was lossy, and what — if anything — is known about its original
/// transcript.
public struct KilnConversationNotice: Equatable, Sendable {

    /// What is known about the NATIVE SOURCE TRANSCRIPT this conversation was imported from.
    ///
    /// There are exactly TWO cases, and that is deliberate. There is no `.present`: an
    /// affirmative "gone" is believed, and everything else — `"present"`, an unrecognised
    /// value, an absent field — is `.unknown`, which the UI renders as SILENCE. Silence is
    /// the honest rendering of "we do not know". Adding a `.present` case, or letting
    /// `.unknown` render a reassuring sentence, would turn a measured 22.9% false-`present`
    /// rate into 2,302 conversations being told their transcript is safely on disk.
    public enum SourcePresence: Equatable, Sendable {
        case gone(headline: String, reassurance: String, noticedAt: String?, evidence: String?)
        case unknown
    }

    /// PROVENANCE — permanent. Stays true after the conversation is picked up.
    public let imported: Bool
    /// RESUME-IN-PLACE — this row has been continued and is live in Kiln.
    public let resumed: Bool
    /// No composer is offered: imported foreign history that has not been picked up yet.
    public let readOnly: Bool
    /// "Claude Code" | "Codex" | the native source label.
    public let originLabel: String
    /// Non-nil ⇒ show the partial-import marker. Never silenced.
    public let partialMarker: String?
    public let sourcePresence: SourcePresence

    /// True ⇒ offer the pick-up. Exactly `isImportedOrigin && !resumed`.
    public var offersPickUp: Bool { readOnly }

    /// The one sentence the source-presence state is allowed to render, or `nil` for silence.
    /// `.unknown` MUST be nil — that is the whole contract.
    public var sourceLine: String? {
        if case .gone(let headline, _, _, _) = sourcePresence { return headline }
        return nil
    }

    public static func make(_ row: LibraryChatRow) -> KilnConversationNotice {
        let label = KilnLibrary.sourceLabel(row.origin)
        // The source-gone notice is rendered WHETHER OR NOT the conversation has been
        // resumed. It is the one fact a reader needs BEFORE deciding to pick something up,
        // and gating it on "not yet resumed" would hide it from exactly the person who acted.
        let presence: SourcePresence = KilnLibrary.sourceIsGone(row)
            ? .gone(
                headline: "Its \(label) transcript is gone",
                reassurance: "Nothing is lost and nothing needs recovering",
                noticedAt: kilnTruthy(row.sourceEvictedAt).map { "Noticed missing \($0)." },
                // Surfaced VERBATIM — it is the engine's own evidence, not ours to reword.
                evidence: kilnTruthy(row.sourceEvidence))
            : .unknown
        return KilnConversationNotice(
            imported: KilnLibrary.isImportedOrigin(row.origin),
            resumed: row.resumed,
            readOnly: KilnLibrary.isReadOnlyChat(row),
            originLabel: label,
            partialMarker: KilnLibrary.partialMarker(row),
            sourcePresence: presence)
    }
}

/// The user-facing words the library surface uses. Kept here, beside the logic that decides
/// WHEN each is shown, so a Brine scenario can assert the sentence and not just a boolean.
public enum KilnLibraryCopy {

    /// The `{n}×` badge a SERIES row wears. `nil` for an ordinary conversation.
    ///
    /// A row standing for many firings without this badge is a LIE — 706 conversations
    /// collapsed into one row that presents itself as one conversation. The collapse is only
    /// honest if the row says what it stands for.
    public static func seriesBadge(_ n: ChatNode) -> String? {
        guard n.loopId != nil, n.seriesRuns > 1 else { return nil }
        return "\(n.seriesRuns)×"
    }

    /// The honest affordance for a row that SPAWNED subagent work.
    ///
    /// The phone cannot expand these: that needs `GET /sessions/:id/children`, which the door
    /// does not proxy. So this says the work EXISTS and stops — it is deliberately not a
    /// disclosure control, because a control that opens onto nothing is worse than a
    /// sentence that admits the limit.
    public static func subagentNote(_ n: ChatNode, parentIds: Set<String>) -> String? {
        guard parentIds.contains(n.id) else { return nil }
        return "Has subagent work · open on your Mac to see it"
    }

    /// The pick-up button and the sentence beside it.
    ///
    /// The surrounding copy has to say RESUME-IN-PLACE out loud, because the alternative
    /// people expect — "continue" meaning "make me a copy to work in" — is the wrong mental
    /// model and would make the same id showing up on the Mac look like a bug.
    public static let pickUpAction = "Pick up here"
    public static func pickUpBlurb(_ notice: KilnConversationNotice) -> String {
        "Picks this same conversation back up — same conversation, same history, "
        + "now live in Kiln. Nothing is copied and no second chat is made."
    }

    /// A GENUINELY empty library. Never shown for a failure — see `DoorFailureMessage`.
    public static let emptyTitle = "No conversations yet"
    public static let emptyMessage =
        "Conversations you have in Kiln, Claude Code or Codex will show up here."
}
