import XCTest
import Foundation
import Combine
import AVFoundation
@testable import FoundryXKit

/// GREEN acceptance for the track `20260722T1244_live_capture_model_stops_library_rerenders`.
///
/// The sibling track made ONE conversation-list rebuild cheap (~380ms → ~2ms). What was
/// left was the FREQUENCY multiplier: `liveTranscript` / `liveTitle` / `recordingCandidates`
/// were `@Published` on the shared `CaptureManager`, written on every transcriber snapshot —
/// several times a second while recording. Every one of those ticks invalidated everything
/// that observes the manager, the conversation LIST included.
///
/// These tests pin the property that removes the multiplier: a live tick invalidates the
/// LIVE surface and nothing else. The instrument is deterministic — the manager's rebuild
/// counter and its `objectWillChange` emissions — never a wall-clock timing assertion.
///
/// Isolation is NON-NEGOTIABLE: every test uses a FRESH tempDir — the real `~/.foundry` /
/// `~/.lore` are never touched.
@MainActor
final class LiveCaptureModelIsolationTests: SignedOutListeningCaptureTestCase {

    /// How many live ticks a test drives — comfortably more than a minute of real recording
    /// at the transcriber's several-per-second cadence.
    private static let liveTicks = 60

    private final class TestSource: AudioFrameSource, @unchecked Sendable {
        var onFrame: ((Data) -> Void)?
        var onState: ((AudioSourceState) -> Void)?
        func start() {}
        func stop() {}
    }

    /// A controllable live transcriber the test drives directly (mirrors the one
    /// `LiveTranscriptionTests` uses) so the PUMP path is exercised for real.
    private final class FakeLiveTranscriber: LiveTranscribing, @unchecked Sendable {
        let transcript: AsyncStream<LiveTranscript>
        private let cont: AsyncStream<LiveTranscript>.Continuation
        init() {
            var c: AsyncStream<LiveTranscript>.Continuation!
            transcript = AsyncStream { c = $0 }
            cont = c
        }
        func start() async throws {}
        func append(_ pcm: AVAudioPCMBuffer) {}
        func finish() async -> String { cont.finish(); return "" }
        func emit(_ t: LiveTranscript) { cont.yield(t) }
    }

    private final class FakeFactory: @unchecked Sendable {
        private let lock = NSLock()
        private var made: [FakeLiveTranscriber] = []
        func make() -> LiveTranscribing? {
            let f = FakeLiveTranscriber(); lock.lock(); made.append(f); lock.unlock(); return f
        }
        var last: FakeLiveTranscriber? { lock.lock(); defer { lock.unlock() }; return made.last }
    }

    private func tempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("foundryx-livemodel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeManager(dir: URL, source: AudioFrameSource,
                             factory: FakeFactory? = nil) async -> CaptureManager {
        let target = DoorTarget(baseURL: URL(string: "http://127.0.0.1:1")!, bearer: "x")
        var make: LiveTranscriberFactory?
        if let factory { make = { factory.make() } }
        let m = CaptureManager(target: target, baseDir: dir, source: source,
                               finalize: { _, _ in }, deleteCapture: { _ in },
                               fetchContent: { _ in nil },
                               liveTranscriber: make)
        await m.hydration?.value
        return m
    }

    /// One live-tick snapshot: FINALIZED text (empty volatile tail) so the rolling-title
    /// path runs too — a title publish is exactly as hot as a transcript publish.
    private func snapshot(_ i: Int) -> LiveTranscript {
        let text = "okay so the kitchen renovation budget is our topic today for planning "
            + (0...i).map { n in "and the cabinets question number \(n) is still open" }
                     .joined(separator: " ")
        return LiveTranscript(finalizedText: text, volatileTail: "", isComplete: false,
                              titleContext: text)
    }

    // MARK: the acceptance instrument

    /// N live-transcript/live-title publishes cause ZERO conversation-list rebuilds and
    /// ZERO manager invalidations — while the LIVE model publishes every single one.
    ///
    /// The manager is quiet here on purpose (no source streaming, no timers): the only
    /// thing moving is the live text, so a non-zero count can only be the live text.
    func testLivePublishesCauseZeroConversationListRebuilds() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let mgr = await makeManager(dir: dir, source: TestSource())

        var managerInvalidations = 0
        var liveInvalidations = 0
        var bag = Set<AnyCancellable>()
        mgr.objectWillChange.sink { _ in managerInvalidations += 1 }.store(in: &bag)
        mgr.live.objectWillChange.sink { _ in liveInvalidations += 1 }.store(in: &bag)
        let rebuildsBefore = mgr.rebuildCountForTests

