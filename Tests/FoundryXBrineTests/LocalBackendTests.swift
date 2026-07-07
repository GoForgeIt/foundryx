import XCTest
import Foundation
import FoundryXKit

/// Phase 2 (track 20260705T1100): the "Just my phone" brain. LocalBackend must
/// behave exactly like a door from the pipeline's point of view — finalize
/// transcribes on-device and persists through the SAME stores (event log included);
/// status + content serve from those stores. STT is faked here; WhisperKit is the
/// real engine on-device (not runnable in CI).
final class LocalBackendTests: XCTestCase {

    final class FakeSTT: LocalSTT, @unchecked Sendable {
        var available = true
        var received: [Data] = []
        var text = "hello from the phone brain"
        var isAvailable: Bool { available }
        func transcribe(opusFrames: [Data]) async throws -> String {
            received = opusFrames
            return text
        }
    }

    private func tempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("foundryx-localbackend-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Write a capture dir with WAL-encoded segments of the given frames.
    private func seedCapture(_ id: String, dir: URL, segments: [[Data]]) throws {
        let cdir = dir.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: cdir, withIntermediateDirectories: true)
        for (i, frames) in segments.enumerated() {
            let body = CaptureWAL.encodeSegment(frames)
            try body.write(to: cdir.appendingPathComponent(CaptureWAL.segName(UInt64(i))))
        }
    }

    func testDecodeSegmentRoundTripsAndToleratesTornTail() {
        let frames = [Data([1, 2, 3]), Data(repeating: 7, count: 40), Data([9])]
        let encoded = CaptureWAL.encodeSegment(frames)
        XCTAssertEqual(CaptureWAL.decodeSegment(encoded), frames)

        // Torn tail: drop the last 2 bytes — the truncated final frame is skipped,
        // the intact ones survive.
        let torn = encoded.prefix(encoded.count - 2)
        XCTAssertEqual(CaptureWAL.decodeSegment(Data(torn)), Array(frames.prefix(2)))
    }

    func testFinalizeTranscribesAllFramesInOrderAndPersists() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let f1 = Data([1, 1]), f2 = Data([2, 2]), f3 = Data([3, 3])
        try seedCapture("cap-1", dir: dir, segments: [[f1, f2], [f3]])

        let stt = FakeSTT()
        let backend = LocalBackend(baseDir: dir, stt: stt)
        try await backend.finalize(captureId: "cap-1", meta: nil)

        XCTAssertEqual(stt.received, [f1, f2, f3], "all frames, segment order preserved")
        let cached = TranscriptCacheStore.load(captureId: "cap-1", baseDir: dir)
        XCTAssertEqual(cached?.transcript, "hello from the phone brain")

        // The same event-log discipline as the door path: the transcript landing is
        // an appended fact.
        let kinds = CaptureEventLog.events(baseDir: dir).map(\.kind)
        XCTAssertTrue(kinds.contains("transcript_set"), "local transcribe appends to the event log: \(kinds)")
    }

    func testStatusAndContentServeFromLocalStores() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try seedCapture("cap-2", dir: dir, segments: [[Data([5, 5])]])
        let backend = LocalBackend(baseDir: dir, stt: FakeSTT())

        // Before finalize: not transcribed, content not found.
        var status = try await backend.captureStatus(captureId: "cap-2")
        XCTAssertFalse(status.transcribed)
        var content = try await backend.captureContent(captureId: "cap-2")
        XCTAssertFalse(content.found)

        try await backend.finalize(captureId: "cap-2", meta: nil)

        status = try await backend.captureStatus(captureId: "cap-2")
        XCTAssertTrue(status.transcribed)
        XCTAssertEqual(status.stage, "transcribed")
        content = try await backend.captureContent(captureId: "cap-2")
        XCTAssertTrue(content.found)
        XCTAssertEqual(content.transcript, "hello from the phone brain")
    }

    func testUnavailableSTTThrowsSoTheCaptureStaysPending() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try seedCapture("cap-3", dir: dir, segments: [[Data([1])]])
        let stt = FakeSTT()
        stt.available = false
        let backend = LocalBackend(baseDir: dir, stt: stt)
        do {
            try await backend.finalize(captureId: "cap-3", meta: nil)
            XCTFail("finalize must throw when STT is unavailable")
        } catch let e as LocalBackendError {
            XCTAssertEqual(e, .sttUnavailable)
        }
        XCTAssertNil(TranscriptCacheStore.load(captureId: "cap-3", baseDir: dir),
                     "no transcript may be fabricated when STT can't run")
    }

    func testNoAudioThrowsNotFabricates() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try seedCapture("cap-4", dir: dir, segments: [])   // dir exists, no segments
        let backend = LocalBackend(baseDir: dir, stt: FakeSTT())
        do {
            try await backend.finalize(captureId: "cap-4", meta: nil)
            XCTFail("finalize must throw on a capture with no audio")
        } catch let e as LocalBackendError {
            XCTAssertEqual(e, .noAudio("cap-4"))
        }
    }
}
