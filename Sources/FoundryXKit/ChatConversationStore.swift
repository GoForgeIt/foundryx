// ChatConversationStore — the FoundryX chat surface's list of resumable conversations.
//
// Each Conversation owns a stable `id` that IS the kiln-session `chat_id` the phone
// sends to the door. Because kiln-session open-or-resumes by (platform, chat_id, org),
// a distinct id per conversation is a distinct, concurrent server-side session whose
// LLM context Kiln preserves across turns — so "session-based chat" is achieved simply
// by giving each conversation its own id (instead of the legacy hardcoded "ios").
//
// The store is the DURABLE source of truth for the conversation list + each chat's
// history; the live ChatViewModel renders the active one. ObservableObject (not
// @Observable) keeps it buildable on the package's macOS 13 floor; the iOS app uses the
// same type unchanged.

import Foundation

public final class ChatConversationStore: ObservableObject {

    /// One persisted message in a conversation's history.
    public struct StoredMessage: Codable, Equatable, Sendable {
        public var role: String        // "user" | "assistant"
        public var text: String
        public var routedVia: String?  // the target_id that handled an assistant turn

        public init(role: String, text: String, routedVia: String? = nil) {
            self.role = role
            self.text = text
            self.routedVia = routedVia
        }
    }

    /// Where a chat came from (track 20260715T1500 EXT3): tagged at creation so
    /// the list can be organized by provenance. All fields optional-shaped so
    /// pre-provenance persisted chats keep decoding (nil ⇒ started by the user).
    public struct ChatOrigin: Codable, Equatable, Sendable {
        /// "action" (born from a surfaced action / accepted ambient card) or
        /// "manual" (the user started it).
        public let kind: String
        /// The source conversation, when known.
        public let captureId: String?
        /// The action's utterance join key (clipped to 200, like every other
        /// join in the pipeline).
        public let actionKey: String?
        /// The source conversation's category NAME at creation (e.g. Personal).
        public let category: String?

        public init(kind: String, captureId: String? = nil,
                    actionKey: String? = nil, category: String? = nil) {
            self.kind = kind
            self.captureId = captureId
            self.actionKey = actionKey
            self.category = category
        }

        public static let manual = ChatOrigin(kind: "manual")
        public static func action(captureId: String? = nil, actionKey: String? = nil,
                                  category: String? = nil) -> ChatOrigin {
            ChatOrigin(kind: "action", captureId: captureId,
                       actionKey: actionKey.map(ConversationActions.utteranceKey),
                       category: category)
        }
    }

    /// A single chat thread. `id` is the kiln-session `chat_id`. `modelTargetId` is the
    /// chosen Kiln target (nil ⇒ "Auto (router)").
    public struct Conversation: Identifiable, Codable, Equatable, Sendable {
        public let id: String
        public var title: String
        public var messages: [StoredMessage]
        public var modelTargetId: String?
        public var createdAt: Date
        public var updatedAt: Date
        /// Provenance (EXT3). Optional so legacy persisted chats decode; nil
        /// reads as "started by me".
        public var origin: ChatOrigin?

        /// True when this chat was born from a conversation's surfaced action
        /// (or an accepted ambient card) rather than started by hand.
        public var isFromConversation: Bool { origin?.kind == "action" }

        public init(id: String = UUID().uuidString,
                    title: String = "New chat",
                    messages: [StoredMessage] = [],
                    modelTargetId: String? = nil,
                    createdAt: Date = Date(),
                    updatedAt: Date = Date(),
                    origin: ChatOrigin? = nil) {
            self.id = id
            self.title = title
            self.messages = messages
            self.modelTargetId = modelTargetId
            self.createdAt = createdAt
            self.updatedAt = updatedAt
            self.origin = origin
        }
    }

    /// The legacy single-thread id every turn used before this track. A new conversation
    /// must never reuse it (AC1) — kept as a named constant so the rule is explicit.
    public static let legacyChatId = "ios"

    /// Conversations, most-recently-updated first.
    @Published public private(set) var conversations: [Conversation] = []
    /// The active conversation's id (what the chat screen renders + sends to).
    @Published public private(set) var activeId: String = ""

    /// Where the list is persisted as JSON (nil ⇒ in-memory only, for tests).
    private let storageURL: URL?
    /// Stable per-turn metadata (the phone never changes these mid-session).
    public let platform: String
    public let org: String

