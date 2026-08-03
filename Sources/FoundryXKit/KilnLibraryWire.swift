// KilnLibraryWire.swift — the wire shapes of Kiln's SHARED conversation library, as the
// desktop door relays them to the phone.
//
// WHY THIS EXISTS. Until these routes, the phone could only ever see chats it itself
// created: `POST /foundryx/chat` opens-or-resumes by `(platform, chat_id)`, a key only the
// phone mints. The door and the Kiln desktop are attached to ONE store holding every
// conversation — Kiln's own, FoundryX's, and every imported Claude Code / Codex CLI
// transcript. These DTOs are how the phone finally reads that store.
//
// TOLERANCE IS THE CONTRACT. The upstream rows are serde structs with
// `skip_serializing_if` on eight fields, so those fields are ABSENT — not null — when
// unset. Measured on the live store (10,236 rows, 2026-08-02): a decoder that REQUIRES any
// of them fails on roughly 9,300 rows. Every field here is `decodeIfPresent … ?? default`,
// the same house rule `CaptureContent.init(from:)` and `KnownPerson.init(from:)` follow.

import Foundation

/// One row of Kiln's conversation library (`GET /chats/library`, relayed by the door as
/// `GET /foundryx/chats`). Field names are serde's verbatim names — the upstream struct has
/// no `rename_all`, so the wire keys are exactly the Rust field names.
public struct LibraryChatRow: Decodable, Sendable, Equatable, Identifiable {

    // ── Always present on the wire ────────────────────────────────────────────

    /// The conversation's stable id. An IMPORTED conversation's id is STRUCTURED and
    /// contains colons — e.g. `import:claude-code:workflows:wf_ae593755-e61:abbdae8d72a12b0fc`.
    /// Nothing downstream may percent-encode those colons away or validate them out of
    /// existence: doing either makes every imported conversation unreachable.
    public let id: String
    public let title: String?
    public let model: String?
    public let projectId: String?
    /// `kiln` | `foundryx` | `claude-code` | `codex-cli`. An unrecognised value passes
    /// through verbatim (see `sourceLabel`) rather than being silently called "Kiln".
    public let origin: String
    public let sensitivity: String?
    /// A NUMBER (0/1) on the wire, never a JSON bool. Decoded tolerantly either way so a
    /// future upstream that switches to a bool does not blank the whole library.
    public let archived: Int
    public let startedAt: String?
    public let org: String
    /// FORK lineage — written ONLY by `fork_chat`. This is NOT a subagent edge; see
    /// `parentTaskSessionId`, which is a different axis entirely.
    public let parentChatId: String?
    public let forkFromSeq: Int?
    public let lastMessagePreview: String?
    public let lastMessageAt: String?
    public let lastActivityAt: String?
    /// The recurring-job key. `""` when this is not a series firing — never null.
    public let loopId: String
    /// The SUBAGENT parent that spawned this session. A row with this set is a child and
    /// never a top-level library row.
    public let parentTaskSessionId: String?

    // ── ABSENT, not null, when unset (`skip_serializing_if` upstream) ─────────

    /// The working directory an imported conversation ran in. Load-bearing: it becomes a
    /// SYNTHETIC project, which is what keeps imports out of the Inbox.
    public let importProjectRoot: String?
    /// Absent when false.
    public let importPartial: Bool
    public let importPartialReason: String?
    /// A NATIVE session continued from a foreign harness carries its origin harness here;
    /// its own `origin` stays "kiln".
    public let continuedFromHarness: String?
    /// Absent when false. RESUME-IN-PLACE: an imported row that has been picked up flips
    /// THIS field, keeping its id, origin and transcript.
    public let resumed: Bool
    public let sourceState: String?
    public let sourceEvictedAt: String?
    /// A JSON *string* (not an object) — surfaced verbatim, never re-interpreted.
    public let sourceEvidence: String?

