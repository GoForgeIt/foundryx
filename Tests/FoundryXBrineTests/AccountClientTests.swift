import XCTest
import Foundation
import FoundryXKit

/// The phone side of the account/waitlist pipeline (track 20260705T1100). The relay
/// derives the account from the VERIFIED token (server-tested in foundry); here we
/// prove the client sends identity-only profile + bearer, and the once-per-account
/// gate self-heals on failure.
final class AccountClientTests: XCTestCase {

    // URLProtocol stub capturing the request and replying with a canned status.
    final class Stub: URLProtocol {
        nonisolated(unsafe) static var lastRequest: URLRequest?
        nonisolated(unsafe) static var lastBody: Data?
        nonisolated(unsafe) static var status = 200
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            Self.lastRequest = request
            Self.lastBody = request.httpBody ?? request.httpBodyStream.map { stream in
                stream.open()
                defer { stream.close() }
                var data = Data()
                var buf = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let n = stream.read(&buf, maxLength: buf.count)
                    if n <= 0 { break }
                    data.append(buf, count: n)
                }
                return data
            }
            let resp = HTTPURLResponse(url: request.url!, statusCode: Self.status,
                                       httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    private func stubbedClient() -> AccountClient {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [Stub.self]
        return AccountClient(baseURL: URL(string: "https://relay.example:8788")!,
                             session: URLSession(configuration: cfg))
    }

    func testSignupPostsIdentityOnlyProfileWithBearer() async throws {
        Stub.status = 200
        let ok = await stubbedClient().postSignup(idToken: "tok-123", name: "Zach GoForgeIt")
        XCTAssertTrue(ok)

        let req = try XCTUnwrap(Stub.lastRequest)
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertEqual(req.url?.path, "/account/signup")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer tok-123")

        let body = try JSONSerialization.jsonObject(with: XCTUnwrap(Stub.lastBody)) as! [String: String]
        XCTAssertEqual(body["name"], "Zach GoForgeIt")
        XCTAssertNotNil(body["locale"])
        XCTAssertNotNil(body["device_model"])
        XCTAssertNotNil(body["os_version"])
        // Identity-only: the client must never claim an email (account comes from
        // the verified token server-side) and never carry content.
        XCTAssertNil(body["email"])
        XCTAssertNil(body["transcript"])
    }

    func testWaitlistPostsToWaitlistPath() async throws {
        Stub.status = 200
        let ok = await stubbedClient().postWaitlist(idToken: "tok-9")
        XCTAssertTrue(ok)
        XCTAssertEqual(Stub.lastRequest?.url?.path, "/account/waitlist")
    }

    func testFailedPostReportsFalseSoTheOnceFlagStaysUnset() async {
        Stub.status = 401
        let ok = await stubbedClient().postSignup(idToken: "expired", name: nil)
        XCTAssertFalse(ok, "a rejected POST must NOT be marked as done")
    }

    func testOncePerAccountGateSelfHeals() {
        let defaults = UserDefaults(suiteName: "account-client-tests-\(UUID().uuidString)")!
        XCTAssertTrue(AccountClient.shouldPostSignup(account: "Nick@GoForgeIt.com", defaults: defaults))
        AccountClient.markSignupPosted(account: "nick@goforgeit.com", defaults: defaults)
        XCTAssertFalse(AccountClient.shouldPostSignup(account: "Nick@GoForgeIt.com", defaults: defaults),
                       "gate is case-insensitive on the account")
        XCTAssertTrue(AccountClient.shouldPostSignup(account: "other@goforgeit.com", defaults: defaults))
    }
}