    /// `storageURL == nil` ⇒ ephemeral (tests). The production app passes the default
    /// Application Support location via `defaultStorageURL()`. Seeds one empty
    /// conversation when there's nothing persisted so the UI always has an active chat.
    public init(storageURL: URL? = nil, platform: String = "foundryx", org: String = "acme") {
        self.storageURL = storageURL
        self.platform = platform
        self.org = org
        load()
        if conversations.isEmpty {
            let seed = Conversation()
            conversations = [seed]
            activeId = seed.id
            persist()
        } else if !conversations.contains(where: { $0.id == activeId }) {
            activeId = conversations[0].id
        }
    }

    // MARK: - Reads

    public var active: Conversation? {
        conversations.first(where: { $0.id == activeId })
    }

    public func conversation(_ id: String) -> Conversation? {
        conversations.first(where: { $0.id == id })
    }

    // MARK: - Lifecycle

    /// Mint a brand-new conversation, make it active, return it. Its id is a fresh UUID —
    /// distinct from every existing conversation AND from the legacy "ios" id (AC1).
    @discardableResult
    public func newConversation(modelTargetId: String? = nil,
                                origin: ChatOrigin = .manual) -> Conversation {
        // Inherit the previous active chat's model so a "new chat" keeps the user's pick.
        let inherited = modelTargetId ?? active?.modelTargetId
        let convo = Conversation(modelTargetId: inherited, origin: origin)
        conversations.insert(convo, at: 0)
        activeId = convo.id
        persist()
        UsageHook.action("chat_convo_new")   // content-free: a count, no title/text
        return convo
    }

    /// Switch the active conversation (no-op if unknown). History is preserved because
    /// each conversation carries its own `messages` (AC2).
    public func select(_ id: String) {
        guard conversations.contains(where: { $0.id == id }) else { return }
        activeId = id
    }

    /// Delete a conversation; keeps at least one chat alive (seeds a fresh one if the
    /// list would empty), and re-points `activeId` if the active one was removed.
    public func delete(_ id: String) {
        conversations.removeAll { $0.id == id }
        UsageHook.action("chat_convo_delete")   // content-free: a count, no title/text
        if conversations.isEmpty {
            let seed = Conversation()
            conversations = [seed]
            activeId = seed.id
        } else if activeId == id {
            activeId = conversations[0].id
        }
        persist()
    }

    // MARK: - Mutations

    /// Set the chosen model (target_id) for a conversation. nil ⇒ "Auto (router)".
    public func setModel(_ targetId: String?, for id: String) {
        mutate(id) { $0.modelTargetId = targetId }
    }

    /// Replace a conversation's whole message history (used to snapshot the live
    /// ChatViewModel back into the durable store at end-of-turn).
    public func setMessages(_ messages: [StoredMessage], for id: String) {
        mutate(id) { convo in
            convo.messages = messages
            // Derive a human title from the first user message (once), like the apps do.
            if convo.title == "New chat" || convo.title.isEmpty,
               let first = messages.first(where: { $0.role == "user" && !$0.text.isEmpty }) {
                convo.title = Self.deriveTitle(first.text)
            }
        }
        bumpToFront(id)
    }

    /// Build the outbound chat request for a turn in conversation `id`, carrying that
    /// conversation's `chat_id` and selected model (omitted ⇒ router). This is the single
    /// place the (chat_id, requested_target) contract is assembled.
    public func chatRequest(text: String, for id: String) -> ChatRequest {
        let convo = conversation(id)
        // Provenance rides the FIRST turn only (session-open semantics, EXT3),
        // and only for conversation-born chats — absence means manual, so a
        // hand-started chat ships the same six-field body it always did. The
        // door's ChatReq is serde-tolerant: old desktops ignore the fields; a
        // desktop that learns them can tag the kiln session at open.
        let shipOrigin = (convo?.messages.isEmpty ?? true)
            && convo?.isFromConversation == true
        return ChatRequest(message: text,
                           platform: platform,
                           chatId: id,
                           org: org,
                           requestedTarget: convo?.modelTargetId,
                           origin: shipOrigin ? convo?.origin?.kind : nil,
                           originCaptureId: shipOrigin ? convo?.origin?.captureId : nil,
                           originCategory: shipOrigin ? convo?.origin?.category : nil)
    }