    public init(
        id: String,
        title: String? = nil,
        model: String? = nil,
        projectId: String? = nil,
        origin: String = "kiln",
        sensitivity: String? = nil,
        archived: Int = 0,
        startedAt: String? = nil,
        org: String = "personal",
        parentChatId: String? = nil,
        forkFromSeq: Int? = nil,
        lastMessagePreview: String? = nil,
        lastMessageAt: String? = nil,
        lastActivityAt: String? = nil,
        loopId: String = "",
        parentTaskSessionId: String? = nil,
        importProjectRoot: String? = nil,
        importPartial: Bool = false,
        importPartialReason: String? = nil,
        continuedFromHarness: String? = nil,
        resumed: Bool = false,
        sourceState: String? = nil,
        sourceEvictedAt: String? = nil,
        sourceEvidence: String? = nil
    ) {
        self.id = id
        self.title = title
        self.model = model
        self.projectId = projectId
        self.origin = origin
        self.sensitivity = sensitivity
        self.archived = archived
        self.startedAt = startedAt
        self.org = org
        self.parentChatId = parentChatId
        self.forkFromSeq = forkFromSeq
        self.lastMessagePreview = lastMessagePreview
        self.lastMessageAt = lastMessageAt
        self.lastActivityAt = lastActivityAt
        self.loopId = loopId
        self.parentTaskSessionId = parentTaskSessionId
        self.importProjectRoot = importProjectRoot
        self.importPartial = importPartial
        self.importPartialReason = importPartialReason
        self.continuedFromHarness = continuedFromHarness
        self.resumed = resumed
        self.sourceState = sourceState
        self.sourceEvictedAt = sourceEvictedAt
        self.sourceEvidence = sourceEvidence
    }

    enum CodingKeys: String, CodingKey {
        case id, title, model, origin, sensitivity, archived, org, resumed
        case projectId = "project_id"
        case startedAt = "started_at"
        case parentChatId = "parent_chat_id"
        case forkFromSeq = "fork_from_seq"
        case lastMessagePreview = "last_message_preview"
        case lastMessageAt = "last_message_at"
        case lastActivityAt = "last_activity_at"
        case loopId = "loop_id"
        case parentTaskSessionId = "parent_task_session_id"
        case importProjectRoot = "import_project_root"
        case importPartial = "import_partial"
        case importPartialReason = "import_partial_reason"
        case continuedFromHarness = "continued_from_harness"
        case sourceState = "source_state"
        case sourceEvictedAt = "source_evicted_at"
        case sourceEvidence = "source_evidence"
    }

    /// EVERY field except `id` is optional-with-a-default. `id` is identity — a row without
    /// one is not a conversation and there is nothing honest to substitute.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        model = try c.decodeIfPresent(String.self, forKey: .model)
        projectId = try c.decodeIfPresent(String.self, forKey: .projectId)
        origin = (try c.decodeIfPresent(String.self, forKey: .origin)) ?? ""
        sensitivity = try c.decodeIfPresent(String.self, forKey: .sensitivity)
        // A number today; a bool would still decode rather than blanking the library.
        if let n = (try? c.decodeIfPresent(Int.self, forKey: .archived)) ?? nil {
            archived = n
        } else if let b = (try? c.decodeIfPresent(Bool.self, forKey: .archived)) ?? nil {
            archived = b ? 1 : 0
        } else {
            archived = 0
        }
        startedAt = try c.decodeIfPresent(String.self, forKey: .startedAt)
        org = (try c.decodeIfPresent(String.self, forKey: .org)) ?? ""
        parentChatId = try c.decodeIfPresent(String.self, forKey: .parentChatId)
        forkFromSeq = try c.decodeIfPresent(Int.self, forKey: .forkFromSeq)
        lastMessagePreview = try c.decodeIfPresent(String.self, forKey: .lastMessagePreview)
        lastMessageAt = try c.decodeIfPresent(String.self, forKey: .lastMessageAt)
        lastActivityAt = try c.decodeIfPresent(String.self, forKey: .lastActivityAt)
        loopId = (try c.decodeIfPresent(String.self, forKey: .loopId)) ?? ""
        parentTaskSessionId = try c.decodeIfPresent(String.self, forKey: .parentTaskSessionId)
        importProjectRoot = try c.decodeIfPresent(String.self, forKey: .importProjectRoot)
        importPartial = (try c.decodeIfPresent(Bool.self, forKey: .importPartial)) ?? false
        importPartialReason = try c.decodeIfPresent(String.self, forKey: .importPartialReason)
        continuedFromHarness = try c.decodeIfPresent(String.self, forKey: .continuedFromHarness)
        resumed = (try c.decodeIfPresent(Bool.self, forKey: .resumed)) ?? false
        sourceState = try c.decodeIfPresent(String.self, forKey: .sourceState)
        sourceEvictedAt = try c.decodeIfPresent(String.self, forKey: .sourceEvictedAt)
        sourceEvidence = try c.decodeIfPresent(String.self, forKey: .sourceEvidence)
    }
}

