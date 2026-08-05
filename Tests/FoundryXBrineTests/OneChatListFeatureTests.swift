import XCTest
import Foundation
import BrineSwiftCore
@testable import FoundryXKit

/// Brine driver for features/one-chat-list.feature.
///
/// Three real things, no mocks of our own code:
///
///   * THE PHONE'S CHATS are a real `ChatConversationStore` (in-memory), adapted through the
///     real `PhoneChatSource` — the same adapter the app uses.
///   * THE MERGE, ORDER, FACET AND HONESTY decisions are the real
///     `KilnLibraryPresentation.resolve` / `ChatCorpus.merge` / `KilnLibraryCopy`.
///   * THE DOOR is a stand-in, and it is deliberately built to behave like the MEASURED one:
///     `GET /foundryx/chats?q=` full-text-searches the whole corpus INCLUDING message
///     content (live, 2026-08-05: `q=deletion` returns 1,053 of 2,748 rows, many with titles
///     that never mention it), returns at most `limit` rows most-recent-first, and reports
///     the true match count in `total`. A stand-in that searched only titles, or only the
///     rows already in hand, would let the phone's half of the search pass while the real
///     thing failed.
///
/// The App-side wiring (`App/ChatListView.swift`, `App/ChatScreen.swift`) is read from source
/// through `AppSourceTree`, this suite's existing convention for facts `swift test` cannot
/// compile.
final class OneChatListFeatureTests: XCTestCase {
    func testOneChatListFeature() async throws {
        try await BrineFeatureRunner.run(
            "one-chat-list",
            registry: StepRegistry(OneChatListSteps.make(world: OneChatListWorld())))
    }
}

// MARK: - the world

private final class OneChatListWorld: @unchecked Sendable {

    /// The phone's own chats — a REAL `ChatConversationStore`, loaded from a real file it
    /// wrote itself. `nil` = this phone holds nothing at all, which the store cannot be
    /// talked into (it seeds an empty chat on birth), so that one scenario drives the kit
    /// contract directly.
    var store: ChatConversationStore?
    private var seeded: [ChatConversationStore.Conversation] = []
    private let seedRoot = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("one-chat-list-\(UUID().uuidString)", isDirectory: true)
    /// The Mac's rows, as the store on the desktop holds them.
    var macRows: [LibraryChatRow] = []
    /// What the DOOR can see inside a Mac chat that its title and preview do not reveal.
    /// This is how the content-search behaviour is modelled honestly.
    var macContent: [String: String] = [:]
    /// How many rows one door read returns. The real door clamps to 200 over 2,748 rows;
    /// a small number here reproduces the same shape without 2,748 fixtures.
    var pageLimit = 200
    var connected = true
    var macFails = false

    var query = ""
    var provenance: ChatProvenance?
    var state: KilnLibraryPresentation.State = .idle
    /// Every `q` the door was handed, so a scenario can prove the search was ASKED of the
    /// Mac rather than run over whatever the phone was already holding.
    var doorQueries: [String] = []
    /// `App/<file>` → its source with comments removed and string literals intact.
    var sources: [String: String] = [:]

    static let chatScreen = "App/ChatScreen.swift"
    static let chatList = "App/ChatListView.swift"
    static let chatSurfaceFiles = [chatScreen, chatList]

    /// A fixed "now" so bucketing and ordering are deterministic: 2026-08-05T12:00:00Z.
    static let nowMs: Double = 1_754_395_200_000

    func reset() {
        store = nil
        seeded = []
        macRows = []
        macContent = [:]
        pageLimit = 200
        connected = true
        macFails = false
        query = ""
        provenance = nil
        state = .idle
        doorQueries = []
    }

    // ── seeding ──────────────────────────────────────────────────────────────

