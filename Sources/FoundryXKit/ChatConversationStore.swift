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

    /// A single chat thread. `id` is the kiln-session `chat_id`. `modelTargetId` is the
    /// chosen Kiln target (nil ⇒ "Auto (router)").
    public struct Conversation: Identifiable, Codable, Equatable, Sendable {
        public let id: String
        public var title: String
        public var messages: [StoredMessage]
        public var modelTargetId: String?
        /// Per-conversation privacy level sent as `sensitivity` on each turn. nil ⇒ the
        /// field is omitted ⇒ the door's default. `Sensitivity.private` (= "confidential")
        /// tells Kiln's router to keep the turn on compliant/on-device targets; nil/"public"
        /// lets it pick the fastest model. (Decode-old-data safe: a missing key ⇒ nil.)
        public var sensitivity: String?
        public var createdAt: Date
        public var updatedAt: Date

        public init(id: String = UUID().uuidString,
                    title: String = "New chat",
                    messages: [StoredMessage] = [],
                    modelTargetId: String? = nil,
                    sensitivity: String? = nil,
                    createdAt: Date = Date(),
                    updatedAt: Date = Date()) {
            self.id = id
            self.title = title
            self.messages = messages
            self.modelTargetId = modelTargetId
            self.sensitivity = sensitivity
            self.createdAt = createdAt
            self.updatedAt = updatedAt
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
    public func newConversation(modelTargetId: String? = nil) -> Conversation {
        // Inherit the previous active chat's model so a "new chat" keeps the user's pick.
        let inherited = modelTargetId ?? active?.modelTargetId
        let convo = Conversation(modelTargetId: inherited, sensitivity: active?.sensitivity)
        conversations.insert(convo, at: 0)
        activeId = convo.id
        persist()
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

    /// Privacy levels surfaced in the UI, mapped to the door's `sensitivity` wire value.
    /// "Standard" is nil (the door's default). NOTE: confirm against Kiln's sensitivity
    /// taxonomy (public | confidential | phi) — "confidential" is the non-PHI private tier.
    public enum Sensitivity {
        public static let `private` = "confidential"
    }

    /// Set the chosen model (target_id) for a conversation. nil ⇒ "Auto (router)".
    public func setModel(_ targetId: String?, for id: String) {
        mutate(id) { $0.modelTargetId = targetId }
    }

    /// Set the conversation's privacy level. nil ⇒ Standard (door default). Pass
    /// `Sensitivity.private` to keep the turn on compliant / on-device targets.
    public func setSensitivity(_ value: String?, for id: String) {
        mutate(id) { $0.sensitivity = value }
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
        return ChatRequest(message: text,
                           platform: platform,
                           chatId: id,
                           org: org,
                           sensitivity: convo?.sensitivity,
                           requestedTarget: convo?.modelTargetId)
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

    // MARK: - Search

    /// One search result: the conversation that matched plus a short, ellipsized snippet of
    /// text around the first match (rendered as a subtitle under the title in the chat list).
    public struct SearchHit: Equatable, Sendable {
        public let conversationId: String
        public let snippet: String
        public init(conversationId: String, snippet: String) {
            self.conversationId = conversationId
            self.snippet = snippet
        }
    }

    /// Case-insensitive substring search over each conversation's title + message texts.
    /// Returns one hit per matching conversation (the first match — title before messages —
    /// wins its snippet), ordered most-recently-updated first (by `updatedAt`). An empty or
    /// whitespace-only query yields []. Pure + static so the chat UI can search any list of
    /// conversations without reaching through the store.
    public static func search(_ query: String, in conversations: [Conversation]) -> [SearchHit] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }

        // Freshest match leads, mirroring the store's own most-recent-first ordering. `sorted`
        // is stable, so conversations with equal `updatedAt` keep their input order.
        let ordered = conversations.sorted { $0.updatedAt > $1.updatedAt }

        var hits: [SearchHit] = []
        for convo in ordered {
            let fields = [convo.title] + convo.messages.map(\.text)
            for field in fields {
                guard let match = field.range(of: needle, options: .caseInsensitive) else { continue }
                hits.append(SearchHit(conversationId: convo.id,
                                      snippet: snippet(around: match, in: field)))
                break   // one hit per conversation; first match wins the snippet
            }
        }
        return hits
    }

    /// An ~80-char window centered on `match`, ellipsized on whichever end was clipped.
    private static func snippet(around match: Range<String.Index>, in text: String,
                                window: Int = 80) -> String {
        let matchLen = text.distance(from: match.lowerBound, to: match.upperBound)
        let pad = max(0, window - matchLen) / 2
        let lo = max(0, text.distance(from: text.startIndex, to: match.lowerBound) - pad)
        let hi = min(text.count, text.distance(from: text.startIndex, to: match.upperBound) + pad)
        let start = text.index(text.startIndex, offsetBy: lo)
        let end = text.index(text.startIndex, offsetBy: hi)
        var snip = String(text[start..<end])
        if lo > 0 { snip = "…" + snip }
        if hi < text.count { snip += "…" }
        return snip
    }

    // MARK: - Persistence

    /// Decodes a single element WITHOUT letting one malformed entry fail the whole array —
    /// a corrupt conversation is dropped and the rest survive. (AC: "never fail the whole
    /// file for one bad conversation.")
    private struct Lossy<Wrapped: Decodable>: Decodable {
        let value: Wrapped?
        init(from decoder: Decoder) throws {
            value = try? decoder.singleValueContainer().decode(Wrapped.self)
        }
    }

    /// The on-disk envelope. `schemaVersion` lets future readers migrate deliberately; a
    /// missing version (pre-envelope files) is read as the current version and re-stamped
    /// on the next write, so old data upgrades in place.
    private struct Persisted: Codable {
        /// Current on-disk envelope version — bump when the persisted shape needs migration.
        static let currentSchemaVersion = 1

        var schemaVersion: Int
        var conversations: [Conversation]
        var activeId: String

        init(conversations: [Conversation],
             activeId: String,
             schemaVersion: Int = Persisted.currentSchemaVersion) {
            self.schemaVersion = schemaVersion
            self.conversations = conversations
            self.activeId = activeId
        }

        private enum CodingKeys: String, CodingKey { case schemaVersion, conversations, activeId }

        // Tolerant decode: unknown keys are ignored (default Codable behavior → forward
        // compatible), a missing schemaVersion defaults to the current version, and each
        // conversation is decoded independently so one broken entry can't nuke the list. A
        // structurally-broken file (not valid JSON / not this object) still THROWS here —
        // that's the signal `load()` uses to archive it as a .bak. (encode(to:) stays
        // synthesized from CodingKeys, always stamping the current version.)
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.schemaVersion = (try? c.decode(Int.self, forKey: .schemaVersion)) ?? Persisted.currentSchemaVersion
            let lossy = (try? c.decode([Lossy<Conversation>].self, forKey: .conversations)) ?? []
            self.conversations = lossy.compactMap(\.value)
            self.activeId = (try? c.decode(String.self, forKey: .activeId)) ?? ""
        }
    }

    /// Suffix used when a corrupt file is moved aside: `<name>.bak-<epoch>`.
    private static let backupInfix = ".bak-"

    private func load() {
        guard let url = storageURL else { return }
        // No file yet ⇒ a clean first run; `init` will seed. (Distinct from a corrupt file:
        // we never archive/seed unless bytes are actually present and unparseable.)
        guard let data = try? Data(contentsOf: url) else { return }
        do {
            let decoded = try JSONDecoder.iso8601.decode(Persisted.self, from: data)
            // Residual-corruption guard: a structurally-valid envelope whose EVERY
            // conversation failed the lossy decode (non-trivial bytes, zero survivors)
            // is corruption too — archive it rather than silently reseeding over it. A
            // legitimately-empty store file is tiny (<1 KB), so this never false-fires.
            if decoded.conversations.isEmpty, data.count > 1024 {
                archiveCorruptFile(at: url)
                return
            }
            conversations = decoded.conversations
            activeId = decoded.activeId
        } catch {
            // The file exists but can't be parsed as our envelope ⇒ treat it as corrupt. Move
            // the original ASIDE (never delete/overwrite) so its bytes survive for recovery,
            // then fall through: `conversations` stays empty and `init` seeds a fresh list +
            // writes a clean file at `url`. This is the fix for the silent-overwrite data-loss
            // bug — the old `load()` returned nil here and let `init` clobber the file.
            archiveCorruptFile(at: url)
        }
    }

    /// Move a corrupt persistence file aside to `<name>.bak-<epoch>` (epoch = whole seconds
    /// since 1970), preserving its bytes verbatim, then prune to the newest 3 baks. All
    /// best-effort: a filesystem hiccup is swallowed so a bad backup can never block seeding.
    private func archiveCorruptFile(at url: URL) {
        let fm = FileManager.default
        let epoch = Int(Date().timeIntervalSince1970)
        let bak = url.deletingLastPathComponent()
            .appendingPathComponent(url.lastPathComponent + Self.backupInfix + "\(epoch)")
        do {
            // If a same-second bak already exists, let the freshest corrupt copy win the slot
            // (still never touches the live file).
            if fm.fileExists(atPath: bak.path) { try? fm.removeItem(at: bak) }
            try fm.moveItem(at: url, to: bak)
        } catch {
            return   // couldn't move it aside; leave the original in place rather than lose it
        }
        pruneBackups(for: url, keeping: 3)
    }

    /// Keep at most `maxKeep` `<name>.bak-*` files next to `url`, removing the oldest first
    /// (ordered by the numeric epoch suffix, newest kept).
    private func pruneBackups(for url: URL, keeping maxKeep: Int) {
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        let prefix = url.lastPathComponent + Self.backupInfix
        guard let entries = try? fm.contentsOfDirectory(at: dir,
                                                        includingPropertiesForKeys: nil) else { return }
        let baks = entries
            .filter { $0.lastPathComponent.hasPrefix(prefix) }
            .sorted { Self.epochSuffix(of: $0, prefix: prefix) < Self.epochSuffix(of: $1, prefix: prefix) }
        guard baks.count > maxKeep else { return }
        for stale in baks.dropLast(maxKeep) { try? fm.removeItem(at: stale) }
    }

    private static func epochSuffix(of url: URL, prefix: String) -> Int {
        Int(url.lastPathComponent.dropFirst(prefix.count)) ?? 0
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

private extension JSONEncoder {
    static var iso8601: JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }
}
private extension JSONDecoder {
    static var iso8601: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }
}
