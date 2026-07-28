import XCTest
import Foundation
import AVFoundation
@testable import FoundryXKit

/// Door-free tests for the LIVE on-device transcription preview (Feature 1). The live
/// transcriber is INJECTED via the factory seam, so we exercise the wiring — per-session
/// lifecycle, the decoded-PCM tap, the volatile→final progressive-refinement stream
/// republished into `liveTranscript`, and teardown — WITHOUT needing SpeechAnalyzer or a
/// device. This proves the preview is additive (capture is unaffected) and ephemeral.
@MainActor
final class LiveTranscriptionTests: SignedOutListeningCaptureTestCase {

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
        private var emissionOnNextAppend: LiveTranscript?
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
        func append(_ pcm: AVAudioPCMBuffer) {
            lock.lock()
            _appended += 1
            let emission = emissionOnNextAppend
            emissionOnNextAppend = nil
            lock.unlock()
            if let emission { cont.yield(emission) }
        }
        func finish() async -> String { mark(finished: true); cont.finish(); return "" }
        func emit(_ t: LiveTranscript) { cont.yield(t) }
        func emitOnNextAppend(_ t: LiveTranscript) {
            lock.lock()
            emissionOnNextAppend = t
            lock.unlock()
        }
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
        let mgr = CaptureManager(target: target, baseDir: dir, source: src,
                                 finalize: { _, _ in },
                                 liveTranscriber: { factory.make() })
        installListeningPreferences(on: mgr, root: dir)
        return mgr
    }

    private func installListeningPreferences(on manager: CaptureManager, root: URL) {
        guard let binding = CaptureAccountScope.binding(forExplicitRoot: root) else {
            XCTFail("live transcription fixture has no account binding")
            return
        }
        XCTAssertTrue(
            manager.installCapturePreferenceSnapshot(
                CaptureSettings.snapshot(binding: binding)),
            "live transcription fixture installs its explicit listening preferences")
    }

    private func pcmBuffer() throws -> AVAudioPCMBuffer {
        let format = try XCTUnwrap(
            AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: 48_000,
                channels: 1,
                interleaved: true))
        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(OpusEncoder48k.frameSamples)))
        buffer.frameLength = buffer.frameCapacity
        return buffer
    }

    /// The live preview streams partial (volatile) words that snap to finalized text,
    /// republished into `liveTranscript` while the conversation is open.
    func testLivePreviewStreamsVolatileThenFinal() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let src = TestSource(); let factory = FakeFactory()
        let target = DoorTarget(
            baseURL: URL(string: "http://127.0.0.1:1")!,
            bearer: "x")
        let mgr = CaptureManager(
            target: target,
            baseDir: dir,
            source: src,
            micSource: src,
            finalize: { _, _ in },
            liveTranscriber: { factory.make() })
        installListeningPreferences(on: mgr, root: dir)
        #if os(iOS)
        mgr.micPermissionOverrideForTests = true
        #endif

        mgr.startMicRecording()
        src.onState?(.streaming)
        try await waitUntil { mgr.active != nil && factory.last != nil }
        let captureId = try XCTUnwrap(mgr.active?.captureId)
        let fake = try XCTUnwrap(factory.last)
        try await waitUntil { fake.started }

        // Volatile (tentative) result renders as the settling tail.
        fake.emit(LiveTranscript(finalizedText: "", volatileTail: "kiln"))
        try await waitUntil { mgr.liveTranscript.volatileTail == "kiln" }

        // It then snaps to a finalized, corrected line (the "guess then fix" refinement).
        fake.emit(LiveTranscript(
            finalizedText: "the kitchen renovation budget is ready",
            volatileTail: "for review",
            titleContext: "the kitchen renovation budget is ready for review"))
        try await waitUntil { !mgr.liveTranscript.isEmpty }

        // Returning from another app re-attaches the producer without painting an empty
        // frame over the captured words. A replacement transcriber contributes only
        // post-foreground speech, so its text must append under the same capture id.
        let before = mgr.liveTranscript.displayText

        mgr.restoreLiveTranscriptionAfterForeground()

        XCTAssertEqual(mgr.liveTranscript.displayText, before,
                       "foreground restoration must never paint a blank transcript")
        try await waitUntil { factory.count == 2 }
        let replacement = try XCTUnwrap(factory.last)
        replacement.emit(LiveTranscript(
            finalizedText: "and the contractor can start Monday",
            volatileTail: "",
            titleContext: "and the contractor can start Monday"))
        try await waitUntil {
            mgr.liveTranscript.displayText.contains("contractor can start Monday")
        }

        XCTAssertTrue(mgr.liveTranscript.displayText.hasPrefix(before),
                      "the replacement appends to the captured words instead of restarting")
        XCTAssertGreaterThan(mgr.liveTranscript.displayText.count, before.count)
        XCTAssertEqual(mgr.active?.captureId, captureId,
                       "foreground restoration keeps the same conversation")
    }

    /// Foreground replacement is not only a retained display snapshot: real decoded
    /// Omi PCM must reach the replacement, whose output grows that same live binding.
    func testForegroundReplacementReceivesPcmAndGrowsRetainedTranscript() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let src = TestSource()
        let factory = FakeFactory()
        let target = DoorTarget(
            baseURL: URL(string: "http://127.0.0.1:1")!,
            bearer: "x")
        let mgr = CaptureManager(
            target: target,
            baseDir: dir,
            source: src,
            micSource: src,
            finalize: { _, _ in },
            liveTranscriber: { factory.make() })
        installListeningPreferences(on: mgr, root: dir)
        #if os(iOS)
        // Hostless iOS XCTest cannot acquire a TCC microphone identity. This still
        // exercises the explicit phone-mic session with its injected audio source.
        mgr.micPermissionOverrideForTests = true
        #endif
        mgr.startMicRecording()
        src.onState?(.streaming)
        try await waitUntil { mgr.active != nil && factory.last != nil }

        let original = try XCTUnwrap(factory.last)
        try await waitUntil { original.started }
        original.emit(LiveTranscript(
            finalizedText: "words retained before leaving",
            titleContext: "words retained before leaving"))
        try await waitUntil {
            mgr.liveTranscript.displayText == "words retained before leaving"
        }
        let before = mgr.liveTranscript.displayText

        mgr.restoreLiveTranscriptionAfterForeground()
        try await waitUntil { factory.count == 2 }
        let replacement = try XCTUnwrap(factory.last)
        try await waitUntil { replacement.started }
        replacement.emitOnNextAppend(LiveTranscript(
            finalizedText: "and new speech after returning",
            titleContext: "and new speech after returning"))

        mgr.appendLivePCMForTests(try pcmBuffer())
        try await waitUntil {
            replacement.appended > 0
                && mgr.liveTranscript.displayText.contains("and new speech after returning")
        }

        XCTAssertGreaterThan(replacement.appended, 0,
                             "post-foreground decoded PCM reaches the replacement transcriber")
        XCTAssertTrue(mgr.liveTranscript.displayText.hasPrefix(before),
                      "replacement output appends after the retained transcript")
        XCTAssertGreaterThan(mgr.liveTranscript.displayText.count, before.count)
    }

    /// The decoded-PCM tap actually feeds the transcriber — real Opus packets decode and
    /// arrive as `append` calls — proving the audio source is tapped for live STT.
    func testDecodedPcmIsFedToTheTranscriber() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let src = TestSource(); let factory = FakeFactory()
        let mgr = manager(dir, src, factory)

        src.onState?(.streaming)
        try await waitUntil { mgr.isListeningForSpeechForTests }
        RealOmiFrames.openSession(src.onFrame)   // speech onset opens the conversation
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
        try await waitUntil { mgr.isListeningForSpeechForTests }
        RealOmiFrames.openSession(src.onFrame)   // speech onset opens the conversation
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
        installListeningPreferences(on: mgr, root: dir)

        src.onState?(.streaming)
        try await waitUntil { mgr.isListeningForSpeechForTests }
        RealOmiFrames.openSession(src.onFrame)   // speech onset opens the conversation
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
