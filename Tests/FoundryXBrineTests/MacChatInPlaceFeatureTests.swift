import XCTest
import Foundation
import BrineSwiftCore
@testable import FoundryXKit
import SwiftUI
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// Brine driver for features/mac-chat-in-place.feature.
///
/// Drives the REAL types: `KilnConversationPresentation` for what may be built and where the
/// reader lands, and `KilnRemoteTurn` over the REAL `DoorClient` against a `URLProtocol` stub
/// that RECORDS every request — so "typing is how you continue" is proved by the wire
/// sequence (`…/continue` then `/foundryx/chat` on the same id) rather than restated.
///
/// GROUND TRUTH THIS SUITE IS SHAPED BY (measured 2026-08-05 against the live door, 2,745
/// chats): the largest chat holds 42,311 turns / 44.4 MB. Fetching and decoding it took
/// 122 ms; building every turn into a hosted `ChatView` took 22,831 ms and then died with
/// SIGSEGV; building the newest 40 took 69 ms. The scenario about a huge chat therefore seeds
/// tens of thousands of turns, not a toy — a 50-turn seed would pass under the old, eager
/// code and prove nothing.
final class MacChatInPlaceFeatureTests: XCTestCase {
    func testMacChatInPlaceFeature() async throws {
        try await BrineFeatureRunner.run(
            "mac-chat-in-place",
            registry: StepRegistry(MacChatSteps.make(world: MacChatWorld())))
    }
}

// MARK: - the recording stub (hermetic; proves the real client, not a restatement)

/// Answers the two routes a Mac-chat turn touches and RECORDS every request in order:
/// `POST /foundryx/chats/<id>/continue` and `POST /foundryx/chat`.
private final class MacChatStub: URLProtocol {
    struct Seen: Equatable { let method: String; let path: String; let body: Data? }

    nonisolated(unsafe) static var seen: [Seen] = []
    /// The `session_id` the continue route claims. Setting it to something else is how the
    /// "a reply naming some other chat is refused" half is exercised.
    nonisolated(unsafe) static var continueSessionId = ""

    static func reset(sessionId: String) {
        seen = []
        continueSessionId = sessionId
    }

    static var continues: [Seen] { seen.filter { $0.path.hasSuffix("/continue") } }
    static var turns: [Seen] { seen.filter { $0.path == "/foundryx/chat" } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let path = request.url?.path ?? ""
        // URLProtocol strips httpBody for streamed uploads; `httpBodyStream` carries it.
        var body = request.httpBody
        if body == nil, let stream = request.httpBodyStream {
            stream.open()
            var out = Data()
            let size = 4096
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
            defer { buffer.deallocate(); stream.close() }
            while stream.hasBytesAvailable {
                let read = stream.read(buffer, maxLength: size)
                if read <= 0 { break }
                out.append(buffer, count: read)
            }
            body = out
        }
        Self.seen.append(Seen(method: request.httpMethod ?? "", path: path, body: body))

        let payload: Data
        let contentType: String
        if path.hasSuffix("/continue") {
            contentType = "application/json"
            payload = Data(#"{"session_id":"\#(Self.continueSessionId)","harness":"claude-code","source_conversation_id":"c","source_file":"/tmp/c.jsonl","sensitivity":"internal","seeded_turns":12}"#.utf8)
        } else {
            contentType = "text/event-stream"
            payload = Data((
                "data: {\"type\":\"assistant_delta\",\"text\":\"carrying on\"}\n\n"
                + "data: {\"type\":\"done\",\"reason\":\"stop\"}\n\n").utf8)
        }
        let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                   headerFields: ["Content-Type": contentType])!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: payload)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private func stubbedClient() -> DoorClient {
    let cfg = URLSessionConfiguration.ephemeral
    cfg.protocolClasses = [MacChatStub.self]
    let target = DoorTarget(baseURL: URL(string: "http://computer.local:14288")!, bearer: "tok-9")
    return DoorClient(target: target, session: URLSession(configuration: cfg))
}

// MARK: - the world

private final class MacChatWorld: @unchecked Sendable {

    /// A structured, colon-bearing imported id — the shape that measurably exists in the live
    /// store, so the colons are exercised all the way to the URL.
    static let importedId = "import:claude-code:ace8a355-f09b-4d5f-9a4c-fa031b5c9204"
    static let liveId = "f28a1ec9-733a-468f-8bf6-ece510c0fc19"

