import XCTest
import Foundation
@testable import FoundryXKit

/// Speaker-diarized transcript (Lore 0.5.53): the wire decode, the segment→turn
/// grouping, the inferred/confirmed/anonymous rendering inputs, and the door confirm
/// call. Pure-model + a URLProtocol-stubbed DoorClient — no live door.
final class SpeakerTranscriptTests: XCTestCase {

    // MARK: - copy: whole transcript as paste-ready plain text

    func testPlainTextLabelsEachTurnBySpeakerInSpokenOrder() {
        let t = SpeakerTranscript(
            speakers: [
                CaptureSpeaker(slot: "speaker_0", status: .confirmed, name: "Alice"),
                CaptureSpeaker(slot: "speaker_1", status: .anonymous),
            ],
            segments: [
                TranscriptSegment(seq: 0, text: "Hey, did it work?", speaker: "speaker_0"),
                TranscriptSegment(seq: 1, text: "Yeah, all green.", speaker: "speaker_1"),
                TranscriptSegment(seq: 2, text: "Nice.", speaker: "speaker_0"),
            ])
        // Confirmed name for slot 0; "Speaker 2" for the anonymous slot 1; spoken order.
        XCTAssertEqual(
            t.plainText,
            "Alice: Hey, did it work?\n\nSpeaker 2: Yeah, all green.\n\nAlice: Nice.")
    }

    func testPlainTextSkipsEmptyTurns() {
        let t = SpeakerTranscript(
            speakers: [],
            segments: [
                TranscriptSegment(seq: 0, text: "  ", speaker: "speaker_0"),
                TranscriptSegment(seq: 1, text: "real words", speaker: "speaker_1"),
            ])
        XCTAssertEqual(t.plainText, "Speaker 2: real words")
    }

    // MARK: - segment → speaker turn grouping

    func testConsecutiveSameSpeakerFoldIntoOneTurn() {
        let segs = [
            TranscriptSegment(seq: 0, text: "hi", speaker: "speaker_0"),
            TranscriptSegment(seq: 1, text: "how are you", speaker: "speaker_0"),
            TranscriptSegment(seq: 2, text: "good thanks", speaker: "speaker_1"),
            TranscriptSegment(seq: 3, text: "and you", speaker: "speaker_1"),
            TranscriptSegment(seq: 4, text: "great", speaker: "speaker_0"),
        ]
        let turns = SpeakerTurn.group(segs)
        XCTAssertEqual(turns.count, 3, "two speaker changes → three turns")
        XCTAssertEqual(turns[0].slot, "speaker_0")
        XCTAssertEqual(turns[0].text, "hi how are you")
        XCTAssertEqual(turns[1].slot, "speaker_1")
        XCTAssertEqual(turns[1].text, "good thanks and you")
        XCTAssertEqual(turns[2].slot, "speaker_0")
        XCTAssertEqual(turns[2].text, "great")
    }

    func testGroupingSortsOutOfOrderSegmentsBySeq() {
        let segs = [
            TranscriptSegment(seq: 2, text: "c", speaker: "speaker_1"),
            TranscriptSegment(seq: 0, text: "a", speaker: "speaker_0"),
            TranscriptSegment(seq: 1, text: "b", speaker: "speaker_0"),
        ]
        let turns = SpeakerTurn.group(segs)
        XCTAssertEqual(turns.map(\.text), ["a b", "c"])
    }

    func testEmptySegmentsYieldNoTurns() {
        XCTAssertTrue(SpeakerTurn.group([]).isEmpty)
    }

    // MARK: - identity state rendering inputs

    func testConfirmedSpeakerShowsName() {
        let t = SpeakerTranscript(
            speakers: [CaptureSpeaker(slot: "speaker_0", status: .confirmed, name: "Alice")],
            segments: [TranscriptSegment(seq: 0, text: "hi", speaker: "speaker_0")])
        XCTAssertEqual(t.displayLabel(for: "speaker_0"), "Alice")
        XCTAssertTrue(t.speaker(for: "speaker_0").isConfirmed)
        XCTAssertFalse(t.hasUnconfirmedInferred)
    }

