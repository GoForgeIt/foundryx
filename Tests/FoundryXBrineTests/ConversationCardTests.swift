import XCTest
import Foundation
import AudioToolbox
import FoundryXKit

/// Door-free tests for the conversation-cards Phase A (track 20260620T1532): the
/// phone records each conversation's start + end (durably), opportunistically
/// captures a location (degrading honestly when none is available), sends that
/// metadata as the finalize body, and drives the card's stage chip by polling the
/// door — stopping at a terminal stage. No live Foundry.app door is touched: the
/// finalize boundary + the status fetch are injected.
@MainActor
final class ConversationCardTests: XCTestCase {

    // MARK: shared fixtures (mirror CaptureFinalizeTests)

    final class TestSource: AudioFrameSource, @unchecked Sendable {
        var onFrame: ((Data) -> Void)?
        var onState: ((AudioSourceState) -> Void)?
        func start() {}
        func stop() {}
    }

    /// Records finalize calls WITH the metadata body, so we can assert the body shape.
    final class MetaRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _calls: [(id: String, meta: ConversationMeta?)] = []
        var calls: [(id: String, meta: ConversationMeta?)] { lock.lock(); defer { lock.unlock() }; return _calls }
        func record(_ id: String, _ meta: ConversationMeta?) { lock.lock(); _calls.append((id, meta)); lock.unlock() }
    }

    /// A location provider that returns a fixed fix (authorized path).
    struct FixedLocationProvider: ConversationLocationProviding {
        let location: ConversationLocation?
        func currentLocation() async -> ConversationLocation? { location }
    }

    private lazy var loudPacket: Data = RealOmiFrames.voiced()
    private lazy var quietPacket: Data = RealOmiFrames.silent()

    private func ackAllSegments(_ dir: URL, _ captureId: String) {
        let cdir = dir.appendingPathComponent(captureId, isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: cdir, includingPropertiesForKeys: nil)) ?? []
        for f in files where f.pathExtension == "opus" {
            try? Data().write(to: f.deletingPathExtension().appendingPathExtension("ack"), options: [.atomic])
        }
    }

    private func tempDir(_ tag: String) throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("foundryx-\(tag)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func waitUntil(timeout: TimeInterval = 3, _ cond: @MainActor () -> Bool) async throws {
        let start = Date()
        while !cond() {
            if Date().timeIntervalSince(start) > timeout { XCTFail("waitUntil timed out"); return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    /// Drive a closed conversation and return (dir, manager, closedCaptureId, recorder).
    private func runClosedConversation(
        dir: URL,
        location: ConversationLocation?,
        recorder: MetaRecorder
    ) async throws -> String {
        let src = TestSource()
        let target = DoorTarget(baseURL: URL(string: "http://127.0.0.1:1")!, bearer: "x")
        let mgr = CaptureManager(
            target: target, baseDir: dir, source: src,
            finalize: { id, meta in recorder.record(id, meta) },
            locationProvider: FixedLocationProvider(location: location)
        )
        mgr.setSilenceGap(0)
        src.onState?(.streaming)
        try await waitUntil { mgr.active != nil }
        let firstCapture = try XCTUnwrap(mgr.active).captureId
        for _ in 0..<60 { src.onFrame?(loudPacket) }
        try XCTUnwrap(mgr.active).flushAndWait()
        src.onFrame?(quietPacket)                       // silence closes the conversation
        try await waitUntil { mgr.active?.captureId != firstCapture }
        // The end-of-session Task records end+location then finalizes; wait for the
        // meta to be durable (its end stamped).
        try await waitUntil {
            mgr.conversationMeta(for: firstCapture)?.endedAt != nil
        }
        ackAllSegments(dir, firstCapture)
        await mgr.retryPendingFinalizes()
        return firstCapture
    }

    // MARK: AC1 — start + end recorded, duration derived

    func testConversationRecordsStartEndAndDuration() async throws {
        let dir = try tempDir("card-times")
        defer { try? FileManager.default.removeItem(at: dir) }
        let rec = MetaRecorder()
        let id = try await runClosedConversation(dir: dir, location: nil, recorder: rec)

        let meta = try XCTUnwrap(ConversationMetaStore.load(captureId: id, baseDir: dir),
                                 "the conversation must have a durable metadata record")
        XCTAssertGreaterThan(meta.startedAt, 0, "start time recorded")
        let end = try XCTUnwrap(meta.endedAt, "end time recorded on conversation close")
        XCTAssertGreaterThanOrEqual(end, meta.startedAt, "end is not before start")
        XCTAssertNotNil(meta.durationSeconds, "duration is derivable once closed")
    }

    // MARK: AC2 / F9 — location captured + carried in the finalize body

    func testFinalizeBodyCarriesTimesAndLocationWhenAuthorized() async throws {
        let dir = try tempDir("card-loc")
        defer { try? FileManager.default.removeItem(at: dir) }
        let rec = MetaRecorder()
        let fix = ConversationLocation(lat: 37.7762, long: -122.4231, label: "Blue Bottle")
        let id = try await runClosedConversation(dir: dir, location: fix, recorder: rec)

        let call = try XCTUnwrap(rec.calls.first { $0.id == id }, "finalize fired for the closed capture")
        let meta = try XCTUnwrap(call.meta, "finalize carries the conversation metadata body")
        XCTAssertGreaterThan(meta.startedAt, 0)
        XCTAssertNotNil(meta.endedAt)
        XCTAssertEqual(meta.location?.label, "Blue Bottle", "location label carried in the body")
        XCTAssertEqual(meta.location?.lat, 37.7762)

        // The body encodes to the door's snake_case contract.
        let data = try JSONEncoder().encode(FinalizeBody(meta: meta))
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNotNil(obj["started_at"], "body uses started_at")
        XCTAssertNotNil(obj["ended_at"], "body uses ended_at")
        let loc = try XCTUnwrap(obj["location"] as? [String: Any], "body has a location object")
        XCTAssertEqual(loc["label"] as? String, "Blue Bottle")
        XCTAssertNotNil(loc["lat"]); XCTAssertNotNil(loc["long"])
    }

    // MARK: AC6 / F5 — location degradation (no fix → no label, capture unaffected)

    func testLocationDegradesGracefullyWhenUnavailable() async throws {
        let dir = try tempDir("card-degrade")
        defer { try? FileManager.default.removeItem(at: dir) }
        let rec = MetaRecorder()
        // NoLocationProvider path (denied / backgrounded / macOS host): no fix.
        let id = try await runClosedConversation(dir: dir, location: nil, recorder: rec)

        let meta = try XCTUnwrap(ConversationMetaStore.load(captureId: id, baseDir: dir))
        XCTAssertNil(meta.location, "no location captured → no place on the card")
        // Capture itself is unaffected: it still recorded times and finalized.
        XCTAssertNotNil(meta.endedAt)
        XCTAssertTrue(rec.calls.contains { $0.id == id }, "capture still finalized without a location")

        // The finalize body simply omits the location object.
        let call = try XCTUnwrap(rec.calls.first { $0.id == id })
        let data = try JSONEncoder().encode(FinalizeBody(meta: try XCTUnwrap(call.meta)))
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(obj["location"], "no location object in the body when there's no fix")
    }

    // MARK: F11 / F10 — the poller advances the chip and stops at terminal stages

    /// A status fetcher returning a scripted sequence of stages (and counting hits).
    /// An actor so it's safe to mutate the script across the poller's async calls.
    actor ScriptedFetcher: CaptureStatusFetching {
        private var stages: [String]
        private(set) var hits = 0
        init(_ stages: [String]) { self.stages = stages }
        func captureStatus(captureId: String) async throws -> CaptureStatusResponse {
            hits += 1
            let stage = stages.first ?? stages.last ?? "stored"
            if stages.count > 1 { stages.removeFirst() }
            let lore = (stage == "in_lore" || stage == "organized") ? "lore-cap-1" : nil
            return CaptureStatusResponse(stage: stage, loreCaptureId: lore, transcribed: stage != "stored")
        }
    }

    func testPollerStopsAtOrganized() async throws {
        let fetcher = ScriptedFetcher(["transcribing", "in_lore", "organized"])
        let poller = CaptureStatusPoller(captureId: "omi-x", client: fetcher, baseInterval: 0.01, maxInterval: 0.05)

        var terminal = false
        for _ in 0..<5 {
            terminal = await poller.pollOnce()
            if terminal { break }
        }
        XCTAssertTrue(terminal, "the poller reports terminal at organized")
        XCTAssertEqual(poller.stage, .organized)
        XCTAssertEqual(poller.loreCaptureId, "lore-cap-1", "lore id surfaced once organized")
        XCTAssertTrue(poller.stage.isTerminal, "organized is terminal — polling must stop (F11)")
    }

    func testPollerSurfacesTerminalFailure() async throws {
        let fetcher = ScriptedFetcher(["transcribing", "failed"])
        let poller = CaptureStatusPoller(captureId: "omi-y", client: fetcher, baseInterval: 0.01)
        _ = await poller.pollOnce()      // transcribing
        let terminal = await poller.pollOnce()  // failed
        XCTAssertTrue(terminal, "failed is terminal")
        XCTAssertEqual(poller.stage, .failed)
        XCTAssertTrue(poller.stage.needsRetry, "a failed capture shows a retry affordance, not infinite Transcribing (F10)")
        XCTAssertEqual(poller.stage.chipLabel, "⚠️ Transcription failed — retry")
    }

    func testStageMappingFromWire() {
        XCTAssertEqual(CaptureLifecycleStage(wire: "in_lore"), .inLore)
        XCTAssertEqual(CaptureLifecycleStage(wire: "organized"), .organized)
        XCTAssertEqual(CaptureLifecycleStage(wire: "failed"), .failed)
        // Unknown stage degrades to stored, never crashes.
        XCTAssertEqual(CaptureLifecycleStage(wire: "wat"), .stored)
    }
}