    // MARK: - Helpers

    private func mutate(_ id: String, _ change: (inout Conversation) -> Void) {
        guard let idx = conversations.firstIndex(where: { $0.id == id }) else { return }
        change(&conversations[idx])
        conversations[idx].updatedAt = Date()
        persist()
    }

    private func bumpToFront(_ id: String) {
        guard let idx = conversations.firstIndex(where: { $0.id == id }), idx != 0 else { return }
        let convo = conversations.remove(at: idx)
        conversations.insert(convo, at: 0)
        persist()
    }

    /// A short title from the first user message: first line, trimmed, ≤ 48 chars.
    static func deriveTitle(_ text: String) -> String {
        let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        let trimmed = firstLine.trimmingCharacters(in: .whitespaces)
        if trimmed.count <= 48 { return trimmed.isEmpty ? "New chat" : trimmed }
        return String(trimmed.prefix(47)).trimmingCharacters(in: .whitespaces) + "…"
    }

    // MARK: - Persistence

    private struct Persisted: Codable {
        var conversations: [Conversation]
        var activeId: String
    }

    private func load() {
        guard let url = storageURL,
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder.iso8601.decode(Persisted.self, from: data) else { return }
        conversations = decoded.conversations
        activeId = decoded.activeId
    }

    private func persist() {
        guard let url = storageURL else { return }
        let snapshot = Persisted(conversations: conversations, activeId: activeId)
        guard let data = try? JSONEncoder.iso8601.encode(snapshot) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    /// The default on-device location for the conversation list.
    public static func defaultStorageURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("FoundryX/chat-conversations.json")
    }
}

// MARK: - List organization (EXT3)

/// Pure provenance/category filtering + source grouping over the chat list —
/// what ChatListSheet renders. Kit-level so the Brine step-defs drive the real
/// logic the UI uses.
public enum ChatListOrganizer {
    public enum Provenance: String, CaseIterable, Sendable {
        case all = "All"
        case fromConversations = "From conversations"
        case startedByMe = "Started by me"
    }

    /// Apply the provenance pill + (optional) category pill. A nil category
    /// means no category filter. Legacy chats (nil origin) read as started-by-me.
    public static func filter(_ conversations: [ChatConversationStore.Conversation],
                              provenance: Provenance,
                              category: String? = nil) -> [ChatConversationStore.Conversation] {
        conversations.filter { convo in
            switch provenance {
            case .all: break
            case .fromConversations: guard convo.isFromConversation else { return false }
            case .startedByMe: guard !convo.isFromConversation else { return false }
            }
            if let category {
                guard convo.origin?.category == category else { return false }
            }
            return true
        }
    }

    /// The distinct source categories present (for the category pills), sorted.
    public static func categories(
        of conversations: [ChatConversationStore.Conversation]
    ) -> [String] {
        Set(conversations.compactMap { $0.origin?.category }).sorted()
    }

    /// One section of the source-grouped list: the source conversation (nil =
    /// no known source — accepted-card chats and hand-started ones) + its chats.
    public struct SourceGroup: Equatable, Sendable {
        public let captureId: String?
        public let conversations: [ChatConversationStore.Conversation]
    }

    /// Group conversation-born chats under their source conversation, keeping
    /// the list's most-recently-updated order both across and inside groups.
    /// Chats without a known source share one trailing nil-group.
    public static func groupedBySource(
        _ conversations: [ChatConversationStore.Conversation]
    ) -> [SourceGroup] {
        var order: [String] = []
        var byCapture: [String: [ChatConversationStore.Conversation]] = [:]
        var unsourced: [ChatConversationStore.Conversation] = []
        for convo in conversations {
            if let cid = convo.origin?.captureId, convo.isFromConversation {
                if byCapture[cid] == nil { order.append(cid) }
                byCapture[cid, default: []].append(convo)
            } else {
                unsourced.append(convo)
            }
        }
        var groups = order.map { SourceGroup(captureId: $0, conversations: byCapture[$0] ?? []) }
        if !unsourced.isEmpty {
            groups.append(SourceGroup(captureId: nil, conversations: unsourced))
        }
        return groups
    }
}

private extension JSONEncoder {
    static var iso8601: JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }
}
private extension JSONDecoder {
    static var iso8601: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }
}
