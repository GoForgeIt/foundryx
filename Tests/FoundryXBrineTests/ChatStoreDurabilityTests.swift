import XCTest
import Foundation
import FoundryXKit

/// Durability + search for the chat conversation store — the fix for the silent-overwrite
/// data-loss bug plus the pure search helper the chat surface calls.
///  - Persistence: round-trips the full envelope (messages, model, sensitivity) and stamps
///    the new schemaVersion; tolerates forward-compatible extra JSON keys and legacy
///    (pre-envelope) files; drops a single malformed conversation without failing the file.
///  - Corruption: a structurally-broken file is moved aside to `<name>.bak-<epoch>` (its
///    bytes preserved verbatim), a fresh list is seeded, and baks are pruned to the newest 3.
///  - Search: title + body matches, snippet windowing, no-match, empty query, recency order.
/// NOTE: like the rest of FoundryXBrineTests these run in CI (Package.swift needs the
/// un-cloned brine-private dependency); written to compile clean, mirroring ChatSessionTests.
final class ChatStoreDurabilityTests: XCTestCase {

    // MARK: helpers

    /// A fresh, unique temp directory so directory listing (backup pruning) sees only this
    /// test's files. Caller cleans up via `defer`.
    private func makeTempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("foundryx-store-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func storageURL(in dir: URL) -> URL {
        dir.appendingPathComponent("chat-conversations.json")
    }

    private func makeConversation(id: String, title: String,
                                  messages: [(String, String)] = [],
                                  updatedAt: Date = Date()) -> ChatConversationStore.Conversation {
        ChatConversationStore.Conversation(
            id: id, title: title,
            messages: messages.map { .init(role: $0.0, text: $0.1) },
            updatedAt: updatedAt)
    }

    // MARK: persistence round-trip

    func testPersistReloadRoundTripsMessagesModelAndSensitivity() {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = storageURL(in: dir)

        let first = ChatConversationStore(storageURL: url)
        let id = first.active!.id
        first.setMessages([.init(role: "user", text: "remember me"),
                           .init(role: "assistant", text: "will do")], for: id)
        first.setModel("claude-max", for: id)
        first.setSensitivity(ChatConversationStore.Sensitivity.private, for: id)

        let reloaded = ChatConversationStore(storageURL: url)
        XCTAssertEqual(reloaded.conversation(id)?.messages.map(\.text), ["remember me", "will do"])
        XCTAssertEqual(reloaded.conversation(id)?.modelTargetId, "claude-max")
        XCTAssertEqual(reloaded.conversation(id)?.sensitivity, "confidential",
                       "privacy posture must survive reload")
        XCTAssertEqual(reloaded.activeId, id, "the active conversation must survive reload")
    }

    func testPersistedFileCarriesSchemaVersion() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = storageURL(in: dir)