/// One page of the library (`GET /foundryx/chats?limit=&offset=&q=`).
///
/// `snapshot` is the store's read-consistency token: the desktop echoes it back on every
/// page AFTER the first, or the OFFSET window shifts under a library that is still being
/// written to. The door does NOT currently forward a `snapshot` parameter upstream
/// (`chats_library_url` builds only `limit`/`offset`/`q`), so the phone can decode the token
/// but cannot yet return it. Recorded as a known limitation rather than papered over.
public struct LibraryPage: Decodable, Sendable, Equatable {
    public let chats: [LibraryChatRow]
    public let total: Int
    public let totalIsLowerBound: Bool
    public let limit: Int
    public let offset: Int
    public let snapshot: Int?
    public let hasMore: Bool
    public let stores: [String]

    public init(
        chats: [LibraryChatRow],
        total: Int = 0,
        totalIsLowerBound: Bool = false,
        limit: Int = 50,
        offset: Int = 0,
        snapshot: Int? = nil,
        hasMore: Bool = false,
        stores: [String] = []
    ) {
        self.chats = chats
        self.total = total
        self.totalIsLowerBound = totalIsLowerBound
        self.limit = limit
        self.offset = offset
        self.snapshot = snapshot
        self.hasMore = hasMore
        self.stores = stores
    }

    enum CodingKeys: String, CodingKey {
        case chats, total, limit, offset, snapshot, stores
        case totalIsLowerBound = "total_is_lower_bound"
        case hasMore = "has_more"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        chats = (try c.decodeIfPresent([LibraryChatRow].self, forKey: .chats)) ?? []
        total = (try c.decodeIfPresent(Int.self, forKey: .total)) ?? 0
        totalIsLowerBound = (try c.decodeIfPresent(Bool.self, forKey: .totalIsLowerBound)) ?? false
        limit = (try c.decodeIfPresent(Int.self, forKey: .limit)) ?? 0
        offset = (try c.decodeIfPresent(Int.self, forKey: .offset)) ?? 0
        snapshot = try c.decodeIfPresent(Int.self, forKey: .snapshot)
        hasMore = (try c.decodeIfPresent(Bool.self, forKey: .hasMore)) ?? false
        stores = (try c.decodeIfPresent([String].self, forKey: .stores)) ?? []
    }
}

/// `GET /foundryx/chat-org?org=<scope>` → `{"doc": "<opaque JSON string>"}` or `{"doc": null}`.
///
/// `doc` is DOUBLE-ENCODED: a JSON *string* whose contents are themselves the org document.
/// `null` means the document was never persisted — a fresh workspace with no groups. That is
/// a legitimate success, not a failure, and must never be surfaced as one.
public struct ChatOrgEnvelope: Decodable, Sendable, Equatable {
    public let doc: String?
    public init(doc: String?) { self.doc = doc }
}

/// One turn of a conversation's transcript (`GET /foundryx/chats/<id>/messages`).
///
/// The upstream turn nests its text under `parts` (`{role, text, tool_calls, tool_result}`)
/// and numbers its `id`. Both are normalised here so the phone renders one flat shape.
public struct KilnMessage: Decodable, Sendable, Equatable, Identifiable {
    public let id: String
    public let role: String
    public let text: String
    /// True ⇒ this turn came in with the import, not from a live Kiln exchange.
    public let imported: Bool

    public init(id: String, role: String, text: String, imported: Bool = false) {
        self.id = id
        self.role = role
        self.text = text
        self.imported = imported
    }

    enum CodingKeys: String, CodingKey { case id, role, parts, text, imported }
    private struct Parts: Decodable { let role: String?; let text: String? }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // The turn id is a NUMBER upstream; a string form still decodes.
        if let n = (try? c.decodeIfPresent(Int.self, forKey: .id)) ?? nil {
            id = String(n)
        } else {
            id = ((try? c.decodeIfPresent(String.self, forKey: .id)) ?? nil) ?? UUID().uuidString
        }
        let parts = (try? c.decodeIfPresent(Parts.self, forKey: .parts)) ?? nil
        role = (try c.decodeIfPresent(String.self, forKey: .role))
            ?? parts?.role
            ?? "assistant"
        text = try parts?.text
            ?? c.decodeIfPresent(String.self, forKey: .text)
            ?? ""
        imported = (try c.decodeIfPresent(Bool.self, forKey: .imported)) ?? false
    }
}

