import XCTest
import Foundation
import BrineSwiftCore
@testable import FoundryXKit

/// Brine driver for features/kiln-library.feature. Drives the REAL library port —
/// `KilnLibrary.toNodes`, `KilnChatOrg`, `KilnLibraryPresentation.rail/resolve`,
/// `KilnConversationNotice` — plus the REAL `DoorClient.kilnContinueChat` over a
/// `URLProtocol` stub, so the resume-in-place contract is proved through the actual client
/// rather than restated. Hermetic: no network, no live kiln-session, no UI.
///
/// GROUND TRUTH THIS SUITE IS SHAPED BY (measured against the live store, 2026-08-03, 2,724
/// rows through the door's upstream `GET /chats/library`): 0 subagent children, 0 forks, 0
/// archived rows, and an EMPTY org document. Those four behaviours therefore CANNOT be
/// proved by pointing at production data — they are seeded here, and each is asserted
/// against a NON-EMPTY expected set, because an assertion over an empty collection is the
/// classic check that can never fail.
final class KilnLibraryFeatureTests: XCTestCase {
    func testKilnLibraryFeature() async throws {
        try await BrineFeatureRunner.run(
            "kiln-library",
            registry: StepRegistry(KilnLibrarySteps.make(world: KilnLibraryWorld())))
    }
}

// MARK: - the world

private final class KilnLibraryWorld: @unchecked Sendable {

    /// A FIXED clock. The Time lens buckets on the local calendar day, so a wall-clock
    /// `now` would make bucket membership drift with the hour the suite runs.
    static let now: Double = 1_754_265_600_000  // 2026-08-04T00:00:00Z

    var rows: [LibraryChatRow] = []
    /// The org document EXACTLY as it arrives on the wire — a double-encoded
    /// `{"doc":"<json string>"}` — so `parseOrg` is exercised through the real double decode.
    var orgWire: String = #"{"doc":null}"#
    var connected = true
    var failure: KilnLibraryError?
    var lens = KilnLibraryPresentation.Lens.project
    var sort = KilnLibraryPresentation.Sort.recent
    var query = ""
    var collapsed: Set<String> = []

    var state: KilnLibraryPresentation.State = .idle
    /// The state the SAME inputs would produce on a 502 — used to prove that an empty
    /// library and an unreachable one are not the same state.
    var stateIfUnreachable: KilnLibraryPresentation.State = .idle
    var notices: [String: KilnConversationNotice] = [:]
    var continueOutcome: Result<KilnContinueResult, Error>?
    var continuePath: String?
    var mismatchedContinueRejected = false

    func reset() {
        rows = []
        orgWire = #"{"doc":null}"#
        connected = true
        failure = nil
        lens = .project
        sort = .recent
        query = ""
        collapsed = []
        state = .idle
        stateIfUnreachable = .idle
        notices = [:]
        continueOutcome = nil
        continuePath = nil
        mismatchedContinueRejected = false
    }

    /// Decode the wire envelope the way the client does — `{"doc": "<json>"}` where `doc` is
    /// itself a JSON STRING — then parse the inner document.
    var org: OrgState {
        let env = try? JSONDecoder().decode(
            ChatOrgEnvelope.self, from: Data(orgWire.utf8))
        return KilnChatOrg.parseOrg(env?.doc)
    }

    /// Run the real resolver. When `failure` is set the injected load THROWS it, exactly as
    /// the door client would — nothing here fabricates an empty page out of a failure.
    func open() async {
        let page = LibraryPage(chats: rows, total: rows.count)
        let org = self.org
        let fail = failure
        state = await KilnLibraryPresentation.resolve(
            computerConnected: connected, destination: .computer, lens: lens, sort: sort, query: query,
            nowMs: Self.now,
            load: {
                if let fail { throw fail }
                return KilnLibraryPresentation.Load(page: page, org: org)
            })
        stateIfUnreachable = await KilnLibraryPresentation.resolve(
            computerConnected: connected, destination: .computer, lens: lens, sort: sort, query: query,
            nowMs: Self.now,
            load: { throw KilnLibraryError.unreachable })
    }

    var rail: KilnLibraryPresentation.Rail? {
        if case .loaded(let r) = state { return r }
        return nil
    }

    func requireRail() throws -> KilnLibraryPresentation.Rail {
        guard let rail else {
            throw BrineStepError("expected a loaded library, got \(state)")
        }
        return rail
    }

    func node(_ id: String) throws -> ChatNode {
        guard let n = try requireRail().allNodes.first(where: { $0.id == id }) else {
            throw BrineStepError("no row for \(id); the library rendered "
                + "\(try requireRail().allNodes.map(\.id))")
        }
        return n
    }

    func unreachableMessage() throws -> String {
        guard case .unreachable(let m) = state else {
            throw BrineStepError("expected .unreachable, got \(state)")
        }
        return m
    }
}

// MARK: - the continue stub (hermetic; proves the real client, not a restatement)

