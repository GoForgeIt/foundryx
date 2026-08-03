import XCTest
import Foundation
import FoundryXKit

/// The phone's client for Kiln's SHARED conversation library. The door routes are
/// server-tested in foundry; here we prove the PHONE sends the right path + bearer, keeps a
/// structured chat id intact, decodes the tolerant wire shapes — and, above all, maps door
/// statuses onto a vocabulary that cannot be mistaken for an empty library.
///
/// STATUS DISCIPLINE IS THE POINT OF THIS FILE. The door deliberately answers 503 (it holds
/// no kiln-session at all) and 502 (the session is unreachable or refused) rather than an
/// empty list, because an empty list reads on the phone as "you have no conversations" when
/// the truth is "the door could not ask". These tests exist to stop that distinction being
/// optimised away into the `404 → []` degradation the SEARCH client correctly uses.
///
/// LAN path stubbed via URLProtocol — no relay, no network.
final class DoorClientKilnLibraryTests: XCTestCase {

    final class Stub: URLProtocol {
        nonisolated(unsafe) static var lastRequest: URLRequest?
        nonisolated(unsafe) static var status = 200
        nonisolated(unsafe) static var body = Data()
        /// When set, the request FAILS at the transport layer instead of answering.
        nonisolated(unsafe) static var transportError: Error?

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            Self.lastRequest = request
            if let e = Self.transportError {
                client?.urlProtocol(self, didFailWithError: e)
                return
            }
            let resp = HTTPURLResponse(url: request.url!, statusCode: Self.status,
                                       httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Self.body)
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    private func client() -> DoorClient {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [Stub.self]
        let target = DoorTarget(baseURL: URL(string: "http://computer.local:14288")!, bearer: "tok-77")
        return DoorClient(target: target, session: URLSession(configuration: cfg))
    }

    override func setUp() {
        super.setUp()
        Stub.status = 200
        Stub.body = Data()
        Stub.transportError = nil
        Stub.lastRequest = nil
    }

    /// A structured imported id, exactly the shape measured on the live store.
    private let importedId = "import:claude-code:workflows:wf_ae593755-e61:abbdae8d72a12b0fc"

    // MARK: - the library page