/// The transcript envelope the messages route returns.
public struct KilnMessagePage: Decodable, Sendable, Equatable {
    public let messages: [KilnMessage]
    public init(messages: [KilnMessage]) { self.messages = messages }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        messages = (try c.decodeIfPresent([KilnMessage].self, forKey: .messages)) ?? []
    }
    enum CodingKeys: String, CodingKey { case messages }
}

/// The result of picking an imported conversation up
/// (`POST /foundryx/chats/<id>/continue`).
///
/// RESUME-IN-PLACE: `sessionId` is ALWAYS the id that was posted to. Continuing flips that
/// same row live — same id, same transcript, same provenance. A DIFFERENT id here is a
/// contract violation and the caller must surface it as an error rather than quietly
/// navigating somewhere else.
public struct KilnContinueResult: Decodable, Sendable, Equatable {
    public let sessionId: String
    public let harness: String
    public let sourceConversationId: String
    public let sourceFile: String
    public let sensitivity: String
    public let seededTurns: Int
    public let nativeWriteback: String?
    public let nativeWritebackDetail: String?

    public init(
        sessionId: String,
        harness: String = "",
        sourceConversationId: String = "",
        sourceFile: String = "",
        sensitivity: String = "",
        seededTurns: Int = 0,
        nativeWriteback: String? = nil,
        nativeWritebackDetail: String? = nil
    ) {
        self.sessionId = sessionId
        self.harness = harness
        self.sourceConversationId = sourceConversationId
        self.sourceFile = sourceFile
        self.sensitivity = sensitivity
        self.seededTurns = seededTurns
        self.nativeWriteback = nativeWriteback
        self.nativeWritebackDetail = nativeWritebackDetail
    }

    enum CodingKeys: String, CodingKey {
        case harness, sensitivity
        case sessionId = "session_id"
        case sourceConversationId = "source_conversation_id"
        case sourceFile = "source_file"
        case seededTurns = "seeded_turns"
        case nativeWriteback = "native_writeback"
        case nativeWritebackDetail = "native_writeback_detail"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = (try c.decodeIfPresent(String.self, forKey: .sessionId)) ?? ""
        harness = (try c.decodeIfPresent(String.self, forKey: .harness)) ?? ""
        sourceConversationId = (try c.decodeIfPresent(String.self, forKey: .sourceConversationId)) ?? ""
        sourceFile = (try c.decodeIfPresent(String.self, forKey: .sourceFile)) ?? ""
        sensitivity = (try c.decodeIfPresent(String.self, forKey: .sensitivity)) ?? ""
        seededTurns = (try c.decodeIfPresent(Int.self, forKey: .seededTurns)) ?? 0
        nativeWriteback = try c.decodeIfPresent(String.self, forKey: .nativeWriteback)
        nativeWritebackDetail = try c.decodeIfPresent(String.self, forKey: .nativeWritebackDetail)
    }
}

/// A Kiln PROJECT row — id → display name.
///
/// The door proxies no projects route, so the phone builds the library with an EMPTY project
/// list. That is not a silent degradation: `toNodes` already falls back to the raw
/// `project_id` as the label when a name is unknown, which is the DESKTOP's own fallback
/// (`nameById.get(id) ?? id`). Grouping is identical; only the human label differs.
public struct KilnProjectRow: Decodable, Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// Why a library read did not produce a library.
///
/// THIS DISTINCTION IS THE WHOLE POINT. The door deliberately answers 503 (it holds no
/// kiln-session URL at all) and 502 (the session is unreachable or refused) and NEVER an
/// empty list — because an empty list reads on the phone as "you have no conversations"
/// when the truth is "the door could not ask". The client must not collapse those into a
/// `[]`, and the UI must not render them as an empty library.
public enum KilnLibraryError: Error, Equatable, Sendable {
    /// 503 — the door has no kiln-session at all.
    case noSession
    /// 502 — the door could not reach the session, or a transport failure on our side.
    case unreachable
    /// 401 — rejected before anything was read.
    case unauthorized
    /// Any other non-200.
    case http(Int)
}