/// Replies to `POST /foundryx/chats/<id>/continue` with a `session_id` this test chooses, so
/// the resume-in-place guard inside `DoorClient.kilnContinueChat` is exercised for real.
private final class ContinueStub: URLProtocol {
    nonisolated(unsafe) static var lastPath: String?
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var sessionId = ""
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lastPath = request.url?.path
        let body = Data(#"{"session_id":"\#(Self.sessionId)","harness":"claude-code","source_conversation_id":"c","source_file":"/tmp/c.jsonl","sensitivity":"internal","seeded_turns":12}"#.utf8)
        let resp = HTTPURLResponse(url: request.url!, statusCode: Self.status,
                                   httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private func stubbedDoorClient() -> DoorClient {
    let cfg = URLSessionConfiguration.ephemeral
    cfg.protocolClasses = [ContinueStub.self]
    let target = DoorTarget(baseURL: URL(string: "http://computer.local:14288")!, bearer: "tok-9")
    return DoorClient(target: target, session: URLSession(configuration: cfg))
}

// MARK: - fixtures

/// A structured, colon-bearing imported id — the shape that measurably exists in the live
/// store. Using it everywhere keeps the suite honest about the ids the phone must address.
private let importedId = "import:claude-code:workflows:wf_ae593755-e61:abbdae8d72a12b0fc"

private func importedRow(
    id: String = importedId,
    title: String = "Rendezvous fix",
    cwd: String? = "/Users/nick/Development/kiln",
    resumed: Bool = false,
    at: String = "2026-08-01T10:00:00Z"
) -> LibraryChatRow {
    LibraryChatRow(
        id: id, title: title, model: "claude-fable-5", origin: "claude-code",
        startedAt: "2026-07-18T14:20:03.436Z", lastMessageAt: at,
        importProjectRoot: cwd, resumed: resumed)
}

private func kilnRow(
    id: String, title: String, at: String,
    archived: Int = 0, projectId: String? = nil, loopId: String = "",
    parentChatId: String? = nil, parentTaskSessionId: String? = nil
) -> LibraryChatRow {
    LibraryChatRow(
        id: id, title: title, model: "kiln-router", projectId: projectId,
        origin: "kiln", archived: archived, startedAt: at,
        parentChatId: parentChatId, lastMessageAt: at, loopId: loopId,
        parentTaskSessionId: parentTaskSessionId)
}

// MARK: - steps

private enum KilnLibrarySteps {
    static func make(world w: KilnLibraryWorld) -> [StepDefinition] {
        [
            // ── Given ────────────────────────────────────────────────────────
            defineStep("my computer is connected") { ctx, _, _ in
                w.reset(); w.connected = true; return ctx
            },
            defineStep("Kiln's library holds a conversation imported from Claude Code") { ctx, _, _ in
                w.rows = [importedRow()]
                return ctx
            },
            defineStep("Kiln's library holds an imported conversation I already picked up") { ctx, _, _ in
                w.rows = [importedRow(resumed: true)]
                return ctx
            },
            defineStep("a recurring job has fired many times, each firing its own conversation") { ctx, _, _ in
                // NO project_id and NO import_project_root on any firing. That shape is
                // deliberate: on the live corpus every loop row ALSO carries a synthetic
                // import-cwd project, so the project guard in `isInbox` MASKS the loop guard
                // and a corpus-shaped seed can never tell the two apart. Measured: dropping
                // the loop guard leaves the real Inbox at 31 either way. Only a loop row with
                // no project of any kind makes that guard falsifiable — which is what this is.
                w.rows = [
                    kilnRow(id: "fire-1", title: "Nightly monitor", at: "2026-07-01T01:00:00Z", loopId: "loop:nightly"),
                    kilnRow(id: "fire-3", title: "Nightly monitor", at: "2026-08-03T01:00:00Z", loopId: "loop:nightly"),
                    kilnRow(id: "fire-2", title: "Nightly monitor", at: "2026-07-15T01:00:00Z", loopId: "loop:nightly"),
                    kilnRow(id: "plain-1", title: "An ordinary chat", at: "2026-08-02T09:00:00Z"),
                ]
                return ctx
            },
            defineStep("a conversation spawned a subagent that had its own conversation") { ctx, _, _ in
                w.rows = [
                    kilnRow(id: "spawner-1", title: "The parent run", at: "2026-08-01T09:00:00Z",
                            projectId: "proj-1"),
                    kilnRow(id: "sub-1", title: "The subagent's own work", at: "2026-08-01T09:30:00Z",
                            projectId: "proj-1", parentTaskSessionId: "spawner-1"),
                ]
                return ctx
            },
            // These four carry a project on purpose. An UNFILED chat belongs to the Inbox
            // zone, and the lens BODY is `active − inbox` — so a project-less seed would
            // leave every lens body empty and the lineage assertions would be passing over
            // an empty collection, which is the classic check that can never fail. (The
            // first run of this suite did exactly that, and the non-empty guards caught it.)
            defineStep("one conversation was forked from another") { ctx, _, _ in
                w.rows = [
                    kilnRow(id: "base-1", title: "The original", at: "2026-08-01T08:00:00Z",
                            projectId: "proj-1"),
                    kilnRow(id: "fork-1", title: "A fork of the original", at: "2026-08-01T08:30:00Z",
                            projectId: "proj-1", parentChatId: "base-1"),
                ]
                return ctx
            },
            defineStep("a different conversation spawned a subagent") { ctx, _, _ in
                w.rows.append(kilnRow(id: "spawner-1", title: "The parent run",
                                      at: "2026-08-01T09:00:00Z", projectId: "proj-1"))
                w.rows.append(kilnRow(id: "sub-1", title: "The subagent's own work",
                                      at: "2026-08-01T09:30:00Z", projectId: "proj-1",
                                      parentTaskSessionId: "spawner-1"))
                return ctx
            },
            defineStep("Kiln's library holds a Claude Code conversation that ran in a project directory") { ctx, _, _ in
                // Paired with an UNFILED native chat, so the Inbox assertion has both a row
                // that must be in it and a row that must not — a one-sided seed would let an
                // always-empty Inbox pass.
                w.rows = [
                    importedRow(),
                    kilnRow(id: "loose-1", title: "An unfiled quick chat", at: "2026-08-02T11:00:00Z"),
                ]
                return ctx
            },
            defineStep("on my Mac I filed a conversation into a group") { ctx, _, _ in
                w.rows = [
                    kilnRow(id: "filed-1", title: "Filed under Work", at: "2026-08-01T12:00:00Z"),
                    kilnRow(id: "loose-1", title: "An unfiled quick chat", at: "2026-08-02T11:00:00Z"),
                ]
                w.orgWire = wireOrg(#"""
                {"groups":[{"id":"g-work","name":"Work","color":"forge-blue","rank":0},
                           {"id":"g-empty","name":"Someday","color":null,"rank":1}],
                 "membership":{"filed-1":"g-work"},
                 "pins":{},"colors":{},"order":{},"version":1}
                """#)
                return ctx
            },
            defineStep("on my Mac I pinned an older conversation") { ctx, _, _ in
                w.rows = [kilnRow(id: "pinned-old", title: "Pinned but old", at: "2026-06-01T09:00:00Z")]
                w.orgWire = wireOrg(#"""
                {"groups":[{"id":"g-work","name":"Work","color":null,"rank":0}],
                 "membership":{"pinned-old":"g-work","fresh-new":"g-work"},
                 "pins":{"pinned-old":true},"colors":{},"order":{},"version":1}
                """#)
                return ctx
            },
            defineStep("a different conversation was touched more recently") { ctx, _, _ in
                w.rows.append(kilnRow(id: "fresh-new", title: "Newer, unpinned", at: "2026-08-03T09:00:00Z"))
                return ctx
            },
            defineStep("Kiln's library holds an archived conversation and an active one") { ctx, _, _ in
                w.rows = [
                    kilnRow(id: "arch-1", title: "Shelved sunsetting plan", at: "2026-07-02T09:00:00Z",
                            archived: 1, projectId: "proj-1"),
                    kilnRow(id: "act-1", title: "Still going", at: "2026-08-03T09:00:00Z",
                            projectId: "proj-1"),
                ]
                return ctx
            },
            defineStep("I have collapsed History") { ctx, _, _ in
                w.collapsed = ["z:archive"]; return ctx
            },
            defineStep("the door has no Kiln session at all") { ctx, _, _ in
                w.failure = .noSession; return ctx
            },
            defineStep("Kiln cannot be reached") { ctx, _, _ in
                w.failure = .unreachable; return ctx
            },
            defineStep("Kiln's library is genuinely empty") { ctx, _, _ in
                w.rows = []; w.failure = nil; return ctx
            },
            defineStep("an imported conversation's original transcript is gone from disk") { ctx, _, _ in
                // BOTH postures, because the notice must render whether or not the
                // conversation has already been picked up — it is the fact a reader needs
                // BEFORE deciding, and hiding it from someone who already acted is worse.
                w.rows = [
                    LibraryChatRow(
                        id: "gone-1", title: "Its file is gone", origin: "claude-code",
                        lastMessageAt: "2026-07-20T10:00:00Z",
                        sourceState: "evicted", sourceEvictedAt: "2026-07-30T12:00:00Z",
                        sourceEvidence: #"{"checked":"/Users/nick/.claude/projects/x.jsonl"}"#),
                    LibraryChatRow(
                        id: "gone-2", title: "Gone, and already picked up", origin: "claude-code",
                        lastMessageAt: "2026-07-21T10:00:00Z", resumed: true,
                        sourceState: "MISSING ", sourceEvictedAt: "2026-07-29T12:00:00Z"),
                ]
                return ctx
            },
            defineStep("an imported conversation says nothing about whether its transcript is still on disk") { ctx, _, _ in
                // `silent-1` omits source_state entirely — the shape 10,236 live rows have.
                // `claims-present-1` says "present", which the store said for 10,043 rows
                // while 2,302 of those files (22.9%) did not exist. NEITHER may produce a
                // claim in either direction.
                w.rows = [
                    LibraryChatRow(id: "silent-1", title: "Says nothing", origin: "claude-code",
                                   lastMessageAt: "2026-07-20T10:00:00Z"),
                    LibraryChatRow(id: "claims-present-1", title: "Store says present",
                                   origin: "claude-code", lastMessageAt: "2026-07-20T10:00:00Z",
                                   sourceState: "present"),
                ]
                return ctx
            },
            defineStep("a conversation was only partly imported") { ctx, _, _ in
                w.rows = [
                    LibraryChatRow(id: "partial-1", title: "Partly imported", origin: "claude-code",
                                   lastMessageAt: "2026-07-20T10:00:00Z",
                                   importPartial: true,
                                   importPartialReason: "3 image/binary attachment(s) not rendered as text"),
                    LibraryChatRow(id: "partial-2", title: "Partly imported, no reason given",
                                   origin: "codex-cli", lastMessageAt: "2026-07-20T10:00:00Z",
                                   importPartial: true),
                ]
                return ctx
            },
            defineStep("Kiln's library holds a row carrying only the fields that are always sent") { ctx, _, _ in
                // Decoded from the EXACT always-present key set, with every
                // `skip_serializing_if` field ABSENT — the shape ~9,300 of 10,236 live rows
                // have. A decoder that requires any of the absent eight fails here.
                let json = #"""
                {"chats":[{"archived":0,"fork_from_seq":null,
                 "id":"2686e7e9-1d32-4628-9749-d9acc8d7ca29",
                 "last_activity_at":"2026-08-03T23:17:46.351889+00:00",
                 "last_message_at":"2026-08-03T23:17:46.351889+00:00",
                 "last_message_preview":"ping","loop_id":"","model":null,"org":"foundryx",
                 "origin":"kiln","parent_chat_id":null,"parent_task_session_id":null,
                 "project_id":null,"sensitivity":"internal",
                 "started_at":"2026-07-26T16:58:52.719133+00:00","title":null}],
                 "has_more":false,"limit":50,"offset":0,"snapshot":10251,
                 "stores":["primary"],"total":1,"total_is_lower_bound":false}
                """#
                guard let page = try? JSONDecoder().decode(LibraryPage.self, from: Data(json.utf8)) else {
                    throw BrineStepError("a row carrying only the always-present fields FAILED to decode")
                }
                guard page.chats.count == 1 else {
                    throw BrineStepError("expected the one minimal row, got \(page.chats.count)")
                }
                w.rows = page.chats
                return ctx
            },
            defineStep("my grouping document on the Mac is corrupt") { ctx, _, _ in
                w.rows = [kilnRow(id: "survivor-1", title: "Still here", at: "2026-08-02T09:00:00Z",
                                  projectId: "proj-1")]
                w.orgWire = #"{"doc":"{\"groups\":[{\"id\":\"ok\"} ,, not json at all"}"#
                return ctx
            },

            // ── When ─────────────────────────────────────────────────────────
            defineStep("I open the Kiln library on my phone") { ctx, _, _ in
                await w.open(); return ctx
            },
            defineStep("I look at the library by lineage") { ctx, _, _ in
                w.lens = .tree; await w.open(); return ctx
            },
            defineStep("I look at the library by my own grouping") { ctx, _, _ in
                w.lens = .manual; await w.open(); return ctx
            },
            defineStep("I filter for a term that only the archived conversation matches") { ctx, _, _ in
                w.query = "sunsetting"; await w.open(); return ctx
            },
            defineStep("I open that conversation on my phone") { ctx, _, _ in
                await w.open()
                for row in w.rows { w.notices[row.id] = KilnConversationNotice.make(row) }
                return ctx
            },

            // ── Then: the gap this closes ────────────────────────────────────
            defineCheck("I see that Claude Code conversation") { _, _, _ in
                _ = try w.node(importedId)
            },
            defineCheck("it is marked as having come from Claude Code") { _, _, _ in
                let n = try w.node(importedId)
                guard n.source == "Claude Code" else {
                    throw BrineStepError("source label was '\(n.source)', not 'Claude Code'")
                }
                guard KilnLibrary.sourceTag(n.source).short == "CC" else {
                    throw BrineStepError("badge was '\(KilnLibrary.sourceTag(n.source).short)', not 'CC'")
                }
            },
            defineCheck("that conversation offers to be picked up") { _, _, _ in
                let notice = KilnConversationNotice.make(try w.node(importedId).row)
                guard notice.offersPickUp else {
                    throw BrineStepError("an imported, never-resumed conversation was not offered a pick-up")
                }
                guard notice.imported else {
                    throw BrineStepError("provenance was lost — the row no longer reads as imported")
                }
            },
            defineCheck("picking it up resumes that same conversation rather than starting a new one") { _, _, _ in
                // The REAL client, over a stub. Two halves: the honest reply must be
                // accepted AND carry the same id, and a reply naming a DIFFERENT id must be
                // REFUSED — otherwise "resumes that same conversation" is unfalsifiable.
                ContinueStub.status = 200
                ContinueStub.sessionId = importedId
                let result = try await stubbedDoorClient().kilnContinueChat(chatId: importedId)
                w.continueOutcome = .success(result)
                w.continuePath = ContinueStub.lastPath
                guard result.sessionId == importedId else {
                    throw BrineStepError("continue returned \(result.sessionId), not the id posted to")
                }
                // The structured id's colons must reach the door INTACT: the door's chat-id
                // allow-list admits `:` and rejects `%`, so encoding them would 404 every
                // imported conversation.
                guard let path = w.continuePath, path == "/foundryx/chats/\(importedId)/continue" else {
                    throw BrineStepError("continue hit '\(w.continuePath ?? "nil")' — the id did not survive the URL")
                }
                ContinueStub.sessionId = "some-other-session"
                do {
                    _ = try await stubbedDoorClient().kilnContinueChat(chatId: importedId)
                    throw BrineStepError("a continue naming a DIFFERENT id was accepted — that is a fork, not a resume")
                } catch is BrineStepError {
                    throw BrineStepError("a continue naming a DIFFERENT id was accepted — that is a fork, not a resume")
                } catch {
                    w.mismatchedContinueRejected = true
                }
            },
            defineCheck("that conversation is not offered a pick-up") { _, _, _ in
                let notice = KilnConversationNotice.make(try w.node(importedId).row)
                guard !notice.offersPickUp else {
                    throw BrineStepError("an already-resumed conversation was offered a second pick-up")
                }
            },
            defineCheck("it still says it came from Claude Code") { _, _, _ in
                let n = try w.node(importedId)
                guard KilnLibrary.isImportedOrigin(n.row.origin), n.source == "Claude Code" else {
                    throw BrineStepError("picking it up erased its provenance — source is '\(n.source)'")
                }
            },

            // ── Then: parity of grouping ─────────────────────────────────────
            defineCheck("I see one row for that job, not one per firing") { _, _, _ in
                let firings = try w.requireRail().allNodes.filter { $0.loopId == "loop:nightly" }
                guard firings.count == 1 else {
                    throw BrineStepError("the series did not collapse — \(firings.count) rows: \(firings.map(\.id))")
                }
            },
            defineCheck("the row I see is the most recent firing") { _, _, _ in
                let firings = try w.requireRail().allNodes.filter { $0.loopId == "loop:nightly" }
                guard firings.first?.id == "fire-3" else {
                    throw BrineStepError("the surviving firing was \(firings.first?.id ?? "none"), not the newest (fire-3)")
                }
            },
            defineCheck("the row says how many firings it stands for") { _, _, _ in
                let n = try w.node("fire-3")
                guard n.seriesRuns == 3 else {
                    throw BrineStepError("the row stands for 3 firings but reports \(n.seriesRuns)")
                }
                guard KilnLibraryCopy.seriesBadge(n) == "3×" else {
                    throw BrineStepError("no '3×' badge — a row standing for many that says nothing is a lie "
                        + "(got \(KilnLibraryCopy.seriesBadge(n) ?? "nil"))")
                }
                // An ordinary chat must NOT wear one, or the badge means nothing.
                guard KilnLibraryCopy.seriesBadge(try w.node("plain-1")) == nil else {
                    throw BrineStepError("an ordinary one-off chat wore a series badge")
                }
            },
            defineCheck("the job's row is not sitting in my Inbox, even though nothing else filed it") { _, _, _ in
                let rail = try w.requireRail()
                let n = try w.node("fire-3")
                // The seed's whole point: no project of ANY kind, so the loop guard is the
                // only thing that can be excluding it.
                guard n.projectId == nil else {
                    throw BrineStepError("the seed is wrong — this firing has project '\(n.projectId!)', "
                        + "so the project guard would mask the loop guard and this check could not fail")
                }
                guard !rail.inbox.contains(where: { $0.id == "fire-3" }) else {
                    throw BrineStepError("a scheduled firing landed in the Inbox; measured on a real "
                        + "library, 2,242 of 9,897 Inbox rows were firings against 26 real chats")
                }
                // And the Inbox is not simply empty — the ordinary chat IS in it.
                guard rail.inbox.contains(where: { $0.id == "plain-1" }) else {
                    throw BrineStepError("the Inbox is empty, so 'the firing is not in it' proves nothing")
                }
            },
            defineCheck("the subagent's conversation is not a row of its own") { _, _, _ in
                let rail = try w.requireRail()
                guard !rail.allNodes.contains(where: { $0.id == "sub-1" }) else {
                    throw BrineStepError("the subagent's conversation stood alone as a top-level row")
                }
                guard rail.allNodes.contains(where: { $0.id == "spawner-1" }) else {
                    throw BrineStepError("the parent vanished too — the filter is dropping the wrong rows")
                }
            },
            defineCheck("the conversation that spawned it says it has work underneath it") { _, _, _ in
                let rail = try w.requireRail()
                guard !rail.parentIds.isEmpty else {
                    throw BrineStepError("no row was recognised as having spawned anything")
                }
                let n = try w.node("spawner-1")
                guard let note = KilnLibraryCopy.subagentNote(n, parentIds: rail.parentIds, destination: .computer) else {
                    throw BrineStepError("the spawning conversation said nothing about the work underneath it")
                }
                guard note.contains("subagent") else {
                    throw BrineStepError("the affordance does not name what is underneath: '\(note)'")
                }
                // And it is not said about everything — that would make it noise, not a fact.
                guard KilnLibraryCopy.subagentNote(
                    kilnNode(id: "nobody", rail: rail) ?? n, parentIds: [], destination: .computer) == nil else {
                    throw BrineStepError("a row with no children still claimed to have subagent work")
                }
            },
            defineCheck("the fork appears beneath the conversation it was forked from") { _, _, _ in
                let rail = try w.requireRail()
                guard let lineage = rail.groups.first(where: { $0.key == "t:lineage" }) else {
                    throw BrineStepError("no fork-lineage group was rendered")
                }
                guard lineage.nodes.contains(where: { $0.id == "fork-1" }),
                      lineage.nodes.contains(where: { $0.id == "base-1" }) else {
                    throw BrineStepError("the lineage group is missing the fork or its parent: \(lineage.nodes.map(\.id))")
                }
                guard lineage.depth["base-1"] == 0, lineage.depth["fork-1"] == 1 else {
                    throw BrineStepError("the fork is not indented under its parent "
                        + "(base=\(lineage.depth["base-1"] ?? -1), fork=\(lineage.depth["fork-1"] ?? -1))")
                }
                guard let bi = lineage.nodes.firstIndex(where: { $0.id == "base-1" }),
                      let fi = lineage.nodes.firstIndex(where: { $0.id == "fork-1" }),
                      fi == bi + 1 else {
                    throw BrineStepError("the fork does not render directly beneath its parent")
                }
            },
            defineCheck("the subagent's conversation does not appear at all") { _, _, _ in
                let rail = try w.requireRail()
                guard !rail.allNodes.contains(where: { $0.id == "sub-1" }) else {
                    throw BrineStepError("a subagent child was rendered as a lineage row — a fork and a "
                        + "subagent child are different axes and must not be conflated")
                }
                guard rail.allNodes.contains(where: { $0.id == "fork-1" }) else {
                    throw BrineStepError("the fork vanished too — the two axes were collapsed")
                }
            },
            defineCheck("that conversation is filed under the directory it ran in") { _, _, _ in
                let n = try w.node(importedId)
                guard n.projectId == "import-cwd:/Users/nick/Development/kiln" else {
                    throw BrineStepError("no synthetic project — projectId is \(n.projectId ?? "nil")")
                }
                guard n.projectName == "kiln" else {
                    throw BrineStepError("the group is labelled '\(n.projectName ?? "nil")', not the directory's name")
                }
                let rail = try w.requireRail()
                guard let g = rail.groups.first(where: { $0.key == "p:import-cwd:/Users/nick/Development/kiln" }),
                      g.nodes.contains(where: { $0.id == importedId }) else {
                    throw BrineStepError("it was not rendered under its source directory: "
                        + "\(rail.groups.map(\.key))")
                }
            },
            defineCheck("it is not sitting in my Inbox") { _, _, _ in
                let rail = try w.requireRail()
                guard !rail.inbox.contains(where: { $0.id == importedId }) else {
                    throw BrineStepError("an imported conversation with a source directory landed in the Inbox")
                }
                guard rail.inbox.contains(where: { $0.id == "loose-1" }) else {
                    throw BrineStepError("the Inbox is empty, so 'the import is not in it' proves nothing")
                }
            },
            defineCheck("that conversation appears under that group") { _, _, _ in
                let rail = try w.requireRail()
                guard let g = rail.groups.first(where: { $0.key == "m:g-work" }) else {
                    throw BrineStepError("the group I made on the Mac was not rendered: \(rail.groups.map(\.key))")
                }
                guard g.label == "Work" else {
                    throw BrineStepError("the group is labelled '\(g.label)', not 'Work'")
                }
                guard g.nodes.contains(where: { $0.id == "filed-1" }) else {
                    throw BrineStepError("the filed conversation is not in its group: \(g.nodes.map(\.id))")
                }
            },
            defineCheck("a group I made but have not filed anything into is still shown") { _, _, _ in
                let rail = try w.requireRail()
                guard let g = rail.groups.first(where: { $0.key == "m:g-empty" }) else {
                    throw BrineStepError("an empty group vanished — it is still a real destination")
                }
                guard g.nodes.isEmpty else {
                    throw BrineStepError("the empty group is not empty: \(g.nodes.map(\.id))")
                }
            },
            defineCheck("the pinned conversation comes first") { _, _, _ in
                let rail = try w.requireRail()
                guard let g = rail.groups.first(where: { $0.key == "m:g-work" }) else {
                    throw BrineStepError("the group holding both conversations was not rendered")
                }
                guard g.nodes.count == 2 else {
                    throw BrineStepError("expected both conversations in the group, got \(g.nodes.map(\.id))")
                }
                guard g.nodes.first?.id == "pinned-old" else {
                    throw BrineStepError("the newer unpinned conversation won: \(g.nodes.map(\.id))")
                }
            },
            defineCheck("it comes first because it is pinned, not because it is newer") { _, _, _ in
                // Falsification of the reason, not just the outcome: without the pin the
                // SAME two rows must come out the other way round.
                let nodes = KilnLibrary.toNodes(rows: w.rows)
                let unpinned = KilnChatOrg.sortZone(nodes, KilnChatOrg.empty)
                guard unpinned.first?.id == "fresh-new" else {
                    throw BrineStepError("without the pin the newer one should lead, but got "
                        + "\(unpinned.map(\.id)) — so this scenario proves nothing about pinning")
                }
            },
            defineCheck("the archived conversation is not in the body of the list") { _, _, _ in
                let rail = try w.requireRail()
                let body = rail.groups.flatMap(\.nodes).map(\.id)
                guard !body.contains("arch-1") else {
                    throw BrineStepError("an archived conversation was in the body: \(body)")
                }
                guard body.contains("act-1") else {
                    throw BrineStepError("the body is empty, so 'the archived one is not in it' proves nothing")
                }
            },
            defineCheck("it is shown under History") { _, _, _ in
                let rail = try w.requireRail()
                guard rail.archived.contains(where: { $0.id == "arch-1" }) else {
                    throw BrineStepError("the archived conversation is nowhere — it was dropped, not filed")
                }
            },
            defineCheck("History is open anyway") { _, _, _ in
                let rail = try w.requireRail()
                guard rail.filtering else {
                    throw BrineStepError("the rail does not know it is filtering")
                }
                guard rail.isOpen("z:archive", collapsed: w.collapsed) else {
                    throw BrineStepError("History stayed collapsed while filtering, hiding a match")
                }
                // Without a filter the same collapsed set must still close it, or "open
                // anyway" is not attributable to filtering at all.
                let resting = KilnLibraryPresentation.rail(
                    rows: w.rows, org: w.org, lens: w.lens, sort: w.sort, query: "",
                    nowMs: KilnLibraryWorld.now)
                guard !resting.isOpen("z:archive", collapsed: w.collapsed) else {
                    throw BrineStepError("History is open even when not filtering, so this proves nothing")
                }
            },
            defineCheck("I can see the match") { _, _, _ in
                let rail = try w.requireRail()
                guard rail.archived.contains(where: { $0.id == "arch-1" }) else {
                    throw BrineStepError("the matching archived conversation was filtered away entirely")
                }
            },

            // ── Then: honest states ──────────────────────────────────────────
            defineCheck("I am told Kiln could not be reached") { _, _, _ in
                let m = try w.unreachableMessage()
                guard !m.isEmpty else { throw BrineStepError("the failure message is empty") }
                guard m.lowercased().contains("kiln") else {
                    throw BrineStepError("the message does not name what could not be reached: '\(m)'")
                }
                // Never a status code, never an NSError domain — the whole reason
                // DoorFailureMessage exists.
                for leak in ["502", "503", "NSURLError", "Error Domain", "nil"] {
                    guard !m.contains(leak) else {
                        throw BrineStepError("a transport detail leaked into user-facing copy: '\(m)'")
                    }
                }
            },
            defineCheck("I am never told that I have no conversations") { _, _, _ in
                if case .loaded(let rail) = w.state {
                    throw BrineStepError("a failure rendered as a LIBRARY of \(rail.allNodes.count) rows — "
                        + "an empty list here reads as 'you have no conversations'")
                }
                let m = try w.unreachableMessage()
                for lie in ["no conversation", "empty", "nothing here", "no chats"] {
                    guard !m.lowercased().contains(lie) else {
                        throw BrineStepError("the failure copy claims the library is empty: '\(m)'")
                    }
                }
                guard !m.contains(KilnLibraryCopy.emptyTitle), !m.contains(KilnLibraryCopy.emptyMessage) else {
                    throw BrineStepError("the empty-library copy was used for a failure: '\(m)'")
                }
            },
            defineCheck("I am shown an empty library") { _, _, _ in
                let rail = try w.requireRail()
                guard rail.isEmpty else {
                    throw BrineStepError("expected an empty rail, got \(rail.allNodes.count) rows")
                }
            },
            defineCheck("that is a different state from being unable to reach Kiln") { _, _, _ in
                guard case .loaded = w.state else {
                    throw BrineStepError("an empty library is not a failure, but it resolved to \(w.state)")
                }
                guard case .unreachable = w.stateIfUnreachable else {
                    throw BrineStepError("a 502 on the same inputs resolved to \(w.stateIfUnreachable), "
                        + "not .unreachable")
                }
                guard w.state != w.stateIfUnreachable else {
                    throw BrineStepError("an empty library and an unreachable one are the SAME state — "
                        + "the phone cannot tell the user which is true")
                }
            },

            // ── Then: what one conversation may claim ────────────────────────
            defineCheck("I am told its original transcript is gone") { _, _, _ in
                for id in ["gone-1", "gone-2"] {
                    guard let n = w.notices[id] else { throw BrineStepError("no notice for \(id)") }
                    guard case .gone(let headline, _, _, _) = n.sourcePresence else {
                        throw BrineStepError("\(id): an affirmative gone state was not believed")
                    }
                    guard headline == "Its Claude Code transcript is gone" else {
                        throw BrineStepError("\(id): headline was '\(headline)'")
                    }
                }
                // The already-resumed one must say it TOO — it is the fact a reader needs
                // whether or not they already acted.
                guard w.notices["gone-2"]?.resumed == true else {
                    throw BrineStepError("the resumed fixture is not resumed, so this proves nothing")
                }
            },
            defineCheck("I am reassured nothing is lost") { _, _, _ in
                guard case .gone(_, let reassurance, _, _)? = w.notices["gone-1"]?.sourcePresence,
                      reassurance == "Nothing is lost and nothing needs recovering" else {
                    throw BrineStepError("the reassurance is missing or reworded")
                }
            },
            defineCheck("I am told when it was noticed missing") { _, _, _ in
                guard case .gone(_, _, let noticedAt, let evidence)? = w.notices["gone-1"]?.sourcePresence else {
                    throw BrineStepError("gone-1 is not in the gone state")
                }
                guard noticedAt == "Noticed missing 2026-07-30T12:00:00Z." else {
                    throw BrineStepError("the noticed-missing line is '\(noticedAt ?? "nil")'")
                }
                guard evidence == #"{"checked":"/Users/nick/.claude/projects/x.jsonl"}"# else {
                    throw BrineStepError("the engine's evidence was not surfaced verbatim: '\(evidence ?? "nil")'")
                }
            },
            defineCheck("nothing claims its transcript is present") { _, _, _ in
                for id in ["silent-1", "claims-present-1"] {
                    guard let n = w.notices[id] else { throw BrineStepError("no notice for \(id)") }
                    guard n.sourcePresence == .unknown else {
                        throw BrineStepError("\(id): the absence of a gone signal was turned into a claim")
                    }
                    guard n.sourceLine == nil else {
                        throw BrineStepError("\(id): a sentence was rendered where the honest answer is silence: "
                            + "'\(n.sourceLine!)'")
                    }
                }
            },
            defineCheck("nothing claims its transcript is gone") { _, _, _ in
                for id in ["silent-1", "claims-present-1"] {
                    guard let n = w.notices[id] else { throw BrineStepError("no notice for \(id)") }
                    if case .gone = n.sourcePresence {
                        throw BrineStepError("\(id): a non-affirmative source state was read as GONE — "
                            + "only 'missing/evicted/absent/deleted/gone' may be believed")
                    }
                }
            },
            defineCheck("I am told the import was partial") { _, _, _ in
                guard let marker = w.notices["partial-1"]?.partialMarker else {
                    throw BrineStepError("a partial import rendered as if it were complete")
                }
                guard marker.contains("3 image/binary attachment(s) not rendered as text") else {
                    throw BrineStepError("the marker does not name the reason: '\(marker)'")
                }
            },
            defineCheck("a partial import with no stated reason still says it was partial") { _, _, _ in
                guard let marker = w.notices["partial-2"]?.partialMarker else {
                    throw BrineStepError("a partial import with no reason was silenced entirely")
                }
                guard marker == "Partial import — some source content could not be rendered" else {
                    throw BrineStepError("the reasonless marker reads '\(marker)'")
                }
            },

            // ── Then: tolerance ──────────────────────────────────────────────
            defineCheck("that conversation still appears") { _, _, _ in
                let n = try w.node("2686e7e9-1d32-4628-9749-d9acc8d7ca29")
                guard n.title == "Chat 2686e7e9" else {
                    throw BrineStepError("a titleless row should fall back to a short id, got '\(n.title)'")
                }
            },
            defineCheck("the whole library did not fail to load") { _, _, _ in
                guard case .loaded(let rail) = w.state, !rail.allNodes.isEmpty else {
                    throw BrineStepError("one tolerant row should not have cost the library: \(w.state)")
                }
            },
            defineCheck("I still see my conversations") { _, _, _ in
                let rail = try w.requireRail()
                guard rail.allNodes.contains(where: { $0.id == "survivor-1" }) else {
                    throw BrineStepError("a corrupt grouping document took the conversations with it")
                }
            },
            defineCheck("they are simply ungrouped") { _, _, _ in
                guard w.org == KilnChatOrg.empty else {
                    throw BrineStepError("a corrupt document produced groups out of nowhere: \(w.org)")
                }
                let manual = KilnLibraryPresentation.rail(
                    rows: w.rows, org: w.org, lens: .manual, sort: w.sort, query: "",
                    nowMs: KilnLibraryWorld.now)
                guard manual.groups.map(\.key) == ["m:unsorted"] else {
                    throw BrineStepError("expected one Unsorted bucket, got \(manual.groups.map(\.key))")
                }
            },
        ]
    }
}

/// Wrap an org document in the DOUBLE-ENCODED envelope the door actually sends:
/// `{"doc": "<the document, as a JSON string>"}`. Built through a real encoder so the test
/// exercises the same two-step decode the client does, rather than a hand-escaped literal
/// that could quietly be single-encoded.
private func wireOrg(_ document: String) -> String {
    let data = try! JSONSerialization.data(withJSONObject: ["doc": document])
    return String(decoding: data, as: UTF8.self)
}

private func kilnNode(id: String, rail: KilnLibraryPresentation.Rail) -> ChatNode? {
    rail.allNodes.first { $0.id == id }
}