    func testInferredSpeakerIsTentativeAndOffersConfirm() {
        let t = SpeakerTranscript(
            speakers: [CaptureSpeaker(slot: "speaker_1", status: .inferred,
                                      name: "Bob", inferScore: 0.82,
                                      inferredSpeakerId: "spk_bob")],
            segments: [TranscriptSegment(seq: 0, text: "hey", speaker: "speaker_1")])
        let sp = t.speaker(for: "speaker_1")
        XCTAssertTrue(sp.isInferred, "inferred match renders tentative, not solid")
        XCTAssertEqual(sp.name, "Bob", "the tentative name is offered for confirm")
        XCTAssertEqual(sp.inferScore ?? 0, 0.82, accuracy: 0.0001)
        XCTAssertEqual(t.displayLabel(for: "speaker_1"), "Bob")
        XCTAssertEqual(t.inferredSlots, ["speaker_1"])
        XCTAssertTrue(t.hasUnconfirmedInferred, "drives the review-speakers affordance")
    }

    func testAnonymousSpeakerIsNumberedAndNameable() {
        let t = SpeakerTranscript(
            speakers: [CaptureSpeaker(slot: "speaker_0", status: .anonymous)],
            segments: [
                TranscriptSegment(seq: 0, text: "one", speaker: "speaker_0"),
                TranscriptSegment(seq: 1, text: "two", speaker: "speaker_2"),
            ])
        XCTAssertEqual(t.displayLabel(for: "speaker_0"), "Speaker 1")
        // A slot with a segment but no speakers-list entry is synthesised as anonymous.
        XCTAssertTrue(t.speaker(for: "speaker_2").isAnonymous)
        XCTAssertEqual(t.displayLabel(for: "speaker_2"), "Speaker 2")
    }

    func testStableNumberAndColorIndexFollowFirstAppearance() {
        let t = SpeakerTranscript(
            speakers: [],
            segments: [
                TranscriptSegment(seq: 0, text: "a", speaker: "speaker_5"),
                TranscriptSegment(seq: 1, text: "b", speaker: "speaker_2"),
                TranscriptSegment(seq: 2, text: "c", speaker: "speaker_5"),
            ])
        XCTAssertEqual(t.displayNumber(for: "speaker_5"), 1)
        XCTAssertEqual(t.displayNumber(for: "speaker_2"), 2)
        XCTAssertEqual(t.colorIndex(for: "speaker_5"), 0)
        XCTAssertEqual(t.colorIndex(for: "speaker_2"), 1)
    }

    // MARK: - CaptureContent wire decode

