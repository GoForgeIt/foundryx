// ActionChatLink — the durable action↔chat association (track 20260715T1500
// extension EXT2): when the user ACTS on a surfaced action in chat and actually
// SENDS the seeded turn, the action remembers which chat it started. From then
// on the action's options offer "Continue in chat →" (routing to THAT chat)
// instead of a fresh prefill.
//
// Storage: `action-chat-links.json` beside the pipeline's other stores in the
// captures dir — a small map keyed by (captureId, utterance), values carry the
// chat id + when the link was made. Honesty rules:
//   • a link is written ONLY at the send that logs the `run` outcome — never on
//     mere prefill/navigation;
//   • deleting the chat removes its links (plus lazy validation at render, so a
//     dead link can never route nowhere).

import Foundation

public enum ActionChatLinkStore {
    public static let filename = "action-chat-links.json"

    public struct Entry: Codable, Equatable, Sendable {
        public let chatId: String
        /// Unix seconds when the link was made (the seeded turn's send).
        public let ts: UInt64

        public init(chatId: String, ts: UInt64) {
            self.chatId = chatId
            self.ts = ts
        }
    }

    static func url(baseDir: URL) -> URL {
        baseDir.appendingPathComponent(filename)
    }

    /// The map key: capture-scoped so the same sentence surfacing in two
    /// conversations keeps two independent links. Uses THE shared utterance
    /// truncation (`ConversationActions.utteranceKey`) so every join agrees.
    public static func key(captureId: String, utterance: String) -> String {
        "\(captureId)|\(ConversationActions.utteranceKey(utterance))"
    }

    /// Record (or overwrite — re-acting rebinds) the action's chat.
    public static func link(captureId: String, utterance: String, chatId: String,
                            baseDir: URL,
                            ts: UInt64 = UInt64(max(0, Date().timeIntervalSince1970))) {
        var map = load(baseDir: baseDir)
        map[key(captureId: captureId, utterance: utterance)] = Entry(chatId: chatId, ts: ts)
        save(map, baseDir: baseDir)
    }

    /// The chat an action leads back to, or nil when never acted on.
    public static func chatId(captureId: String, utterance: String, baseDir: URL) -> String? {
        load(baseDir: baseDir)[key(captureId: captureId, utterance: utterance)]?.chatId
    }

    /// One conversation's links, keyed by the clipped utterance — what the
    /// Actions-face builder joins rows against.
    public static func links(captureId: String, baseDir: URL) -> [String: String] {
        var out: [String: String] = [:]
        let prefix = "\(captureId)|"
        for (k, v) in load(baseDir: baseDir) where k.hasPrefix(prefix) {
            out[String(k.dropFirst(prefix.count))] = v.chatId
        }
        return out
    }

    /// The chat was deleted — forget every link to it (never route to a ghost).
    public static func removeLinks(toChatId chatId: String, baseDir: URL) {
        let map = load(baseDir: baseDir)
        let pruned = map.filter { $0.value.chatId != chatId }
        guard pruned.count != map.count else { return }
        save(pruned, baseDir: baseDir)
    }

    // MARK: persistence (tolerant: corrupt/missing file reads as no links)

    static func load(baseDir: URL) -> [String: Entry] {
        guard let data = try? Data(contentsOf: url(baseDir: baseDir)),
              let map = try? JSONDecoder().decode([String: Entry].self, from: data)
        else { return [:] }
        return map
    }

    static func save(_ map: [String: Entry], baseDir: URL) {
        try? FileManager.default.createDirectory(at: baseDir,
                                                 withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(map) else { return }
        try? data.write(to: url(baseDir: baseDir), options: .atomic)
    }
}