        _ = ChatConversationStore(storageURL: url)   // seeds + persists synchronously
        let data = try Data(contentsOf: url)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["schemaVersion"] as? Int, 1, "persisted envelope must stamp schemaVersion v1")
        XCTAssertNotNil(json["conversations"], "envelope must carry the conversations array")
        XCTAssertNotNil(json["activeId"], "envelope must carry the active id")
    }

    // MARK: forward / backward compatibility

    func testForwardCompatIgnoresUnknownKeys() {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = storageURL(in: dir)

        // A future-shaped file: extra top-level key, a newer schemaVersion, an unknown key
        // inside the conversation AND inside a message. All must be ignored, never fatal.
        let json = """
        {
          "schemaVersion": 99,
          "futureFlag": true,
          "activeId": "keep-me",
          "conversations": [
            {
              "id": "keep-me",
              "title": "Survivor",
              "messages": [{"role":"user","text":"hi","futureField":1}],
              "createdAt": "2026-01-01T00:00:00Z",
              "updatedAt": "2026-01-02T00:00:00Z",
              "unknownExtra": "ignored"
            }
          ]
        }
        """
        try? Data(json.utf8).write(to: url)

        let store = ChatConversationStore(storageURL: url)
        XCTAssertEqual(store.conversation("keep-me")?.title, "Survivor",
                       "extra/unknown JSON keys must be ignored, not fail the decode")
        XCTAssertEqual(store.conversation("keep-me")?.messages.first?.text, "hi")
        XCTAssertEqual(store.activeId, "keep-me")
    }

    func testLegacyFileWithoutSchemaVersionStillLoads() {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = storageURL(in: dir)

        // Pre-envelope shape: no schemaVersion key at all — must read cleanly (not corrupt).
        let json = """
        {"activeId":"legacy","conversations":[{"id":"legacy","title":"Old thread",
        "messages":[],"createdAt":"2025-12-01T00:00:00Z","updatedAt":"2025-12-01T00:00:00Z"}]}
        """
        try? Data(json.utf8).write(to: url)

        let store = ChatConversationStore(storageURL: url)
        XCTAssertEqual(store.conversation("legacy")?.title, "Old thread")
        XCTAssertEqual(store.activeId, "legacy")
    }

    func testOneMalformedConversationIsDroppedNotFatal() {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = storageURL(in: dir)

        // First conversation is missing required fields (bad); the second is valid. The bad
        // one is dropped, the good one survives — one bad entry never nukes the file.
        let json = """
        {"schemaVersion":1,"activeId":"good","conversations":[
          {"id":"bad"},
          {"id":"good","title":"Kept","messages":[],
           "createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-01T00:00:00Z"}
        ]}
        """
        try? Data(json.utf8).write(to: url)

        let store = ChatConversationStore(storageURL: url)
        XCTAssertNil(store.conversation("bad"), "a malformed conversation is dropped")
        XCTAssertEqual(store.conversation("good")?.title, "Kept", "valid conversations survive")
    }

    // MARK: corruption → backup + fresh seed

    func testCorruptFileArchivedToBakAndReseededPreservingOriginal() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = storageURL(in: dir)
        let fm = FileManager.default

        // Structurally-broken bytes: not valid JSON → the whole-file decode throws.
        let garbage = Data("{ this is not json ]]] corrupt".utf8)
        try garbage.write(to: url)

        let store = ChatConversationStore(storageURL: url)

        // Fresh seed: exactly one usable conversation, and a clean file now lives at `url`.
        XCTAssertEqual(store.conversations.count, 1, "a corrupt file must seed a fresh list")
        XCTAssertFalse(store.activeId.isEmpty, "the fresh seed must be the active conversation")
        let reseeded = try Data(contentsOf: url)
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: reseeded),
                         "the file at the live path must be valid JSON again")

        // The corrupt original was moved aside, not destroyed.
        let baks = try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("chat-conversations.json.bak-") }
        XCTAssertEqual(baks.count, 1, "exactly one .bak should be created for the corrupt file")
        let bak = try XCTUnwrap(baks.first)
        XCTAssertEqual(try Data(contentsOf: bak), garbage,
                       "the .bak must preserve the original corrupt bytes verbatim")

        // The bak filename ends in a numeric epoch: chat-conversations.json.bak-<epoch>.
        let suffix = bak.lastPathComponent.replacingOccurrences(
            of: "chat-conversations.json.bak-", with: "")
        XCTAssertNotNil(Int(suffix), "bak suffix must be an integer epoch, got \(suffix)")
    }

    func testBackupPruningKeepsAtMostThreeNewest() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = storageURL(in: dir)
        let fm = FileManager.default

        // Pre-seed four older baks with distinct (small) epochs so pruning has to choose.
        for epoch in [1000, 1001, 1002, 1003] {
            let bak = dir.appendingPathComponent("chat-conversations.json.bak-\(epoch)")
            try Data("old-\(epoch)".utf8).write(to: bak)
        }
        // Corrupt the live file and open the store → it archives a 5th (current-epoch, newest)
        // bak, then prunes to the newest 3.
        try Data("garbage-not-json {{{".utf8).write(to: url)
        _ = ChatConversationStore(storageURL: url)

        let baks = try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("chat-conversations.json.bak-") }
        XCTAssertEqual(baks.count, 3, "backups must be pruned to at most 3, newest kept")

        // The two oldest (1000, 1001) must be pruned; 1002, 1003 and the new bak survive.
        let names = Set(baks.map(\.lastPathComponent))
        XCTAssertFalse(names.contains("chat-conversations.json.bak-1000"), "oldest bak pruned")
        XCTAssertFalse(names.contains("chat-conversations.json.bak-1001"), "next-oldest bak pruned")
        XCTAssertTrue(names.contains("chat-conversations.json.bak-1002"), "newer baks retained")
        XCTAssertTrue(names.contains("chat-conversations.json.bak-1003"), "newer baks retained")
    }

    // MARK: search

    func testSearchEmptyOrWhitespaceQueryReturnsNothing() {
        let items = [makeConversation(id: "a", title: "Dentist appointment")]
        XCTAssertTrue(ChatConversationStore.search("", in: items).isEmpty)
        XCTAssertTrue(ChatConversationStore.search("   \n\t ", in: items).isEmpty)
    }

    func testSearchMatchesTitleCaseInsensitively() {
        let items = [makeConversation(id: "a", title: "Dentist Appointment"),
                     makeConversation(id: "b", title: "Grocery list")]
        let hits = ChatConversationStore.search("dentist", in: items)
        XCTAssertEqual(hits.map(\.conversationId), ["a"])
        XCTAssertTrue(hits.first!.snippet.localizedCaseInsensitiveContains("dentist"),
                      "snippet must carry the matched text")
    }

    func testSearchMatchesMessageBody() {
        let items = [makeConversation(id: "a", title: "New chat",
                                      messages: [("user", "can you move the dentist appointment?")])]
        let hits = ChatConversationStore.search("appointment", in: items)
        XCTAssertEqual(hits.map(\.conversationId), ["a"])
        XCTAssertTrue(hits.first!.snippet.contains("appointment"))
    }

    func testSearchNoMatchReturnsEmpty() {
        let items = [makeConversation(id: "a", title: "Grocery list",
                                      messages: [("user", "milk and eggs")])]
        XCTAssertTrue(ChatConversationStore.search("dentist", in: items).isEmpty)
    }

    func testSearchSnippetWindowsAroundFirstMatchWithEllipses() throws {
        let long = String(repeating: "x", count: 200) + " NEEDLE " + String(repeating: "y", count: 200)
        let items = [makeConversation(id: "a", title: "New chat", messages: [("user", long)])]
        let hit = try XCTUnwrap(ChatConversationStore.search("needle", in: items).first)
        XCTAssertTrue(hit.snippet.contains("NEEDLE"), "snippet must contain the matched text")
        XCTAssertTrue(hit.snippet.hasPrefix("…"), "clipped left edge must be ellipsized")
        XCTAssertTrue(hit.snippet.hasSuffix("…"), "clipped right edge must be ellipsized")
        XCTAssertLessThan(hit.snippet.count, 120,
                          "the ~80-char window (plus ellipses) must be far shorter than the 400+ source")
    }

    func testSearchOrdersMostRecentlyUpdatedFirst() {
        let older = makeConversation(id: "old", title: "dentist plan",
                                     updatedAt: Date(timeIntervalSince1970: 1_000))
        let newer = makeConversation(id: "new", title: "dentist reschedule",
                                     updatedAt: Date(timeIntervalSince1970: 2_000))
        // Input order deliberately oldest-first to prove the sort, not the input.
        let hits = ChatConversationStore.search("dentist", in: [older, newer])
        XCTAssertEqual(hits.map(\.conversationId), ["new", "old"],
                       "most-recently-updated conversation must lead")
    }
}