        for i in 0..<Self.liveTicks { mgr.publishLiveSnapshotForTests(snapshot(i)) }

        XCTAssertEqual(mgr.rebuildCountForTests - rebuildsBefore, 0,
                       "\(Self.liveTicks) live ticks must rebuild the conversation list ZERO times")
        XCTAssertEqual(managerInvalidations, 0,
                       "live ticks must not invalidate the manager — that is what re-rendered the list")
        XCTAssertGreaterThanOrEqual(liveInvalidations, Self.liveTicks,
                                    "the live surface must still be invalidated on every tick (liveness)")
        // R4 / liveness: the manager still READS the live state, unchanged.
        XCTAssertTrue(mgr.liveTranscript.displayText.contains("number \(Self.liveTicks - 1) "),
                      "the manager must still read the latest live transcript")
        XCTAssertNotNil(mgr.liveTitle, "the rolling title must still settle from the live ticks")
    }

    /// The same property through the REAL transcriber pump during a REAL recording session
    /// (the production path: `startLiveTranscription` → `for await snap` → publish).
    func testTranscriberPumpDoesNotRebuildTheListDuringRecording() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let src = TestSource(); let factory = FakeFactory()
        let mgr = await makeManager(dir: dir, source: src, factory: factory)

        src.onState?(.streaming)
        try await waitUntil { mgr.isListeningForSpeechForTests }
        RealOmiFrames.openSession(src.onFrame)   // speech onset opens the conversation
        try await waitUntil { mgr.active != nil && factory.last != nil }
        let fake = try XCTUnwrap(factory.last)

        // Baseline once the session's OWN rebuilds have settled: opening a conversation
        // legitimately rebuilds the list (and the off-main sidecar warm rebuilds once more
        // when its values land). Those are library events; this test is about live ticks.
        let rebuildsBefore = try await settledRebuildCount(mgr)
        for i in 0..<Self.liveTicks {
            fake.emit(snapshot(i))
        }
        try await waitUntil { mgr.liveTranscript.displayText.contains("number \(Self.liveTicks - 1) ") }

        XCTAssertEqual(mgr.rebuildCountForTests - rebuildsBefore, 0,
                       "pumped live snapshots must rebuild the conversation list ZERO times")
    }

    /// The candidate rows are the third hot live field: surfacing one is a LIVE-surface
    /// event, not a library event.
    func testRecordingCandidatesPublishOnlyOnTheLiveModel() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let src = TestSource()
        let mgr = await makeManager(dir: dir, source: src)

        src.onState?(.streaming)
        try await waitUntil { mgr.isListeningForSpeechForTests }
        RealOmiFrames.openSession(src.onFrame)
        try await waitUntil { mgr.active != nil }
        let activeId = try XCTUnwrap(mgr.active?.captureId)

        var managerInvalidations = 0
        var bag = Set<AnyCancellable>()
        mgr.objectWillChange.sink { _ in managerInvalidations += 1 }.store(in: &bag)
        let rebuildsBefore = mgr.rebuildCountForTests

        mgr.noteRecordingCandidate(
            AmbientCandidate(utterance: "remind me to send Sarah the deck",
                             summary: "Send Sarah the deck", confidence: 0.9),
            forCapture: activeId)

        XCTAssertEqual(mgr.recordingCandidates.count, 1, "the candidate still reaches the live surface")
        XCTAssertEqual(mgr.rebuildCountForTests - rebuildsBefore, 0,
                       "a surfaced candidate must not rebuild the conversation list")
        XCTAssertEqual(managerInvalidations, 0,
                       "a surfaced candidate must invalidate only the live surface")
    }

    /// The rebuild count once it has stopped moving on its own — so a live-tick assertion
    /// can never be charged for a library event (session open, off-main sidecar warm).
    private func settledRebuildCount(_ mgr: CaptureManager) async throws -> Int {
        var last = mgr.rebuildCountForTests
        var stable = 0
        while stable < 4 {
            try await Task.sleep(nanoseconds: 50_000_000)
            let now = mgr.rebuildCountForTests
            stable = (now == last) ? stable + 1 : 0
            last = now
        }
        return last
    }

    private func waitUntil(timeout: TimeInterval = 3, _ cond: @MainActor () -> Bool) async throws {
        let start = Date()
        while !cond() {
            if Date().timeIntervalSince(start) > timeout { XCTFail("waitUntil timed out"); return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}