    /// Seed a chat into the phone's REAL store, through the file the store really reads.
    /// No test-only setter on the production type: the persisted document IS the seam.
    func addPhoneChat(id: String, title: String, agoMinutes: Int, saying: String = "") throws {
        let at = Date(timeIntervalSince1970: (Self.nowMs / 1000) - Double(agoMinutes) * 60)
        seeded.append(ChatConversationStore.Conversation(
            id: id, title: title,
            messages: saying.isEmpty ? [] : [.init(role: "user", text: saying)],
            createdAt: at, updatedAt: at))

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let list = String(decoding: try encoder.encode(seeded), as: UTF8.self)
        let url = ChatConversationStore.storageURL(inAccountRoot: seedRoot)
        try FileManager.default.createDirectory(at: seedRoot, withIntermediateDirectories: true)
        try #"{"conversations":\#(list),"activeId":"\#(seeded[0].id)"}"#
            .data(using: .utf8)!.write(to: url, options: .atomic)
        store = ChatConversationStore(storageURL: url)
        guard store?.conversations.count == seeded.count else {
            throw BrineStepError(
                "the store loaded \(store?.conversations.count ?? -1) of \(seeded.count) "
                    + "seeded chats — the seed no longer matches what it persists")
        }
    }

    var phoneConversations: [ChatConversationStore.Conversation] { store?.conversations ?? [] }

    /// - `importedAgoMinutes`: when the ROW was created, which for an imported transcript is
    ///   the IMPORT time and has nothing to do with when the conversation happened. The live
    ///   store really does write `started_at = now` on import while carrying the true
    ///   `last_message_at` — that skew is what once floated a two-year-old Codex transcript
    ///   above the morning's work, so a fixture without it cannot tell a recency-ordered
    ///   list from a creation-ordered one.
    func addMacChat(id: String, title: String, origin: String, agoMinutes: Int,
                    importedAgoMinutes: Int? = nil, saying: String = "") {
        let spoke = Self.nowMs - Double(agoMinutes) * 60_000
        let created = Self.nowMs - Double(importedAgoMinutes ?? agoMinutes) * 60_000
        macRows.append(LibraryChatRow(
            id: id, title: title, origin: origin,
            startedAt: KilnTimestamp.iso8601(millisSince1970: created),
            lastMessagePreview: nil,
            lastMessageAt: KilnTimestamp.iso8601(millisSince1970: spoke)))
        if !saying.isEmpty { macContent[id] = saying }
    }

    // ── the stand-in door ────────────────────────────────────────────────────

    /// What `GET /foundryx/chats?limit=&q=` answers, shaped like the measured one.
    func door(_ q: String) throws -> KilnLibraryPresentation.Load {
        doorQueries.append(q)
        if macFails { throw KilnLibraryError.unreachable }
        let terms = q.split(whereSeparator: { $0.isWhitespace }).map { $0.lowercased() }
        let matched = macRows.filter { row in
            guard !terms.isEmpty else { return true }
            let hay = [(row.title ?? ""), (row.lastMessagePreview ?? ""), (macContent[row.id] ?? "")]
                .joined(separator: " ").lowercased()
            return terms.allSatisfy { hay.contains($0) }
        }
        let recent = matched.sorted {
            (KilnTimestamp.millis($0.lastMessageAt ?? $0.startedAt) ?? 0)
                > (KilnTimestamp.millis($1.lastMessageAt ?? $1.startedAt) ?? 0)
        }
        return KilnLibraryPresentation.Load(
            page: LibraryPage(chats: Array(recent.prefix(pageLimit)), total: matched.count),
            org: KilnChatOrg.empty)
    }

    /// Open the list — exactly the call `ChatListStore.load()` makes.
    func open() async {
        let terms = KilnLibraryPresentation.parseFilter(query).text
        let phone = PhoneChatSource.rows(
            PhoneChatSource.matching(phoneConversations, terms: terms))
        let asked = terms.joined(separator: " ")
        state = await KilnLibraryPresentation.resolve(
            computerConnected: connected,
            phoneRows: phone,
            lens: KilnLibraryPresentation.defaultMergedLens,
            query: query, provenance: provenance,
            nowMs: Self.nowMs,
            load: { try self.door(asked) })
    }

    func rail() throws -> KilnLibraryPresentation.Rail {
        guard case .loaded(let rail) = state else {
            throw BrineStepError("the list did not draw: \(state)")
        }
        return rail
    }

    /// Every row the list renders, in reading order.
    func rows() throws -> [ChatNode] { try rail().allNodes }

