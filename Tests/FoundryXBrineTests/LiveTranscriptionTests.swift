import XCTest
import Foundation
import AVFoundation
import FoundryXKit

/// Door-free tests for the LIVE on-device transcription preview (Feature 1). The live
/// transcriber is INJECTED via the factory seam, so we exercise the wiring — per-session
/// lifecycle, the decoded-PCM tap, the volatile→final progressive-refinement stream
/// republished into `liveTranscript`, and teardown — WITHOUT needing SpeechAnalyzer or a
/// device. This proves the preview is additive (capture is unaffected) and ephemeral.
@MainActor
final class LiveTranscriptionTests: XCTestCase {

    final class TestSource: AudioFrameSource, @unchecked Sendable {
        var onFrame: ((Data) -> Void)?
        var onState: ((AudioSourceState) -> Void)?
        func start() {}
        func stop() {}
    }

    /// A controllable live transcriber the test drives directly: it records start/append/
    /// finish and lets the test push volatile + finalized snapshots into the stream.
    final class FakeLiveTranscriber: LiveTranscribing, @unchecked Sendable {
        let transcript: AsyncStream<LiveTranscript>
        private let cont: AsyncStream<LiveTranscript>.Continuation
        private let lock = NSLock()
        private var _started = false, _finished = false, _appended = 0
        var started: Bool { lock.lock(); defer { lock.unlock() }; return _started }
        var finished: Bool { lock.lock(); defer { lock.unlock() }; return _finished }
        var appended: Int { lock.lock(); defer { lock.unlock() }; return _appended }

        init() {
            var c: AsyncStream<LiveTranscript>.Continuation!
            transcript = AsyncStream { c = $0 }
            cont = c
        }
        private func mark(started: Bool? = nil, finished: Bool? = nil) {
            lock.lock(); if let started { _started = started }; if let finished { _finished = finished }; lock.unlock()
        }
        func start() async throws { mark(started: true) }
        func append(_ pcm: AVAudioPCMBuffer) { lock.lock(); _appended += 1; lock.unlock() }
        func finish() async -> String { mark(finished: true); cont.finish(); return "" }
        func emit(_ t: LiveTranscript) { cont.yield(t) }
    }

    /// Hands out a fresh fake per conversation + remembers them (so a manual split makes
    /// a brand-new transcriber).
    final class FakeFactory: @unchecked Sendable {
        private let lock = NSLock()
        private var made: [FakeLiveTranscriber] = []
        func make() -> LiveTranscribing? { let f = FakeLiveTranscriber(); lock.lock(); made.append(f); lock.unlock(); return f }
        var last: FakeLiveTranscriber? { lock.lock(); defer { lock.unlock() }; return made.last }
        var count: Int { lock.lock(); defer { lock.unlock() }; return made.count }
    }

    private func tempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("foundryx-live-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func manager(_ dir: URL, _ src: TestSource, _ factory: FakeFactory) -> CaptureManager {
        let target = DoorTarget(baseURL: URL(string: "http://127.0.0.1:1")!, bearer: "x")
        return CaptureManager(target: target, baseDir: dir, source: src,
                              finalize: { _, _ in },
                              liveTranscriber: { factory.make() })
    }

    /// The live preview streams partial (volatile) words that snap to finalized text,
    /// republished into `liveTranscript` while the conversation is open.
    func testLivePreviewStreamsVolatileThenFinal() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let src = TestSource(); let factory = FakeFactory()
        let mgr = manager(dir, src, factory)

        src.onState?(.streaming)
        try await waitUntil { mgr.active != nil && factory.last != nil }
        let fake = try XCTUnwrap(factory.last)
        try await waitUntil { fake.started }

        // Volatile (tentative) result renders as the settling tail.
        fake.emit(LiveTranscript(finalizedText: "", volatileTail: "kiln"))
        try await waitUntil { mgr.liveTranscript.volatileTail == "kiln" }

        // It then snaps to a finalized, corrected line (the "guess then fix" refinement).
        fake.emit(LiveTranscript(finalizedText: "Kiln", volatileTail: ""))
        try await waitUntil { mgr.liveTranscript.finalizedText == "Kiln" && mgr.liveTranscript.volatileTail.isEmpty }
    }

    /// The decoded-PCM tap actually feeds the transcriber — real Opus packets decode and
    /// arrive as `append` calls — proving the audio source is tapped for live STT.
    func testDecodedPcmIsFedToTheTranscriber() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let src = TestSource(); let factory = FakeFactory()
        let mgr = manager(dir, src, factory)

        src.onState?(.streaming)
        try await waitUntil { mgr.active != nil && factory.last != nil }
        let fake = try XCTUnwrap(factory.last)

        for _ in 0..<40 { src.onFrame?(RealOmiFrames.voiced()) }
        try await waitUntil { fake.appended > 0 }
        XCTAssertGreaterThan(fake.appended, 0, "decoded PCM frames must reach the live transcriber")
    }

    /// The preview is EPHEMERAL: closing the conversation finishes the transcriber and
    /// clears `liveTranscript` (the authoritative transcript still comes from Kiln).
    func testPreviewClearsAndFinishesOnConversationEnd() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let src = TestSource(); let factory = FakeFactory()
        let mgr = manager(dir, src, factory)

        src.onState?(.streaming)
        try await waitUntil { mgr.active != nil && factory.last != nil }
        let fake = try XCTUnwrap(factory.last)
        fake.emit(LiveTranscript(finalizedText: "hello", volatileTail: "wor"))
        try await waitUntil { !mgr.liveTranscript.isEmpty }

        // Disconnect holds the session for the reconnect grace; once it elapses the
        // session ends → preview cleared + transcriber finished.
        src.onState?(.stopped)
        try await waitUntil { mgr.isAwaitingReconnect }
        mgr.resolveReconnectGrace(now: Date().timeIntervalSince1970 + CaptureManager.reconnectGraceWindow + 1)
        try await waitUntil { mgr.active == nil }
        try await waitUntil { fake.finished }
        XCTAssertTrue(mgr.liveTranscript.isEmpty, "live preview must clear when the conversation closes")
    }

    /// Live transcription is OPTIONAL: with no factory wired (older OS / disabled),
    /// capture runs exactly as before and the preview stays empty.
    func testNoFactoryMeansNoPreviewButCaptureWorks() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let src = TestSource()
        let target = DoorTarget(baseURL: URL(string: "http://127.0.0.1:1")!, bearer: "x")
        let mgr = CaptureManager(target: target, baseDir: dir, source: src, finalize: { _, _ in })

        src.onState?(.streaming)
        try await waitUntil { mgr.active != nil }
        for _ in 0..<40 { src.onFrame?(RealOmiFrames.voiced()) }
        try XCTUnwrap(mgr.active).flushAndWait()
        XCTAssertGreaterThan(try XCTUnwrap(mgr.active).snapshot().totalSegments, 0, "capture still WALs frames")
        XCTAssertTrue(mgr.liveTranscript.isEmpty, "no live preview without a factory")
    }

    private func waitUntil(timeout: TimeInterval = 3, _ cond: @MainActor () -> Bool) async throws {
        let start = Date()
        while !cond() {
            if Date().timeIntervalSince(start) > timeout { XCTFail("waitUntil timed out"); return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}
