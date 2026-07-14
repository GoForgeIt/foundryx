import XCTest
import Foundation
import FoundryXKit

/// AmbientSignalShipper (track 20260710T2030 v3.3): ship the on-device gate/card
/// signal to the DESKTOP door, STRIPPED of raw conversation text. These tests are the
/// privacy proof — they assert the redaction map drops the utterance / window / seed,
/// and that the watermark only re-ships NEW lines. Hermetic: no network, a fake sender
/// captures the batch; the logs are temp JSONL files. Decisions are built as JSON (the
/// exact on-disk shape the lane writes) so the tests exercise the real decode path.
final class AmbientSignalShipperTests: XCTestCase {

    /// A raw utterance that MUST NEVER appear in any shipped record.
    private let secret = "MEET_SARAH_AT_THE_PIER_AT_NINE"

    private func tmp(_ name: String) -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("\(name)-\(UUID().uuidString)")
    }

    /// Build one `ambient-decisions.jsonl` line as the lane writes it, then decode it
    /// into the real `AmbientDecision` (no public initializer needed cross-module).
    private func decision(ts: Int, windowChars: Int, outcome: String,
                          utterance: String? = nil, summary: String? = nil,
                          confidence: Double? = nil, skipReason: String? = nil,
                          latencyMs: Int) throws -> AmbientDecision {
        var obj: [String: Any] = [
            "ts": ts, "captureId": "cap", "windowChars": windowChars,
            "outcome": outcome, "latencyMs": latencyMs,
        ]
        if let utterance, let summary, let confidence {
            obj["candidate"] = ["utterance": utterance, "summary": summary, "confidence": confidence]
        }
        if let skipReason { obj["skipReason"] = skipReason }
        let data = try JSONSerialization.data(withJSONObject: obj)
        return try JSONDecoder().decode(AmbientDecision.self, from: data)
    }

    private func decisionLine(ts: Int, windowChars: Int, outcome: String,
                              utterance: String? = nil, summary: String? = nil,
                              confidence: Double? = nil, latencyMs: Int) throws -> Data {
        var obj: [String: Any] = [
            "ts": ts, "captureId": "cap", "windowChars": windowChars,
            "outcome": outcome, "latencyMs": latencyMs,
        ]
        if let utterance, let summary, let confidence {
            obj["candidate"] = ["utterance": utterance, "summary": summary, "confidence": confidence]
        }
        return try JSONSerialization.data(withJSONObject: obj)
    }

    private func appendLine(_ data: Data, to url: URL) throws {
        var line = data; line.append(UInt8(ascii: "\n"))
        if let h = try? FileHandle(forWritingTo: url) {
            defer { try? h.close() }
            _ = try? h.seekToEnd(); try h.write(contentsOf: line)
        } else {
            try line.write(to: url)
        }
    }

    private func jsonString(_ record: AmbientSignalRecord) throws -> String {
        String(data: try JSONEncoder().encode(record), encoding: .utf8) ?? ""
    }

    // (a) The GATE redaction map: a decision carrying a raw utterance maps to a record
    //     that keeps the DERIVED summary as `action` + confidence, and CANNOT carry
    //     the utterance (no such field) — the encoded JSON never contains the secret.
    func testGateRedactionDropsUtteranceKeepsDerivedAction() throws {
        let d = try decision(ts: 1_700_000_000, windowChars: 812, outcome: "candidate",
                             utterance: secret, summary: "add a reminder to meet at 9",
                             confidence: 0.87, latencyMs: 42)

        let record = AmbientSignalShipper.redact(decision: d)

        XCTAssertEqual(record.source, "gate")
        XCTAssertEqual(record.outcome, "candidate")
        XCTAssertEqual(record.action, "add a reminder to meet at 9", "the DERIVED summary ships as action")
        XCTAssertEqual(record.confidence, 0.87)
        XCTAssertEqual(record.latencyMs, 42)
        XCTAssertEqual(record.windowChars, 812, "window SIZE ships, not content")

        let json = try jsonString(record)
        XCTAssertFalse(json.contains(secret), "the raw utterance MUST NOT ship: \(json)")
        XCTAssertFalse(json.contains("\"utterance\""), "no utterance field")
        XCTAssertFalse(json.contains("\"window\""), "no window (content) field")
        XCTAssertTrue(json.contains("add a reminder to meet at 9"))
        XCTAssertTrue(json.contains("\"window_chars\":812"), "size only")
    }

    // (b) The CARD redaction map: a card seed EMBEDS the utterance; the mapped record
    //     carries the outcome but neither the seed nor the utterance.
    func testCardRedactionDropsSeedAndEmbeddedUtterance() throws {
        let seed = "While I was recording, this came up: \(secret) — want me to help?"
        let raw = try JSONSerialization.data(withJSONObject: [
            "ts": 1_700_000_500, "outcome": "dismissed", "seed": seed,
        ])
        let card = try JSONDecoder().decode(AmbientCardLine.self, from: raw)

        let record = AmbientSignalShipper.redact(card: card)

        XCTAssertEqual(record.source, "card")
        XCTAssertEqual(record.outcome, "dismissed", "the outcome (false-positive label) ships")
        XCTAssertNil(record.action, "the seed is not separable — no action ships")

        let json = try jsonString(record)
        XCTAssertFalse(json.contains(secret), "the embedded utterance MUST NOT ship: \(json)")
        XCTAssertFalse(json.contains("\"seed\""), "no seed field")
        XCTAssertFalse(json.contains("recording"), "no seed text at all")
        XCTAssertTrue(json.contains("dismissed"))
    }

    // (c) The watermark: a second ship pass sends ONLY lines appended since the first,
    //     and a full end-to-end pass never leaks the secret over the wire.
    func testWatermarkShipsOnlyNewLines() async throws {
        let decisions = tmp("decisions.jsonl")
        let cards = tmp("cards.jsonl")
        let watermark = tmp("watermark")

        actor Wire {
            var batches: [[AmbientSignalRecord]] = []
            func record(_ b: [AmbientSignalRecord]) -> Bool { batches.append(b); return true }
            func all() -> [AmbientSignalRecord] { batches.flatMap { $0 } }
        }
        let wire = Wire()

        let shipper = AmbientSignalShipper(
            decisionsURL: decisions, cardsURL: cards, watermarkURL: watermark,
            isEnabled: { true },
            send: { records in await wire.record(records) })

        // First line: a candidate whose utterance is the secret.
        try appendLine(try decisionLine(ts: 1, windowChars: 100, outcome: "candidate",
                                        utterance: secret, summary: "look it up",
                                        confidence: 0.9, latencyMs: 10), to: decisions)

        try await shipper.shipPending()
        var batches = await wire.batches
        XCTAssertEqual(batches.count, 1)
        XCTAssertEqual(batches[0].count, 1, "first pass ships the one decision")

        // A second pass with NOTHING new must not re-ship.
        try await shipper.shipPending()
        batches = await wire.batches
        XCTAssertEqual(batches.count, 1, "no new lines → no new batch (watermark held)")

        // Append a NEW gated_no line + a card outcome, ship again.
        try appendLine(try decisionLine(ts: 2, windowChars: 40, outcome: "gated_no",
                                        latencyMs: 5), to: decisions)
        try appendLine(try JSONSerialization.data(withJSONObject: [
            "ts": 3, "outcome": "run", "seed": "this came up: \(secret)",
        ]), to: cards)

        try await shipper.shipPending()
        batches = await wire.batches
        XCTAssertEqual(batches.count, 2, "a second batch ships only the NEW lines")
        XCTAssertEqual(batches[1].count, 2, "the new decision + the new card")

        // NOTHING that ever crossed the wire contains the raw utterance.
        let all = await wire.all()
        let wireJSON = String(data: try JSONEncoder().encode(all), encoding: .utf8) ?? ""
        XCTAssertFalse(wireJSON.contains(secret),
                       "no raw conversation text EVER left the device: \(wireJSON)")
        XCTAssertFalse(wireJSON.contains("\"utterance\""))
        XCTAssertFalse(wireJSON.contains("\"seed\""))
        XCTAssertFalse(wireJSON.contains("\"window\""))
    }

    // A 404 (old door → sender returns false) must NOT advance the watermark: the same
    // line re-ships once the desktop endpoint exists.
    func testOldDoor404HoldsWatermarkForRetry() async throws {
        let decisions = tmp("decisions.jsonl")
        let cards = tmp("cards.jsonl")
        let watermark = tmp("watermark")

        actor Counter {
            var passes = 0; var accept = false
            func hit() -> Bool { passes += 1; return accept }
            func flip() { accept = true }
            func count() -> Int { passes }
        }
        let counter = Counter()

        let shipper = AmbientSignalShipper(
            decisionsURL: decisions, cardsURL: cards, watermarkURL: watermark,
            isEnabled: { true },
            send: { _ in await counter.hit() })

        try appendLine(try decisionLine(ts: 1, windowChars: 10, outcome: "gated_no",
                                        latencyMs: 1), to: decisions)

        try await shipper.shipPending()   // 404 → not accepted → watermark held
        try await shipper.shipPending()   // retried (line still pending)
        var passes = await counter.count()
        XCTAssertEqual(passes, 2, "a rejected (old-door) ship retries the same line")

        await counter.flip()               // door now has the endpoint
        try await shipper.shipPending()    // accepted → watermark advances
        try await shipper.shipPending()    // nothing new → no send
        passes = await counter.count()
        XCTAssertEqual(passes, 3, "after acceptance the line is not re-shipped")
    }
}