    func node(_ id: String) throws -> ChatNode? { try rows().first { $0.id == id } }

    func requireRow(_ id: String, _ what: String) throws -> ChatNode {
        guard let n = try node(id) else {
            throw BrineStepError(
                "\(what) (\(id)) is not in the list — it holds \(try rows().map(\.id))")
        }
        return n
    }

    func refuseRow(_ id: String, _ what: String) throws {
        if try node(id) != nil {
            throw BrineStepError("\(what) (\(id)) is in the list and should not be")
        }
    }

    // ── App source ───────────────────────────────────────────────────────────

    func loadChatSurface() throws {
        for path in Self.chatSurfaceFiles where sources[path] == nil {
            let url = AppSourceTree.repoRoot.appendingPathComponent(path)
            let text = try String(contentsOf: url, encoding: .utf8)
            // A guard, not a convenience: a moved or renamed file must be a LOUD failure,
            // never an empty string that satisfies every "does not contain" check.
            guard text.count > 500 else {
                throw BrineStepError("\(path) read back only \(text.count) bytes")
            }
            sources[path] = AppSourceTree.withoutComments(of: text)
        }
    }

    func source(_ path: String) throws -> String {
        try loadChatSurface()
        guard let text = sources[path] else {
            throw BrineStepError("\(path) could not be read")
        }
        return text
    }

    static func stringLiterals(in text: String) -> [String] {
        let pattern = #""([^"\\\n]*(?:\\.[^"\\\n]*)*)""#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range(at: 1)) }
    }

    static func lines(in text: String, matching pattern: String) throws -> [String] {
        let regex = try NSRegularExpression(pattern: pattern)
        return text.components(separatedBy: "\n").enumerated().compactMap { index, line in
            let ns = line as NSString
            let hit = regex.firstMatch(
                in: line, range: NSRange(location: 0, length: ns.length)) != nil
            return hit ? "\(index + 1): \(line.trimmingCharacters(in: .whitespaces))" : nil
        }
    }
}

// MARK: - steps

