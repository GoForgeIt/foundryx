import XCTest
import Foundation
import FoundryXKit

/// Full-history search client (track 20260714T1200 AC2): `DoorClient.searchConversations`
/// asks the door for conversations from the computer's Lore library. The door endpoint is
/// server-tested in foundry; here we prove the phone sends the query + bearer on the right
/// path, decodes the hits, and degrades gracefully (404 → empty, non-2xx → throw). LAN
/// path stubbed via URLProtocol — no relay, no network.
final class DoorClientSearchTests: XCTestCase {

    /// URLProtocol stub: captures the request and replies with a canned status + body.
    final class Stub: URLProtocol {
        nonisolated(unsafe) static var lastRequest: URLRequest?
        nonisolated(unsafe) static var status = 200
        nonisolated(unsafe) static var body = Data()
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            Self.lastRequest = request
            let resp = HTTPURLResponse(url: request.url!, statusCode: Self.status,
                                       httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Self.body)
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    private func stubbedClient() -> DoorClient {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [Stub.self]
        let target = DoorTarget(baseURL: URL(string: "http://computer.local:14288")!, bearer: "tok-77")
        return DoorClient(target: target, session: URLSession(configuration: cfg))
    }

    func testSearchDecodesHitsAndSendsQueryPlusBearer() async throws {
        Stub.status = 200
        Stub.body = Data("""
        {"conversations":[
          {"captureId":"omi-1","title":"Casual Bargain Check-In","dateLabel":"2023-11-14","snippet":"Speaker 0 asks where someone is bargaining."},
          {"captureId":"omi-2","title":"Morning Door Access","dateLabel":"2024-01-05","snippet":"Access planned for tomorrow morning."}
        ]}
        """.utf8)

        let hits = try await stubbedClient().searchConversations(query: "bargain door", limit: 25)

        XCTAssertEqual(hits.map(\.captureId), ["omi-1", "omi-2"])
        XCTAssertEqual(hits[0].title, "Casual Bargain Check-In")
        XCTAssertEqual(hits[0].dateLabel, "2023-11-14")

        let req = try XCTUnwrap(Stub.lastRequest)
        XCTAssertEqual(req.httpMethod, "GET")
        XCTAssertEqual(req.url?.path, "/foundryx/conversations")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer tok-77")
        // The term is percent-encoded (space → %20) and the limit is carried.
        let q = try XCTUnwrap(req.url?.query)
        XCTAssertTrue(q.contains("q=bargain%20door"), "term encoded as a query value: \(q)")
        XCTAssertTrue(q.contains("limit=25"), "limit carried: \(q)")
    }

    func testOldDoorWithout404ReturnsEmptyNotAnError() async throws {
        Stub.status = 404
        Stub.body = Data()
        let hits = try await stubbedClient().searchConversations(query: "anything")
        XCTAssertTrue(hits.isEmpty, "an old door without the endpoint degrades to local-only, not an error")
    }

    func testServerErrorThrows() async {
        Stub.status = 502
        Stub.body = Data()
        do {
            _ = try await stubbedClient().searchConversations(query: "x")
            XCTFail("a 502 should surface as an error the UI turns into 'couldn't reach your computer'")
        } catch {
            // expected
        }
    }
}