    func testLibrarySendsPathBearerAndPagingAndDecodesTheRealWireShape() async throws {
        // The EXACT envelope the live kiln-session returns, including a row with every
        // `skip_serializing_if` field ABSENT (the shape ~9,300 of 10,236 live rows have)
        // alongside one carrying them.
        Stub.body = Data(#"""
        {"chats":[
          {"archived":0,"fork_from_seq":null,"id":"2686e7e9-1d32-4628-9749-d9acc8d7ca29",
           "last_activity_at":"2026-08-03T23:17:46.351889+00:00",
           "last_message_at":"2026-08-03T23:17:46.351889+00:00",
           "last_message_preview":"ping","loop_id":"","model":null,"org":"foundryx",
           "origin":"kiln","parent_chat_id":null,"parent_task_session_id":null,
           "project_id":null,"sensitivity":"internal",
           "started_at":"2026-07-26T16:58:52.719133+00:00","title":null},
          {"archived":0,"fork_from_seq":null,"id":"import:claude-code:9ebcbd64",
           "import_partial":true,"import_partial_reason":"1 image/binary attachment(s) not rendered as text",
           "import_project_root":"/Users/nicholasrinard/Development",
           "last_activity_at":"2026-08-03T23:10:18.072Z","last_message_at":"2026-08-03T23:10:18.072Z",
           "last_message_preview":"Running properly now","loop_id":"loop:a311035e50947c5",
           "model":"claude-fable-5","org":"personal","origin":"claude-code",
           "parent_chat_id":null,"parent_task_session_id":null,"project_id":null,
           "sensitivity":"internal","started_at":"2026-07-18T14:20:03.436Z",
           "title":"Loop/Graph Analysis - Design"}],
         "has_more":true,"limit":50,"offset":0,"snapshot":10251,"stores":["primary"],
         "total":2722,"total_is_lower_bound":false}
        """#.utf8)

        let page = try await client().kilnLibrary(limit: 25, offset: 100, query: "rendezvous fix")

        XCTAssertEqual(page.total, 2722)
        XCTAssertEqual(page.snapshot, 10251)
        XCTAssertTrue(page.hasMore)
        XCTAssertEqual(page.stores, ["primary"])
        XCTAssertEqual(page.chats.count, 2)

        // The minimal row: every absent field takes its default rather than failing.
        let minimal = page.chats[0]
        XCTAssertNil(minimal.title)
        XCTAssertEqual(minimal.loopId, "")
        XCTAssertEqual(minimal.archived, 0)
        XCTAssertFalse(minimal.resumed, "an ABSENT `resumed` is false, not a decode failure")
        XCTAssertFalse(minimal.importPartial, "an ABSENT `import_partial` is false")
        XCTAssertNil(minimal.sourceState, "an ABSENT `source_state` stays unknown")

        let imported = page.chats[1]
        XCTAssertTrue(imported.importPartial)
        XCTAssertEqual(imported.importProjectRoot, "/Users/nicholasrinard/Development")
        XCTAssertEqual(imported.loopId, "loop:a311035e50947c5")

        let req = try XCTUnwrap(Stub.lastRequest)
        XCTAssertEqual(req.httpMethod, "GET")
        XCTAssertEqual(req.url?.path, "/foundryx/chats")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer tok-77")
        let q = try XCTUnwrap(req.url?.query)
        XCTAssertTrue(q.contains("limit=25"), q)
        XCTAssertTrue(q.contains("offset=100"), q)
        // The door percent-DECODES `q` then allow-lists the decoded term, so the space must
        // arrive as %20.
        XCTAssertTrue(q.contains("q=rendezvous%20fix"), q)
    }

    func testAnEmptyQueryIsOmittedRatherThanSentAsBlank() async throws {
        Stub.body = Data(#"{"chats":[],"total":0}"#.utf8)
        _ = try await client().kilnLibrary(query: "   ")
        let q = try XCTUnwrap(Stub.lastRequest?.url?.query)
        XCTAssertFalse(q.contains("q="), "a blank filter must not become an empty search term: \(q)")
    }

    // MARK: - status discipline

    func testNoSessionIsItsOwnStateAndNeverAnEmptyLibrary() async {
        Stub.status = 503
        do {
            let page = try await client().kilnLibrary()
            XCTFail("503 became a library of \(page.chats.count) rows — that reads as 'you have no conversations'")
        } catch {
            XCTAssertEqual(error as? KilnLibraryError, .noSession)
        }
    }

    func testUnreachableIsItsOwnStateAndNeverAnEmptyLibrary() async {
        Stub.status = 502
        do {
            let page = try await client().kilnLibrary()
            XCTFail("502 became a library of \(page.chats.count) rows")
        } catch {
            XCTAssertEqual(error as? KilnLibraryError, .unreachable)
        }
    }

    func testUnauthorizedIsDistinctFromUnreachable() async {
        Stub.status = 401
        do {
            _ = try await client().kilnLibrary()
            XCTFail("401 should not produce a library")
        } catch {
            XCTAssertEqual(error as? KilnLibraryError, .unauthorized)
        }
    }

    /// The SEARCH client degrades a 404 to `[]` on purpose. The LIBRARY must not: a door
    /// that does not know this route cannot be reported as a user with no conversations.
    func testLibrary404IsAnErrorNotAnEmptyList() async {
        Stub.status = 404
        do {
            let page = try await client().kilnLibrary()
            XCTFail("404 degraded to \(page.chats.count) rows — the search client's degradation leaked in")
        } catch {
            XCTAssertEqual(error as? KilnLibraryError, .http(404))
        }
    }

    func testATransportFailureIsUnreachableNotAnEmptyList() async {
        Stub.transportError = URLError(.cannotConnectToHost)
        do {
            let page = try await client().kilnLibrary()
            XCTFail("a dead connection produced \(page.chats.count) rows")
        } catch {
            XCTAssertEqual(error as? KilnLibraryError, .unreachable)
        }
    }

    func testUnparsableBodyIsUnreachableNotAnEmptyLibrary() async {
        Stub.body = Data("<html>not json</html>".utf8)
        do {
            let page = try await client().kilnLibrary()
            XCTFail("garbage decoded to \(page.chats.count) rows")
        } catch {
            XCTAssertEqual(error as? KilnLibraryError, .unreachable)
        }
    }

    // MARK: - the org document

    func testChatOrgDecodesTheDoubleEncodedDocument() async throws {
        // `doc` is a JSON STRING holding the document — two decodes, not one.
        Stub.body = Data(#"{"doc":"{\"groups\":[{\"id\":\"g-work\",\"name\":\"Work\",\"color\":\"forge-blue\",\"rank\":0}],\"membership\":{\"c1\":\"g-work\"},\"pins\":{\"c1\":true},\"colors\":{},\"order\":{\"c1\":1.5},\"version\":1}"}"#.utf8)

        let org = try await client().kilnChatOrg(org: "personal")

        XCTAssertEqual(org.groups.map(\.id), ["g-work"])
        XCTAssertEqual(org.groups.first?.name, "Work")
        XCTAssertEqual(KilnChatOrg.groupOf(org, "c1"), "g-work")
        XCTAssertTrue(KilnChatOrg.isPinned(org, "c1"))
        XCTAssertEqual(org.order["c1"], 1.5)
        XCTAssertEqual(Stub.lastRequest?.url?.path, "/foundryx/chat-org")
        XCTAssertEqual(Stub.lastRequest?.url?.query, "org=personal")
    }

    /// A never-persisted document is a fresh workspace with no groups — a SUCCESS.
    func testNullDocumentIsAnEmptyOrgNotAFailure() async throws {
        Stub.body = Data(#"{"doc":null}"#.utf8)
        let org = try await client().kilnChatOrg()
        XCTAssertEqual(org, KilnChatOrg.empty)
    }

    /// An older door that predates the route resolves the same way — "no groups", not a
    /// failure. This is the ONE place a 404 is legitimately not an error.
    func testChatOrg404IsAnEmptyOrgNotAFailure() async throws {
        Stub.status = 404
        let org = try await client().kilnChatOrg()
        XCTAssertEqual(org, KilnChatOrg.empty)
    }

    /// …but 502/503 still throw. "We could not ask" must never render as "nothing is filed".
    func testChatOrgStillThrowsOnAnUnreachableDoor() async {
        Stub.status = 503
        do {
            _ = try await client().kilnChatOrg()
            XCTFail("a 503 on the org document degraded to 'no groups'")
        } catch {
            XCTAssertEqual(error as? KilnLibraryError, .noSession)
        }
    }

    func testMalformedDocumentLeavesTheLibraryUngroupedRatherThanFailing() async throws {
        Stub.body = Data(#"{"doc":"{not json at all"}"#.utf8)
        let org = try await client().kilnChatOrg()
        XCTAssertEqual(org, KilnChatOrg.empty)
    }

    // MARK: - one conversation

    /// The load-bearing URL test. An imported id is STRUCTURED and full of colons; the door's
    /// allow-list admits `:` and rejects `%`, so percent-encoding one would 404 every
    /// imported conversation — the exact defect these routes exist to close.
    func testMessagesKeepsAStructuredChatIdIntactInThePath() async throws {
        Stub.body = Data(#"""
        {"messages":[
          {"id":5737942,"role":"user","parts":{"role":"user","text":"where were we"},"cleared":0,"imported":true},
          {"id":5737943,"role":"assistant","parts":{"role":"assistant","text":"right here"},"cleared":0,"imported":false}]}
        """#.utf8)

        let messages = try await client().kilnChatMessages(chatId: importedId)

        XCTAssertEqual(messages.map(\.id), ["5737942", "5737943"])
        XCTAssertEqual(messages[0].role, "user")
        XCTAssertEqual(messages[0].text, "where were we", "the turn's text lives under `parts`")
        XCTAssertTrue(messages[0].imported)
        XCTAssertFalse(messages[1].imported)

        let path = try XCTUnwrap(Stub.lastRequest?.url?.path)
        XCTAssertEqual(path, "/foundryx/chats/\(importedId)/messages")
        XCTAssertTrue(path.contains(":"), "the colons must survive: \(path)")
        XCTAssertFalse(path.contains("%3A"), "a percent-encoded colon 404s at the door: \(path)")
    }

    func testContinuePostsAndKeepsTheOriginalId() async throws {
        Stub.body = Data(#"""
        {"session_id":"import:claude-code:workflows:wf_ae593755-e61:abbdae8d72a12b0fc",
         "harness":"claude-code","source_conversation_id":"wf_ae593755-e61",
         "source_file":"/Users/nick/.claude/projects/x.jsonl","sensitivity":"internal",
         "seeded_turns":31,"native_writeback":"disarmed",
         "native_writeback_detail":"The source transcript is not written back to."}
        """#.utf8)

        let result = try await client().kilnContinueChat(chatId: importedId)

        XCTAssertEqual(result.sessionId, importedId, "resume-in-place: the SAME id comes back")
        XCTAssertEqual(result.harness, "claude-code")
        XCTAssertEqual(result.seededTurns, 31)
        XCTAssertEqual(result.nativeWriteback, "disarmed")
        XCTAssertEqual(Stub.lastRequest?.httpMethod, "POST")
        XCTAssertEqual(Stub.lastRequest?.url?.path, "/foundryx/chats/\(importedId)/continue")
    }

    /// A continue that answers with a DIFFERENT id has forked, not resumed. Navigating there
    /// quietly would strand the user in a copy of their own conversation.
    func testContinueRefusesAReplyNamingADifferentConversation() async {
        Stub.body = Data(#"{"session_id":"some-brand-new-session","harness":"claude-code"}"#.utf8)
        do {
            let r = try await client().kilnContinueChat(chatId: importedId)
            XCTFail("accepted a continue that returned \(r.sessionId) instead of the id posted to")
        } catch {
            XCTAssertEqual(error as? KilnLibraryError, .unreachable)
        }
    }

    func testContinueOnAnUnreachableSessionIsNotASilentSuccess() async {
        Stub.status = 502
        do {
            _ = try await client().kilnContinueChat(chatId: importedId)
            XCTFail("a 502 continue reported success")
        } catch {
            XCTAssertEqual(error as? KilnLibraryError, .unreachable)
        }
    }

    // MARK: - the copy the user actually reads

    /// Each failure names a DIFFERENT, actionable state, and none of them says the library is
    /// empty. A stopped Kiln and a sleeping Mac are not the same problem and do not have the
    /// same fix.
    func testFailureCopyNamesTheRealStateAndNeverClaimsAnEmptyLibrary() {
        let noSession = DoorFailureMessage.make(kilnLibraryFailure: .noSession)
        let unreachable = DoorFailureMessage.make(kilnLibraryFailure: .unreachable)
        XCTAssertNotEqual(noSession, unreachable, "a stopped Kiln reads the same as a sleeping Mac")
        XCTAssertTrue(noSession.text.contains("Kiln"))

        for msg in [noSession, unreachable,
                    DoorFailureMessage.make(kilnLibraryFailure: .http(500)),
                    DoorFailureMessage.make(kilnLibraryFailure: .unauthorized)] {
            let line = msg.line.lowercased()
            for lie in ["no conversation", "empty", "nothing here"] {
                XCTAssertFalse(line.contains(lie), "failure copy claims an empty library: \(msg.line)")
            }
            for leak in ["502", "503", "nserror", "error domain"] {
                XCTAssertFalse(line.contains(leak), "a transport detail leaked into copy: \(msg.line)")
            }
            XCTAssertFalse(msg.text.isEmpty)
        }
    }
}