    var row: LibraryChatRow?
    var turns: [KilnMessage] = []
    var opened: KilnConversationPresentation.Opened?
    var plan: KilnConversationPresentation.SendPlan = .send
    var sent: [String] = []
    var sendError: Error?
    var unreachable: String?
    var mismatchRefused = false
    /// The rendered message state each surface ends up with, keyed by which corpus it came
    /// from — compared to prove there is ONE surface, not two that look alike.
    var rendered: [String: [String]] = [:]
    var hosted: [String: Bool] = [:]

    func requireOpened() throws -> KilnConversationPresentation.Opened {
        guard let opened else { throw BrineStepError("no chat has been opened") }
        return opened
    }

    func requireRow() throws -> LibraryChatRow {
        guard let row else { throw BrineStepError("no chat was seeded") }
        return row
    }

    func open() {
        guard let row else { return }
        let o = KilnConversationPresentation.open(row, turns: turns)
        opened = o
        plan = o.sendPlan
    }

    /// Type and send, through the REAL client. Records the outcome rather than throwing, so a
    /// scenario can assert on a refusal.
    @MainActor
    func send(_ text: String) async {
        guard let row else { return }
        do {
            plan = try await KilnRemoteTurn.send(
                text: text, row: row, plan: plan, client: stubbedClient(),
                onEvent: { _ in })
            sent.append(text)
        } catch {
            sendError = error
        }
    }
}

// MARK: - fixtures

private func turn(_ n: Int, role: String) -> KilnMessage {
    KilnMessage(id: "t\(n)", role: role, text: "turn \(n)", imported: true)
}

/// `count` turns, oldest → newest, the order the door returns them in.
private func transcript(_ count: Int) -> [KilnMessage] {
    (0..<count).map { turn($0, role: $0.isMultiple(of: 2) ? "user" : "assistant") }
}

private func importedRow(resumed: Bool = false) -> LibraryChatRow {
    LibraryChatRow(
        id: MacChatWorld.importedId, title: "The long one", origin: "claude-code",
        sensitivity: "internal", org: "foundryx",
        lastMessageAt: "2026-08-04T10:00:00Z",
        importProjectRoot: "/Users/nick/Development/kiln", resumed: resumed)
}

private func liveRow() -> LibraryChatRow {
    LibraryChatRow(
        id: MacChatWorld.liveId, title: "Already going", origin: "kiln",
        sensitivity: "internal", org: "foundryx",
        lastMessageAt: "2026-08-05T11:00:00Z")
}

// MARK: - steps

private enum MacChatSteps {
    static func make(world w: MacChatWorld) -> [StepDefinition] {
        [
            // ── Given ────────────────────────────────────────────────────────
            defineStep("my computer is connected") { ctx, _, _ in
                w.row = nil
                w.turns = []
                w.opened = nil
                w.plan = .send
                w.sent = []
                w.sendError = nil
                w.unreachable = nil
                w.mismatchRefused = false
                w.rendered = [:]
                w.hosted = [:]
                MacChatStub.reset(sessionId: "")
                return ctx
            },
            defineStep("a chat on my Mac that I have been going back and forth in") { ctx, _, _ in
                w.row = importedRow(resumed: true)
                w.turns = transcript(120)
                return ctx
            },
            defineStep("a chat on my Mac holding tens of thousands of turns") { ctx, _, _ in
                // The size measured on the real library. A small seed would pass under the
                // eager code this replaces and would therefore prove nothing.
                w.row = importedRow(resumed: true)
                w.turns = transcript(42_311)
                return ctx
            },
            defineStep("a chat on my Mac brought over from Claude Code that I have never picked up") { ctx, _, _ in
                w.row = importedRow(resumed: false)
                w.turns = transcript(120)
                MacChatStub.reset(sessionId: MacChatWorld.importedId)
                return ctx
            },
            defineStep("a chat on my Mac that is already live in Kiln") { ctx, _, _ in
                w.row = liveRow()
                w.turns = transcript(120)
                MacChatStub.reset(sessionId: MacChatWorld.liveId)
                return ctx
            },
            defineStep("a chat on my Mac and a chat that started on my phone, saying the same things") { ctx, _, _ in
                w.row = importedRow(resumed: true)
                w.turns = transcript(12)
                return ctx
            },
            defineStep("that chat cannot be read") { ctx, _, _ in
                w.row = importedRow(resumed: true)
                w.turns = []
                w.unreachable = DoorFailureMessage.make(
                    kilnLibraryFailure: KilnLibraryError.unreachable, destination: .computer).line
                return ctx
            },

            // ── When ─────────────────────────────────────────────────────────
            defineStep("I open that chat on my phone") { ctx, _, _ in
                w.open()
                return ctx
            },
            defineStep("I ask for earlier turns") { ctx, _, _ in
                w.opened = KilnConversationPresentation.showOlder(try w.requireOpened())
                return ctx
            },
            defineStep("I type into it and send") { ctx, _, _ in
                await w.send("carry on then")
                return ctx
            },
            defineStep("I type into it and send again") { ctx, _, _ in
                await w.send("and one more thing")
                return ctx
            },
            defineStep("I open each of them") { ctx, _, _ in
                w.open()
                let mac = try w.requireOpened()
                // The phone's OWN corpus, saying the same things — built the way a chat that
                // started on this phone is built, straight out of the durable store.
                let phone = w.turns.map {
                    ChatConversationStore.StoredMessage(role: $0.role, text: $0.text)
                }
                guard !phone.isEmpty, phone.count == mac.stored.count else {
                    throw BrineStepError(
                        "the two corpora do not hold the same turns, so comparing what they "
                            + "render would prove nothing (mac \(mac.stored.count), "
                            + "phone \(phone.count))")
                }
                try renderBoth(mac: mac.stored, phone: phone, into: w)
                return ctx
            },

            // ── Then: where it opens ─────────────────────────────────────────
            defineCheck("it opens on the newest thing that was said") { _, _, _ in
                let opened = try w.requireOpened()
                guard let newest = w.turns.last?.id else {
                    throw BrineStepError("the seed has no turns, so this proves nothing")
                }
                guard opened.openAt == newest else {
                    throw BrineStepError(
                        "it opens on '\(opened.openAt ?? "nothing")', not the newest turn "
                            + "'\(newest)' — which is how a chat of thousands of turns became "
                            + "impossible to interact with")
                }
            },
            defineCheck("it does not open on the oldest") { _, _, _ in
                let opened = try w.requireOpened()
                guard let oldest = w.turns.first?.id, w.turns.count > 1 else {
                    throw BrineStepError("the seed cannot tell newest from oldest")
                }
                guard opened.openAt != oldest else {
                    throw BrineStepError("it opens at the top of the chat, as it used to")
                }
            },

            // ── Then: what gets built ────────────────────────────────────────
            defineCheck("only a small window of the newest turns is built") { _, _, _ in
                let opened = try w.requireOpened()
                let page = KilnConversationPresentation.pageSize
                guard opened.visible.count <= page else {
                    throw BrineStepError(
                        "\(opened.visible.count) turns were built at once; the window is "
                            + "\(page). Building all 42,311 measured 22,831 ms and then died")
                }
                guard opened.visible.count == page else {
                    throw BrineStepError(
                        "only \(opened.visible.count) turns were built out of a full page of "
                            + "\(page) — the window is not being filled")
                }
                // And it is the NEWEST window, not the oldest.
                guard opened.visible.last?.id == w.turns.last?.id,
                      opened.visible.first?.id == w.turns[w.turns.count - page].id else {
                    throw BrineStepError(
                        "the window is not the tail: it runs "
                            + "\(opened.visible.first?.id ?? "?")…\(opened.visible.last?.id ?? "?")")
                }
            },
            defineCheck("the rest are held back rather than built") { _, _, _ in
                let opened = try w.requireOpened()
                guard opened.turns.count == w.turns.count else {
                    throw BrineStepError(
                        "the held transcript lost turns — \(opened.turns.count) of \(w.turns.count)")
                }
                let expected = w.turns.count - KilnConversationPresentation.pageSize
                guard opened.hasOlder, opened.olderCount == expected else {
                    throw BrineStepError(
                        "\(opened.olderCount) turns are held back, expected \(expected)")
                }
            },

            // ── Then: reaching back ──────────────────────────────────────────
            defineCheck("more of the earlier turns are built") { _, _, _ in
                let opened = try w.requireOpened()
                let page = KilnConversationPresentation.pageSize
                guard opened.visible.count == page * 2 else {
                    throw BrineStepError(
                        "asking for earlier turns built \(opened.visible.count), expected "
                            + "\(page * 2) — asking changed nothing")
                }
                guard opened.hasOlder else {
                    throw BrineStepError(
                        "one ask built the whole 42,311-turn chat, which is the hang itself")
                }
            },
            defineCheck("asking enough times reaches the very first thing that was said") { _, _, _ in
                var opened = try w.requireOpened()
                let page = KilnConversationPresentation.pageSize
                var asks = 0
                let ceiling = opened.turns.count / page + 4
                while opened.hasOlder && asks < ceiling {
                    opened = KilnConversationPresentation.showOlder(opened)
                    asks += 1
                }
                guard !opened.hasOlder else {
                    throw BrineStepError(
                        "after \(asks) asks, \(opened.olderCount) turns are still unreachable")
                }
                guard opened.visible.first?.id == w.turns.first?.id,
                      opened.visible.count == w.turns.count else {
                    throw BrineStepError(
                        "the oldest turn never came back: built \(opened.visible.count) of "
                            + "\(w.turns.count), starting at \(opened.visible.first?.id ?? "?")")
                }
            },

            // ── Then: typing is the continue ─────────────────────────────────
            defineCheck("it is picked back up for me without my having asked separately") { _, _, _ in
                let row = try w.requireRow()
                if let e = w.sendError { throw BrineStepError("the turn failed: \(e)") }
                guard MacChatStub.continues.count == 1 else {
                    throw BrineStepError(
                        "the chat was resumed \(MacChatStub.continues.count) times on one "
                            + "send — a first turn must resume it exactly once")
                }
                // The resume happened BEFORE the turn, in one gesture, with nothing between.
                guard MacChatStub.seen.count == 2,
                      MacChatStub.seen[0].path.hasSuffix("/continue"),
                      MacChatStub.seen[1].path == "/foundryx/chat" else {
                    throw BrineStepError(
                        "sending did not resume-then-send: \(MacChatStub.seen.map(\.path))")
                }
                // The structured id's colons must reach the door INTACT — the door's chat-id
                // allow-list admits `:` and rejects `%`.
                guard MacChatStub.seen[0].path == "/foundryx/chats/\(row.id)/continue" else {
                    throw BrineStepError(
                        "the id did not survive the URL: '\(MacChatStub.seen[0].path)'")
                }
            },
            defineCheck("what I typed is sent into that same chat") { _, _, _ in
                let row = try w.requireRow()
                guard let turn = MacChatStub.turns.last, let body = turn.body else {
                    throw BrineStepError("no turn reached the door at all")
                }
                let wire = try decodeTurn(body)
                guard wire.chatId == row.id else {
                    throw BrineStepError(
                        "the turn went to chat '\(wire.chatId)', not the one being read "
                            + "'\(row.id)' — that is a new chat beside it, not carrying on")
                }
                guard let last = w.sent.last, wire.message == last else {
                    throw BrineStepError(
                        "the door received '\(wire.message)', not what was typed "
                            + "('\(w.sent.last ?? "nothing")')")
                }
                guard wire.org == row.org else {
                    throw BrineStepError(
                        "the turn carried org '\(wire.org)', not the chat's own '\(row.org)' — "
                            + "kiln open-or-resumes by (platform, chat_id, org)")
                }
            },

            // ── Then: it is the same chat, not a copy ────────────────────────
            defineCheck("everything went to the id of the chat I was reading") { _, _, _ in
                let row = try w.requireRow()
                guard !MacChatStub.seen.isEmpty else {
                    throw BrineStepError("nothing reached the door, so this proves nothing")
                }
                for seen in MacChatStub.continues {
                    guard seen.path == "/foundryx/chats/\(row.id)/continue" else {
                        throw BrineStepError("a resume went to '\(seen.path)'")
                    }
                }
                for seen in MacChatStub.turns {
                    let wire = try decodeTurn(seen.body ?? Data())
                    guard wire.chatId == row.id else {
                        throw BrineStepError("a turn went to chat '\(wire.chatId)'")
                    }
                }
            },
            defineCheck("a reply naming some other chat is refused") { _, _, _ in
                let row = try w.requireRow()
                // The other half, or "it keeps the chat I was in" is unfalsifiable: the same
                // real client, told the resume landed somewhere else, must REFUSE.
                MacChatStub.reset(sessionId: "some-other-session")
                do {
                    _ = try await KilnRemoteTurn.send(
                        text: "should never go out", row: row,
                        plan: .resumeInPlaceThenSend, client: stubbedClient(),
                        onEvent: { _ in })
                    throw BrineStepError(
                        "a resume that came back naming a DIFFERENT chat was accepted — that "
                            + "is a fork, not carrying on")
                } catch is BrineStepError {
                    throw BrineStepError(
                        "a resume that came back naming a DIFFERENT chat was accepted — that "
                            + "is a fork, not carrying on")
                } catch {
                    w.mismatchRefused = true
                }
                guard MacChatStub.turns.isEmpty else {
                    throw BrineStepError(
                        "the turn went out anyway, into a chat that is not the one being read")
                }
            },

            // ── Then: already live ───────────────────────────────────────────
            defineCheck("nothing is picked up, because it already was") { _, _, _ in
                if let e = w.sendError { throw BrineStepError("the turn failed: \(e)") }
                guard MacChatStub.continues.isEmpty else {
                    throw BrineStepError(
                        "a live chat was resumed again: \(MacChatStub.continues.map(\.path))")
                }
                guard !MacChatStub.turns.isEmpty else {
                    throw BrineStepError(
                        "no turn went out either, so 'nothing was resumed' proves nothing")
                }
            },
            defineCheck("it was picked back up exactly once") { _, _, _ in
                if let e = w.sendError { throw BrineStepError("a turn failed: \(e)") }
                guard MacChatStub.continues.count == 1 else {
                    throw BrineStepError(
                        "two sends resumed the chat \(MacChatStub.continues.count) times — a "
                            + "chat is picked back up once, on its first turn")
                }
            },
            defineCheck("both of the things I typed were sent") { _, _, _ in
                guard w.sent.count == 2 else {
                    throw BrineStepError("\(w.sent.count) turns were sent, expected 2")
                }
                let bodies = try MacChatStub.turns.map { try decodeTurn($0.body ?? Data()).message }
                guard bodies == w.sent else {
                    throw BrineStepError(
                        "the door received \(bodies), not what was typed (\(w.sent))")
                }
            },

            // ── Then: one surface ────────────────────────────────────────────
            defineCheck("both render through the same chat surface") { _, _, _ in
                guard let mac = w.rendered["mac"], let phone = w.rendered["phone"] else {
                    throw BrineStepError("one of the two surfaces was never rendered")
                }
                guard !mac.isEmpty else {
                    throw BrineStepError("nothing rendered, so equality proves nothing")
                }
                guard mac == phone else {
                    throw BrineStepError(
                        "the two surfaces render different state:\n  mac:   \(mac)\n  phone: \(phone)")
                }
                guard w.hosted["mac"] == true, w.hosted["phone"] == true else {
                    throw BrineStepError(
                        "a surface produced no layout: \(w.hosted)")
                }
            },
            defineCheck("neither screen builds a chat surface of its own") { _, _, _ in
                // The defect was structural: two screens, two renderings of a chat, and the
                // one for the Mac's chats had none of the behaviour. So this reads the app's
                // own source. `ChatView` — the bubbles — must be reached through `ChatSurface`
                // and from nowhere else.
                let hosts = ["App/ChatScreen.swift", "App/KilnConversationView.swift"]
                let surfaces = try AppSourceTree.filesReferencing("ChatSurface")
                for host in hosts {
                    guard surfaces.contains(host) else {
                        throw BrineStepError(
                            "\(host) does not render the shared chat surface — it has its own "
                                + "(surfaces: \(surfaces))")
                    }
                }
                let direct = try AppSourceTree.filesReferencing("ChatView")
                guard direct.isEmpty else {
                    throw BrineStepError(
                        "the chat bubbles are built directly in \(direct) instead of through "
                            + "ChatSurface — that is a second rendering of a chat, which is "
                            + "the whole defect")
                }
                let composers = try AppSourceTree.filesReferencing("GrainComposer")
                guard composers.isEmpty else {
                    throw BrineStepError(
                        "a composer is built outside the shared surface in \(composers)")
                }
            },

            // ── Then: an unreadable chat ─────────────────────────────────────
            defineCheck("I am told it could not be read") { _, _, _ in
                guard let message = w.unreachable, !message.isEmpty else {
                    throw BrineStepError("no failure message was produced")
                }
                guard !KilnChatCopy.unreadableTitle.isEmpty else {
                    throw BrineStepError("the failure has no title")
                }
                for leak in ["502", "503", "NSURLError", "Error Domain"] {
                    guard !message.contains(leak) else {
                        throw BrineStepError(
                            "a transport detail leaked into user-facing copy: '\(message)'")
                    }
                }
            },
            defineCheck("I am never shown it as a chat where nothing was said") { _, _, _ in
                guard let message = w.unreachable else {
                    throw BrineStepError("no failure message was produced")
                }
                guard KilnChatCopy.unreadableTitle != KilnChatCopy.emptyTitle else {
                    throw BrineStepError(
                        "an unreadable chat and an empty one say the same thing, so the "
                            + "reader cannot tell which is true")
                }
                guard !message.contains(KilnChatCopy.emptyTitle) else {
                    throw BrineStepError(
                        "the empty-chat words were used for a failure: '\(message)'")
                }
                for lie in ["nothing was said", "no messages", "empty"] {
                    guard !message.lowercased().contains(lie) else {
                        throw BrineStepError(
                            "the failure copy claims the chat is empty: '\(message)'")
                    }
                }
            },
        ]
    }
}

// MARK: - helpers

/// The outbound turn as the door sees it.
private struct WireTurn: Decodable {
    let message: String
    let chatId: String
    let org: String
    enum CodingKeys: String, CodingKey {
        case message, org
        case chatId = "chat_id"
    }
}

private func decodeTurn(_ body: Data) throws -> WireTurn {
    guard let wire = try? JSONDecoder().decode(WireTurn.self, from: body) else {
        throw BrineStepError("the outgoing turn did not decode: "
            + String(decoding: body, as: UTF8.self))
    }
    return wire
}

/// Render BOTH corpora through the shared surface and record what each ends up showing.
///
/// Same view model, same loader, same hosted view — so if the two ever diverge it is because
/// somebody built a second surface, which is exactly the regression this guards.
private func renderBoth(mac: [ChatConversationStore.StoredMessage],
                        phone: [ChatConversationStore.StoredMessage],
                        into w: MacChatWorld) throws {
    for (label, stored) in [("mac", mac), ("phone", phone)] {
        var lines: [String] = []
        var laidOut = false
        DispatchQueue.main.sync {
            // Everything here builds and hosts a real view, so it must be main-actor isolated;
            // `DispatchQueue.main.sync` guarantees that at runtime but not to the compiler.
            MainActor.assumeIsolated {
                let model = ChatViewModel()
                model.load(from: stored)
                lines = model.messages.map { "\($0.role): \($0.text)" }
                var input = ""
                let binding = Binding(get: { input }, set: { input = $0 })
                laidOut = layOutChatSurface(ChatSurface(
                    model: model, input: binding,
                    placeholder: KilnChatCopy.composerPlaceholder,
                    isSending: false, onSend: {}))
            }
        }
        w.rendered[label] = lines
        w.hosted[label] = laidOut
    }
}

/// Host the surface in the platform's real view hierarchy and lay it out, answering whether it
/// produced a real size.
///
/// This suite runs in TWO lanes: `swift test` on macOS, and the iOS-simulator lane the publish
/// pipeline gates on (`xcodebuild test -scheme FoundryX`). It used to host through `NSHostingView`
/// under `#if canImport(AppKit)` and, on anything else, THROW "SwiftUI/AppKit unavailable". iOS has
/// no AppKit, so the scenario that proves the Mac's chats and the phone's chats are one surface
/// could never pass in the lane that runs on the phone's own runtime — it reported a product
/// failure that was really a missing host, and it held every publish from `da3eaf7` onward.
///
/// So each platform hosts through its own container, and there is deliberately NO fallback branch:
/// a platform that cannot host this must fail to COMPILE. A test that quietly reports "cannot be
/// checked here" is the defect class this file exists to prevent.
#if canImport(AppKit)
@MainActor
private func layOutChatSurface<V: View>(_ view: V) -> Bool {
    let host = NSHostingView(rootView: view)
    host.frame = NSRect(x: 0, y: 0, width: 390, height: 700)
    host.layoutSubtreeIfNeeded()
    return host.fittingSize.width > 0
}
#elseif canImport(UIKit)
@MainActor
private func layOutChatSurface<V: View>(_ view: V) -> Bool {
    let host = UIHostingController(rootView: view)
    host.view.frame = CGRect(x: 0, y: 0, width: 390, height: 700)
    host.view.setNeedsLayout()
    host.view.layoutIfNeeded()
    return host.sizeThatFits(in: CGSize(width: 390, height: 700)).width > 0
}
#endif
