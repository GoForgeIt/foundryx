import XCTest
import Foundation
import FoundryXKit

/// The live signup client's WIRE contract against a URLProtocol stub (never the real
/// Cloud Run service) — proves paths, method, Bearer id_token, and status parsing. The
/// funnel state-machine test stubs the VaultSignupService seam directly; this test is the
/// one place the concrete HTTP shaping is pinned.
final class VaultSignupClientTests: XCTestCase {

    final class Stub: URLProtocol {
        nonisolated(unsafe) static var lastRequest: URLRequest?
        nonisolated(unsafe) static var lastBody: Data?
        nonisolated(unsafe) static var responseJSON: [String: Any] = [:]
        nonisolated(unsafe) static var status = 200
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            Self.lastRequest = request
            Self.lastBody = request.httpBody ?? request.httpBodyStream.map { stream in
                stream.open(); defer { stream.close() }
                var data = Data(); var buf = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let n = stream.read(&buf, maxLength: buf.count)
                    if n <= 0 { break }; data.append(buf, count: n)
                }
                return data
            }
            let resp = HTTPURLResponse(url: request.url!, statusCode: Self.status,
                                       httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: Self.responseJSON))
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    private func client() -> VaultSignupClient {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [Stub.self]
        return VaultSignupClient(
            baseURL: URL(string: "https://foundry-signup-449450484577.us-central1.run.app")!,
            session: URLSession(configuration: cfg))
    }

    func testCheckoutAttemptPostsPlanAndReturnsIdAndURL() async throws {
        Stub.status = 200
        Stub.responseJSON = ["checkout_attempt_id": "att-9",
                             "checkout_url": "https://checkout.goforgeit.com/s/att-9"]
        let attempt = try await client().createCheckoutAttempt(plan: .pro, idToken: "tok-1")

        let req = try XCTUnwrap(Stub.lastRequest)
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertEqual(req.url?.path, "/signup/checkout-attempt")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer tok-1")
        let body = try JSONSerialization.jsonObject(with: XCTUnwrap(Stub.lastBody)) as! [String: String]
        XCTAssertEqual(body["plan"], "pro")
        XCTAssertEqual(attempt.id, "att-9")
        XCTAssertEqual(attempt.checkoutURL?.absoluteString, "https://checkout.goforgeit.com/s/att-9")
    }

    func testReconcilePendingProvisioningReady() async throws {
        Stub.status = 200
        Stub.responseJSON = ["status": "pending"]
        var s = try await client().reconcile(attemptId: "att-9", idToken: "tok-1")
        XCTAssertEqual(s, .pending)
        XCTAssertEqual(Stub.lastRequest?.url?.path, "/signup/reconcile")

        Stub.responseJSON = ["status": "provisioning"]
        s = try await client().reconcile(attemptId: "att-9", idToken: "tok-1")
        XCTAssertEqual(s, .provisioning)

        Stub.responseJSON = ["status": "ready",
                             "cell_url": "https://foundry-cell-acme.fly.dev",
                             "handoff": "door-xyz"]
        s = try await client().reconcile(attemptId: "att-9", idToken: "tok-1")
        XCTAssertEqual(s, .ready(cellURL: "https://foundry-cell-acme.fly.dev", handoff: "door-xyz"))
    }

    func testReturnTicketExchange() async throws {
        Stub.status = 200
        Stub.responseJSON = ["status": "ready",
                             "cell_url": "https://foundry-cell-acme.fly.dev",
                             "door_bearer": "door-xyz"]
        let s = try await client().exchangeReturn(ticket: "OPAQUE", idToken: nil)
        XCTAssertEqual(Stub.lastRequest?.url?.path, "/app/return")
        let body = try JSONSerialization.jsonObject(with: XCTUnwrap(Stub.lastBody)) as! [String: String]
        XCTAssertEqual(body["ticket"], "OPAQUE")
        XCTAssertEqual(s, .ready(cellURL: "https://foundry-cell-acme.fly.dev", handoff: "door-xyz"))
    }

    func testServerErrorThrows() async {
        Stub.status = 500
        Stub.responseJSON = [:]
        do {
            _ = try await client().reconcile(attemptId: "x", idToken: nil)
            XCTFail("a 5xx must throw")
        } catch {
            XCTAssertEqual(error as? VaultSignupError, .server)
        }
    }

    func testProvisioningReasonSurvivesA5xxResponse() async {
        Stub.status = 500
        Stub.responseJSON = ["error": "registry error: cell already exists: c-123"]
        do {
            _ = try await client().reconcile(attemptId: "x", idToken: nil)
            XCTFail("a provisioning failure must throw its displayable reason")
        } catch {
            XCTAssertEqual(error as? VaultSignupError,
                           .provisioning("registry error: cell already exists: c-123"))
        }
    }

    func testFailedStatusPreservesReasonAndRecognisesExistingVault() async throws {
        Stub.status = 200
        Stub.responseJSON = ["status": "failed", "reason": "registry could not create cell"]
        let failed = try await client().reconcile(attemptId: "x", idToken: nil)
        XCTAssertEqual(failed, .failed(.server("registry could not create cell")))

        Stub.responseJSON = ["status": "failed", "reason": "cell already exists: c-123"]
        let existing = try await client().reconcile(attemptId: "x", idToken: nil)
        XCTAssertEqual(existing, .failed(.alreadyExists))
    }
}
