import XCTest
import Foundation
@testable import FoundryXKit

/// RelayHTTP is the one place door-bound requests are framed for + parsed off the
/// blind relay tunnel. These lock the raw HTTP/1.1 request shape the door reads and
/// the status/body parse of the door's reply — the seam that was missing entirely
/// (capture/finalize/status/chat all plain-POSTed to the relay's HTTP control port
/// and 404'd instead of going E2E through the tunnel).
final class RelayHTTPTests: XCTestCase {

    func testRawRequestIsWellFormedHTTP11WithBearerAndBody() {
        let body = Data("hello".utf8)
        let raw = RelayHTTP.rawRequest(
            method: "POST", path: "/foundryx/capture", bearer: "tok123",
            extraHeaders: ["X-Capture-Id": "omi-1", "X-Capture-Seq": "7"],
            contentType: "application/octet-stream", accept: nil, body: body)
        let text = String(decoding: raw, as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("POST /foundryx/capture HTTP/1.1\r\n"), "request line")
        XCTAssertTrue(text.contains("Authorization: Bearer tok123\r\n"), "bearer header")
        XCTAssertTrue(text.contains("Content-Type: application/octet-stream\r\n"))
        XCTAssertTrue(text.contains("X-Capture-Id: omi-1\r\n"))
        XCTAssertTrue(text.contains("X-Capture-Seq: 7\r\n"))
        XCTAssertTrue(text.contains("Content-Length: 5\r\n"), "byte-accurate length")
        XCTAssertTrue(text.contains("Connection: close\r\n\r\n"), "header terminator")
        XCTAssertTrue(text.hasSuffix("hello"), "body appended after headers")
    }

    func testRawRequestWithNoBodyHasZeroContentLength() {
        let raw = RelayHTTP.rawRequest(
            method: "GET", path: "/foundryx/capture/x/status", bearer: "t",
            extraHeaders: [:], contentType: nil, accept: nil, body: nil)
        let text = String(decoding: raw, as: UTF8.self)
        XCTAssertTrue(text.contains("Content-Length: 0\r\n"))
        XCTAssertTrue(text.hasSuffix("\r\n\r\n"), "no body after terminator")
    }

    func testParseResponseExtractsStatusAndBody() throws {
        let raw = Data("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nConnection: close\r\n\r\n{\"ok\":true}".utf8)
        let resp = try RelayHTTP.parseResponse(raw)
        XCTAssertEqual(resp.status, 200)
        XCTAssertEqual(String(decoding: resp.body, as: UTF8.self), "{\"ok\":true}")
    }

    func testParseResponseHandles404WithEmptyBody() throws {
        let raw = Data("HTTP/1.1 404 Not Found\r\nConnection: close\r\n\r\n".utf8)
        let resp = try RelayHTTP.parseResponse(raw)
        XCTAssertEqual(resp.status, 404)
        XCTAssertTrue(resp.body.isEmpty)
    }

    func testParseResponseParsesSSEBodyForChat() throws {
        // The chat turn returns an SSE body the caller splits on `data:` lines.
        let raw = Data("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n\r\ndata: {\"type\":\"session\"}\n\ndata: [DONE]\n".utf8)
        let resp = try RelayHTTP.parseResponse(raw)
        XCTAssertEqual(resp.status, 200)
        XCTAssertTrue(String(decoding: resp.body, as: UTF8.self).contains("data: {\"type\":\"session\"}"))
    }

    func testParseResponseThrowsWithoutHeaderTerminator() {
        let raw = Data("HTTP/1.1 200 OK\r\nincomplete".utf8)
        XCTAssertThrowsError(try RelayHTTP.parseResponse(raw))
    }
}