    func testCaptureContentDecodesSegmentsAndSpeakers() throws {
        let json = Data(#"""
        {"transcript":"hi good","capturedAt":222,"found":true,
         "segments":[
            {"seq":0,"startMs":0,"endMs":1500,"text":"hi","speaker":"speaker_0"},
            {"seq":1,"startMs":1500,"endMs":3000,"text":"good","speaker":"speaker_1"}],
         "speakers":[
            {"slot":"speaker_0","status":"confirmed","inferred":false,"confirmed":true,
             "name":"Alice","inferScore":null,"confirmedSpeakerId":"spk_a"},
            {"slot":"speaker_1","status":"inferred","inferred":true,"confirmed":false,
             "name":"Bob","inferScore":0.77,"inferredSpeakerId":"spk_b"}]}
        """#.utf8)
        let c = try JSONDecoder().decode(CaptureContent.self, from: json)
        XCTAssertEqual(c.segments.count, 2)
        XCTAssertEqual(c.segments[0].speaker, "speaker_0")
        XCTAssertEqual(c.segments[1].endMs, 3000)
        XCTAssertEqual(c.speakers.count, 2)
        XCTAssertEqual(c.diarized.turns.count, 2)
        XCTAssertTrue(c.diarized.hasSegments)
        XCTAssertEqual(c.diarized.displayLabel(for: "speaker_0"), "Alice")
        XCTAssertTrue(c.diarized.speaker(for: "speaker_1").isInferred)
    }

    func testLegacyContentWithoutDiarizationDecodesEmpty() throws {
        // A pre-door-change / non-diarized reply has no segments/speakers → flat path.
        let json = Data(#"{"transcript":"hello","capturedAt":1,"found":true}"#.utf8)
        let c = try JSONDecoder().decode(CaptureContent.self, from: json)
        XCTAssertTrue(c.segments.isEmpty)
        XCTAssertTrue(c.speakers.isEmpty)
        XCTAssertFalse(c.diarized.hasSegments)
    }

    // MARK: - door confirm endpoint (URLProtocol-stubbed DoorClient)

    func testConfirmSpeakerCallsRightEndpointAndDecodesOffer() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.handler = { request in
            // The right method + path reaches the door.
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path,
                           "/foundryx/capture/cap123/speakers/speaker_1/confirm")
            // The body carries the chosen speaker (assign-to-existing path).
            let body = request.bodyData ?? Data()
            let obj = (try? JSONSerialization.jsonObject(with: body)) as? [String: String]
            XCTAssertEqual(obj?["speakerId"], "spk_bob")
            let reply = Data(#"""
            {"captureId":"cap123","slotLabel":"speaker_1","status":"confirmed",
             "speakerId":"spk_bob","speakerName":"Bob",
             "offeredCaptures":[
                {"captureId":"capOld","slotLabel":"speaker_0","score":0.91}]}
            """#.utf8)
            return (200, reply)
        }

        let client = DoorClient(target: stubTarget(), session: stubSession())
        let outcome = try await client.confirmSpeaker(
            captureId: "cap123", slot: "speaker_1", speakerId: "spk_bob")

        XCTAssertEqual(outcome.status, "confirmed")
        XCTAssertEqual(outcome.speakerName, "Bob")
        XCTAssertEqual(outcome.offeredCaptures.count, 1,
                       "the apply-to-N-past-conversations offer is surfaced")
        XCTAssertEqual(outcome.offeredCaptures.first?.captureId, "capOld")
        XCTAssertEqual(outcome.offeredCaptures.first?.score ?? 0, 0.91, accuracy: 0.001)
    }

    func testConfirmSpeakerByNameSendsNameForCreateOrRename() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.handler = { request in
            let body = request.bodyData ?? Data()
            let obj = (try? JSONSerialization.jsonObject(with: body)) as? [String: String]
            XCTAssertEqual(obj?["name"], "Carol", "rename/new-speaker sends the name")
            XCTAssertNil(obj?["speakerId"])
            let reply = Data(#"""
            {"captureId":"cap9","slotLabel":"speaker_0","status":"confirmed",
             "speakerId":"spk_new","speakerName":"Carol","offeredCaptures":[]}
            """#.utf8)
            return (200, reply)
        }
        let client = DoorClient(target: stubTarget(), session: stubSession())
        let outcome = try await client.confirmSpeaker(
            captureId: "cap9", slot: "speaker_0", name: "Carol")
        XCTAssertEqual(outcome.speakerName, "Carol")
        XCTAssertTrue(outcome.offeredCaptures.isEmpty)
    }

    func testConfirmSpeakerSurfacesUnauthorized() async {
        StubURLProtocol.reset()
        StubURLProtocol.handler = { _ in (401, Data()) }
        let client = DoorClient(target: stubTarget(), session: stubSession())
        do {
            _ = try await client.confirmSpeaker(captureId: "c", slot: "speaker_0")
            XCTFail("expected unauthorized")
        } catch let e as DoorError {
            XCTAssertEqual(e, .unauthorized)
        } catch {
            XCTFail("expected DoorError.unauthorized, got \(error)")
        }
    }

    // MARK: - helpers

    private func stubTarget() -> DoorTarget {
        DoorTarget(baseURL: URL(string: "http://door.test")!, bearer: "tok")
    }

    private func stubSession() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: cfg)
    }
}

/// A minimal URLProtocol stub: the test sets a handler that maps a request to a
/// (status, body) reply, so the DoorClient's direct (non-relay) path can be exercised
/// without a live door.
final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, Data))?

    static func reset() { handler = nil }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = StubURLProtocol.handler else {
            client?.urlProtocol(self, didFailWithError:
                NSError(domain: "StubURLProtocol", code: -1))
            return
        }
        let (status, body) = handler(request)
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private extension URLRequest {
    /// URLProtocol strips `httpBody` for some transports but keeps `httpBodyStream`;
    /// read whichever is present so the stub can assert on the request body.
    var bodyData: Data? {
        if let b = httpBody { return b }
        guard let stream = httpBodyStream else { return nil }
        stream.open(); defer { stream.close() }
        var data = Data()
        let bufSize = 4096
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
        defer { buf.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buf, maxLength: bufSize)
            if read <= 0 { break }
            data.append(buf, count: read)
        }
        return data
    }
}