private enum OneChatListSteps {
    // swiftlint:disable:next function_body_length
    static func make(world w: OneChatListWorld) -> [StepDefinition] {
        [
            // ── Given ────────────────────────────────────────────────────────────────

            defineStep("I started a chat on this phone an hour ago") { ctx, _, _ in
                w.reset()
                try w.addPhoneChat(id: "phone-1", title: "Something I started here", agoMinutes: 60)
                return ctx
            },
            defineStep("I started a chat on this phone about kestrels") { ctx, _, _ in
                w.reset()
                try w.addPhoneChat(id: "phone-1", title: "A chat I started here",
                               agoMinutes: 60, saying: "what do kestrels eat")
                return ctx
            },
            defineStep("my Mac holds a Claude Code chat from yesterday") { ctx, _, _ in
                // Imported a minute ago; SPOKEN yesterday. The list must order by the
                // second fact.
                w.addMacChat(id: "import:claude-code:aaa", title: "Yesterday's Claude Code work",
                             origin: "claude-code", agoMinutes: 24 * 60, importedAgoMinutes: 1)
                return ctx
            },
            defineStep("I also started a chat on this phone about something else") { ctx, _, _ in
                try w.addPhoneChat(id: "phone-2", title: "A chat I started here",
                                   agoMinutes: 30, saying: "unrelated musings")
                return ctx
            },
            defineStep("my Mac holds a Kiln chat from ten minutes ago") { ctx, _, _ in
                w.addMacChat(id: "kiln-1", title: "A Kiln chat", origin: "kiln", agoMinutes: 10)
                return ctx
            },
            defineStep("my Mac already knows that same chat") { ctx, _, _ in
                // The overlap is REAL: a chat this phone started appears in the Mac's
                // library as origin `foundryx` as soon as it takes a turn.
                w.addMacChat(id: "phone-1", title: "Something I started here",
                             origin: PhoneChatSource.origin, agoMinutes: 30)
                return ctx
            },
            defineStep("my Mac holds a Claude Code chat about kestrels") { ctx, _, _ in
                w.addMacChat(id: "import:claude-code:kestrel", title: "Kestrels, on the Mac",
                             origin: "claude-code", agoMinutes: 120)
                return ctx
            },
            defineStep("my Mac holds nothing but a chat about kestrels") { ctx, _, _ in
                w.reset()
                w.addMacChat(id: "import:claude-code:kestrel", title: "Kestrels, on the Mac",
                             origin: "claude-code", agoMinutes: 120)
                return ctx
            },
            defineStep("my Mac holds a Codex chat about something else") { ctx, _, _ in
                w.addMacChat(id: "import:codex-cli:other", title: "Something else entirely",
                             origin: "codex-cli", agoMinutes: 15)
                return ctx
            },
            defineStep("my Mac holds a chat whose title says nothing about kestrels") { ctx, _, _ in
                w.reset()
                w.addMacChat(id: "import:codex-cli:quiet", title: "CW-FoundryX",
                             origin: "codex-cli", agoMinutes: 90)
                return ctx
            },
            defineStep("kestrels are discussed inside it") { ctx, _, _ in
                w.macContent["import:codex-cli:quiet"] =
                    "we talked at length about kestrels and their hunting"
                return ctx
            },
            defineStep("my Mac holds more chats than my phone is showing") { ctx, _, _ in
                w.reset()
                w.pageLimit = 2
                w.addMacChat(id: "kiln-new", title: "The newest thing", origin: "kiln",
                             agoMinutes: 5)
                w.addMacChat(id: "kiln-mid", title: "The middling thing", origin: "kiln",
                             agoMinutes: 50)
                w.addMacChat(id: "import:claude-code:deep", title: "The buried thing",
                             origin: "claude-code", agoMinutes: 5000,
                             saying: "kestrels were mentioned here")
                return ctx
            },
            defineStep("the chat I am looking for is not one of the ones being shown") { ctx, _, _ in
                await w.open()
                try w.refuseRow("import:claude-code:deep",
                                "the buried chat, before any search")
                return ctx
            },
            defineStep("I have no chats on this phone") { ctx, _, _ in
                w.reset()
                return ctx
            },
            defineStep("no computer is connected") { ctx, _, _ in
                w.connected = false
                return ctx
            },
            defineStep("my computer cannot be reached") { ctx, _, _ in
                w.macFails = true
                return ctx
            },
            defineStep("I am on the chat surface") { ctx, _, _ in
                w.reset()
                try w.loadChatSurface()
                return ctx
            },

            // ── When ─────────────────────────────────────────────────────────────────

            defineStep("I open my chats") { ctx, _, _ in
                await w.open(); return ctx
            },
            defineStep("I search for {string}") { ctx, params, _ in
                w.query = try params.requireString(0)
                await w.open()
                return ctx
            },
            defineStep("I search for it") { ctx, _, _ in
                w.query = "kestrels"
                await w.open()
                return ctx
            },
            defineStep("I look at only the Claude Code chats") { ctx, _, _ in
                w.provenance = .claudeCode
                await w.open()
                return ctx
            },

            // ── one list, ordered by recency ─────────────────────────────────────────

            defineCheck("all three chats are in one list") { _, _, _ in
                _ = try w.requireRow("phone-1", "the chat I started here")
                _ = try w.requireRow("import:claude-code:aaa", "the Claude Code chat")
                _ = try w.requireRow("kiln-1", "the Kiln chat")
                // ONE list, not three lists drawn one after another: every row has to be in
                // the SAME rendered group, or the merge is cosmetic.
                let rail = try w.rail()
                let bodies = rail.groups.filter { !$0.nodes.isEmpty }
                guard bodies.count == 1, rail.inbox.isEmpty else {
                    throw BrineStepError(
                        "the chats are split across \(bodies.count) group(s) plus "
                            + "\(rail.inbox.count) in an Inbox zone — that is still more than "
                            + "one list: \(bodies.map(\.label))")
                }
            },
            defineCheck("they are ordered with the most recent first") { _, _, _ in
                let ids = try w.rows().map(\.id)
                let expected = ["kiln-1", "phone-1", "import:claude-code:aaa"]
                guard ids == expected else {
                    throw BrineStepError("order was \(ids), expected \(expected)")
                }
            },

            // ── provenance on the row ────────────────────────────────────────────────

            defineCheck("every chat says which source it came from") { _, _, _ in
                for n in try w.rows() {
                    let tag = ChatProvenance(n).shortTag.trimmingCharacters(in: .whitespaces)
                    guard !tag.isEmpty else {
                        throw BrineStepError("\"\(n.title)\" carries no source tag")
                    }
                }
                // And the row has to RENDER it, or the facet exists only in the model.
                let list = try w.source(OneChatListWorld.chatList)
                guard list.contains("ChatProvenance(node)"), list.contains("source.shortTag") else {
                    throw BrineStepError(
                        "the list row never reads a row's source, so nothing says where a "
                            + "chat came from")
                }
            },
            defineCheck("the chat I started here says it came from this phone") { _, _, _ in
                let n = try w.requireRow("phone-1", "the chat I started here")
                guard ChatProvenance(n) == .thisPhone else {
                    throw BrineStepError(
                        "it reads as \(ChatProvenance(n).label), not this phone")
                }
                guard ChatProvenance.thisPhone.label
                    .localizedCaseInsensitiveContains("phone") else {
                    throw BrineStepError(
                        "\"\(ChatProvenance.thisPhone.label)\" does not say it is this phone")
                }
            },

            // ── one row, not two ─────────────────────────────────────────────────────

            defineCheck("that chat appears exactly once") { _, _, _ in
                let hits = try w.rows().filter { $0.id == "phone-1" }
                guard hits.count == 1 else {
                    throw BrineStepError(
                        "the chat appears \(hits.count) times — the phone's copy and the "
                            + "Mac's copy are the SAME conversation and must be one row")
                }
            },
            defineCheck("it is still the chat this phone can carry on locally") { _, _, _ in
                let n = try w.requireRow("phone-1", "the shared chat")
                guard ChatProvenance(n) == .thisPhone else {
                    throw BrineStepError("the merged row lost its phone provenance")
                }
                guard w.store?.conversation("phone-1") != nil else {
                    throw BrineStepError("the phone no longer holds that conversation")
                }
                // The list has to ASK the local store, not guess from the origin: the Mac
                // carries `foundryx` rows for chats this phone has since deleted.
                let list = try w.source(OneChatListWorld.chatList)
                guard list.contains("chats.conversation(id)") else {
                    throw BrineStepError(
                        "the list never asks the local store whether a row is one of this "
                            + "phone's, so it cannot know which rows it can open locally")
                }
            },

            // ── search spanning both origins ─────────────────────────────────────────

            defineCheck("I find the chat I started here") { _, _, _ in
                _ = try w.requireRow("phone-1", "the chat I started here")
            },
            defineCheck("I find the Claude Code chat from my Mac") { _, _, _ in
                _ = try w.requireRow("import:claude-code:kestrel", "the Mac's Claude Code chat")
            },
            // BOTH origins have to be narrowed. A search that filtered the Mac's rows but
            // waved every one of this phone's through would pass a Mac-only assertion and
            // still be broken — the two halves must behave the same way.
            defineCheck("I do not find either chat about something else") { _, _, _ in
                try w.refuseRow("import:codex-cli:other", "the unrelated Codex chat")
                try w.refuseRow("phone-2", "the unrelated chat I started here")
            },
            defineCheck("the list says it searched this phone and my Mac") { _, _, _ in
                let rail = try w.rail()
                guard let line = KilnLibraryCopy.coverageLine(rail.coverage, searching: true) else {
                    throw BrineStepError(
                        "the list said NOTHING about what the search covered")
                }
                for word in ["this phone", "Mac"] where
                    !line.localizedCaseInsensitiveContains(word) {
                    throw BrineStepError("\"\(line)\" does not say it searched \(word)")
                }
            },
            defineCheck("I find it") { _, _, _ in
                _ = try w.requireRow("import:claude-code:deep", "the buried chat")
            },
            defineCheck("finding it did not depend on it already being on my phone") { _, _, _ in
                // The door was ASKED. A search that only re-filtered the rows already in
                // hand would never have sent the term, and would never have found this row.
                guard w.doorQueries.contains(where: { $0.localizedCaseInsensitiveContains("kestrels") })
                else {
                    throw BrineStepError(
                        "the search term never reached the door (\(w.doorQueries)) — so it "
                            + "could only ever have covered the rows already on the phone")
                }
                let list = try w.source(OneChatListWorld.chatList)
                guard try !OneChatListWorld.lines(
                    in: list, matching: #"kilnLibrary\(limit:\s*\d+,\s*query:\s*asked\)"#).isEmpty
                else {
                    throw BrineStepError(
                        "the list does not send the typed free text to the door, so a search "
                            + "covers only the page it happens to be holding")
                }
            },
            defineCheck("I find that chat") { _, _, _ in
                let n = try w.requireRow("import:codex-cli:quiet", "the quietly-matching chat")
                guard !n.title.localizedCaseInsensitiveContains("kestrel") else {
                    throw BrineStepError(
                        "the fixture's title mentions kestrels, so this proves nothing about "
                            + "matching on what was said inside")
                }
            },

            // ── coverage ─────────────────────────────────────────────────────────────

            defineCheck("the list says how many of my Mac's chats it is showing") { _, _, _ in
                let rail = try w.rail()
                guard case .truncated(let shown, let total) = rail.coverage else {
                    throw BrineStepError(
                        "the list claims to hold everything (\(rail.coverage)) while the Mac "
                            + "has more than it fetched")
                }
                guard let line = KilnLibraryCopy.coverageLine(rail.coverage, searching: false) else {
                    throw BrineStepError("a truncated list said nothing about being truncated")
                }
                for n in [shown, total] where !line.contains("\(n)") {
                    throw BrineStepError("\"\(line)\" does not say \(n)")
                }
            },
            defineCheck("the list says what the search covered") { _, _, _ in
                // The honesty invariant, stated as a property rather than a sentence: while
                // searching, NO coverage may render as silence.
                for coverage: ChatListCoverage in [
                    .complete, .truncated(shownFromMac: 2, totalOnMac: 9),
                    .thisPhoneOnly(reason: "nope"), .pending,
                ] where KilnLibraryCopy.coverageLine(coverage, searching: true) == nil {
                    throw BrineStepError(
                        "a search whose coverage is \(coverage) says nothing at all — a "
                            + "partial answer with no stated scope reads as a complete one")
                }
                let rail = try w.rail()
                guard KilnLibraryCopy.coverageLine(rail.coverage, searching: true) != nil else {
                    throw BrineStepError("this search said nothing about what it covered")
                }
                let list = try w.source(OneChatListWorld.chatList)
                guard list.contains("KilnLibraryCopy.coverageLine") else {
                    throw BrineStepError("the list never renders the coverage line")
                }
            },

            // ── the source facet ─────────────────────────────────────────────────────

            defineCheck("I see the Claude Code chat") { _, _, _ in
                _ = try w.requireRow("import:claude-code:aaa", "the Claude Code chat")
            },
            defineCheck("I do not see the chat I started here") { _, _, _ in
                try w.refuseRow("phone-1", "the chat I started here")
            },
            defineCheck("the list says it is showing only Claude Code") { _, _, _ in
                let rail = try w.rail()
                guard let line = KilnLibraryCopy.provenanceLine(rail.provenance) else {
                    throw BrineStepError(
                        "rows are being hidden by a filter and nothing says a filter is on")
                }
                guard line.localizedCaseInsensitiveContains("Claude Code") else {
                    throw BrineStepError("\"\(line)\" does not name Claude Code")
                }
                guard KilnLibraryCopy.provenanceLine(nil) == nil else {
                    throw BrineStepError(
                        "an unfiltered list also announces a filter, so the announcement "
                            + "says nothing")
                }
                let list = try w.source(OneChatListWorld.chatList)
                guard list.contains("KilnLibraryCopy.provenanceLine") else {
                    throw BrineStepError("the list never renders the filter notice")
                }
            },
            defineCheck("I can get back to every source from there") { _, _, _ in
                let rail = try w.rail()
                guard rail.sourcesPresent.contains(.thisPhone) else {
                    throw BrineStepError(
                        "the chip for the source being filtered OUT is gone, so there is no "
                            + "way back to it: \(rail.sourcesPresent.map(\.label))")
                }
                let list = try w.source(OneChatListWorld.chatList)
                guard list.contains("chat-source-clear") else {
                    throw BrineStepError("nothing offers a way back to every source")
                }
            },
            defineCheck("this phone and Claude Code are offered as sources to filter by") { _, _, _ in
                let present = try w.rail().sourcesPresent
                for wanted: ChatProvenance in [.thisPhone, .claudeCode] where !present.contains(wanted) {
                    throw BrineStepError(
                        "\(wanted.label) is not offered: \(present.map(\.label))")
                }
            },
            defineCheck("Codex is not offered, because I have no Codex chats") { _, _, _ in
                let present = try w.rail().sourcesPresent
                guard !present.contains(.codex) else {
                    throw BrineStepError(
                        "Codex is offered as a filter over a corpus holding no Codex chats")
                }
            },

            // ── honest degradation ───────────────────────────────────────────────────

            defineCheck("I still see the chat I started here") { _, _, _ in
                _ = try w.requireRow("phone-1", "the chat I started here")
            },
            defineCheck(
                "I am told these are the chats on this phone and my Mac isn't reachable"
            ) { _, _, _ in
                let rail = try w.rail()
                guard case .unreachable = rail.macReach else {
                    throw BrineStepError(
                        "the list thinks the Mac was fine: \(rail.macReach)")
                }
                guard let line = KilnLibraryCopy.reachLine(rail.macReach) else {
                    throw BrineStepError(
                        "the list shows this phone's chats and says nothing about the Mac")
                }
                for word in ["this phone", "isn't reachable"] where
                    !line.localizedCaseInsensitiveContains(word) {
                    throw BrineStepError("\"\(line)\" does not say \(word)")
                }
                let list = try w.source(OneChatListWorld.chatList)
                guard list.contains("KilnLibraryCopy.reachLine") else {
                    throw BrineStepError("the list never renders the reach notice")
                }
            },
            defineCheck("I am never shown my phone's chats as though they were all of them") { _, _, _ in
                // The property, not the instance: a reachable Mac is the ONLY state allowed
                // to render as silence.
                for reach: MacReach in [.noComputer, .unreachable("something broke")]
                where KilnLibraryCopy.reachLine(reach) == nil {
                    throw BrineStepError(
                        "\(reach) renders as silence, so a partial list reads as everything")
                }
                guard KilnLibraryCopy.reachLine(.reachable) == nil else {
                    throw BrineStepError(
                        "a reachable Mac also draws a warning, so the warning means nothing")
                }
                let rail = try w.rail()
                guard case .thisPhoneOnly = rail.coverage else {
                    throw BrineStepError(
                        "a list with no Mac in it reports its coverage as \(rail.coverage)")
                }
            },
            defineCheck("the list says my Mac's chats were not searched") { _, _, _ in
                let rail = try w.rail()
                guard case .thisPhoneOnly = rail.coverage else {
                    throw BrineStepError(
                        "a search that never reached the Mac reports \(rail.coverage)")
                }
                guard let line = KilnLibraryCopy.coverageLine(rail.coverage, searching: true) else {
                    throw BrineStepError("nothing said the Mac was not searched")
                }
                guard line.localizedCaseInsensitiveContains("not searched")
                    || line.localizedCaseInsensitiveContains("only") else {
                    throw BrineStepError(
                        "\"\(line)\" does not say the Mac's chats went unsearched")
                }
            },
            defineCheck("I am told no computer is connected") { _, _, _ in
                guard case .notConnected = w.state else {
                    throw BrineStepError("the list resolved to \(w.state), not .notConnected")
                }
            },
            defineCheck("I am not shown an empty list as if I had no chats") { _, _, _ in
                // `.notConnected` and a genuinely empty `.loaded([])` are DIFFERENT states,
                // and the surface renders them differently. That separation is the whole
                // reason the door answers 503 instead of an empty array.
                let empty = await KilnLibraryPresentation.resolve(
                    computerConnected: true, phoneRows: [],
                    nowMs: OneChatListWorld.nowMs,
                    load: { KilnLibraryPresentation.Load(
                        page: LibraryPage(chats: [], total: 0), org: KilnChatOrg.empty) })
                guard case .loaded = empty else {
                    throw BrineStepError("a genuinely empty library did not resolve as loaded")
                }
                guard w.state != empty else {
                    throw BrineStepError(
                        "having no computer and having no chats are the SAME state")
                }
            },

            // ── one way in ───────────────────────────────────────────────────────────

            defineCheck("there is one control that opens my chats") { _, _, _ in
                let screen = try w.source(OneChatListWorld.chatScreen)
                let n = OneChatListWorld.occurrences(
                    of: "accessibilityIdentifier(ChatListCopy.controlAccessibilityIdentifier)",
                    in: screen)
                guard n == 1 else {
                    throw BrineStepError(
                        "expected exactly one control that opens the chats, found \(n)")
                }
                let sets = OneChatListWorld.occurrences(of: "showingChatList = true", in: screen)
                guard sets == 1 else {
                    throw BrineStepError(
                        "the chat list is opened from \(sets) places, expected exactly one")
                }
            },
            defineCheck("it does not ask me which place to look in") { _, _, _ in
                let screen = try w.source(OneChatListWorld.chatScreen)
                // The scope menu, exactly: a Menu in the header whose choices are corpora.
                let scoped = try OneChatListWorld.lines(
                    in: screen, matching: #"ChatScope|scope\.(title|caption)|onYourMac|thisPhone"#)
                guard scoped.isEmpty else {
                    throw BrineStepError(
                        "the chat surface still asks which corpus to look in:\n"
                            + scoped.joined(separator: "\n"))
                }
            },
            defineCheck("no control on that surface opens a second list of chats") { _, _, _ in
                let screen = try w.source(OneChatListWorld.chatScreen)
                let sheets = try OneChatListWorld.lines(
                    in: screen, matching: #"\.sheet\(isPresented:"#)
                guard sheets.count == 1 else {
                    throw BrineStepError(
                        "the chat surface presents \(sheets.count) boolean sheets; only the "
                            + "one chat list should be one:\n" + sheets.joined(separator: "\n"))
                }
                for banned in ["ChatListSheet", "KilnLibraryView"] where screen.contains(banned) {
                    throw BrineStepError("\(banned) — a second list of chats — is back")
                }
            },

            // ── the name ─────────────────────────────────────────────────────────────

            defineCheck("the list is not named with a bare quantifier") { _, _, _ in
                guard !ChatProvenance.isBareQuantifier(KilnLibraryCopy.listTitle) else {
                    throw BrineStepError(
                        "\"\(KilnLibraryCopy.listTitle)\" counts rather than names")
                }
                let list = try w.source(OneChatListWorld.chatList)
                guard list.contains("navigationTitle(KilnLibraryCopy.listTitle)") else {
                    throw BrineStepError("the list is titled with something else")
                }
                let quantified = OneChatListWorld.stringLiterals(in: list)
                    .filter { ChatProvenance.isBareQuantifier($0) || $0.lowercased().hasPrefix("all ") }
                guard quantified.isEmpty else {
                    throw BrineStepError("the list still counts rather than names: \(quantified)")
                }
            },
            defineCheck("the rule that says so can actually reject one") { _, _, _ in
                // POSITIVE CONTROL. A rule that cannot fire makes every use of it vacuous,
                // and "All" is the precise label this whole line of work removed.
                guard ChatProvenance.isBareQuantifier("All") else {
                    throw BrineStepError(
                        "the bare-quantifier rule does not even reject \"All\" — it cannot "
                            + "fail, so it proves nothing about any label")
                }
                guard !ChatProvenance.isBareQuantifier("Claude Code") else {
                    throw BrineStepError("the rule is broken: it rejects a real source name")
                }
            },
        ]
    }
}

private extension OneChatListWorld {
    static func occurrences(of needle: String, in text: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        var count = 0
        var range = text.startIndex..<text.endIndex
        while let found = text.range(of: needle, range: range) {
            count += 1
            range = found.upperBound..<text.endIndex
        }
        return count
    }
}
