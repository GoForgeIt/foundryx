import XCTest
import Foundation
import FoundryXKit

/// Phone-microphone capture-source tests (door-free). The phone mic is "just another
/// AudioFrameSource": it Opus-encodes mic PCM into the SAME 48 kHz/960 segment format
/// the Omi pipeline + door mux already assume, then drives the IDENTICAL capture
/// lifecycle (beginSession on .streaming, finalize on .stopped). These assert:
///   1. (AC2) the mic Opus encoder produces packets the production decoder reads, and
///      whose Opus TOC declares a 20 ms (960-sample) frame — exactly what the door's
///      granule parser reads, so no door change is needed.
///   2. (AC1/AC3) starting/stopping a phone-mic recording begins/ends a session and
///      finalizes the closed capture once, through the normal finalize path.
///   3. (AC4) selecting a capture source persists and doesn't auto-start the Omi.
@MainActor
final class PhoneMicCaptureTests: ProcessGlobalStateTestCase {

    /// A controllable stand-in source (Omi or mic): start/stop are recorded, and the
    /// test fires the onFrame/onState closures CaptureManager installs.
    final class TestSource: AudioFrameSource, @unchecked Sendable {
        var onFrame: ((Data) -> Void)?
        var onState: ((AudioSourceState) -> Void)?
        private(set) var startCount = 0
        private(set) var stopCount = 0
        func start() { startCount += 1 }
        func stop() { stopCount += 1 }
    }

    final class FinalizeRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _calls: [String] = []
        var calls: [String] { lock.lock(); defer { lock.unlock() }; return _calls }
        func record(_ id: String) { lock.lock(); _calls.append(id); lock.unlock() }
    }

    /// One 20 ms (960-sample @ 48 kHz) Int16 sine block at the given amplitude.
    private func pcm960(amplitude: Double) -> [Int16] {
        (0..<OpusEncoder48k.frameSamples).map { i in
            Int16(amplitude * 30000 * sin(2.0 * .pi * 440.0 * Double(i) / 48000.0))
        }
    }

    /// Mirror of the door's TOC → 48 kHz sample-count parse
    /// (foundry foundryx_capture_ingest.rs `opus_frame_samples_48k`), so we can assert
    /// the encoder's packet frames at exactly 20 ms = 960 samples the way the door will.
    private func frameSamples48k(_ packet: Data) -> Int {
        guard let toc = packet.first else { return 0 }
        let config = Int(toc >> 3)
        let code = Int(toc & 0b11)
        // config → frame duration in 48 kHz samples (Opus TOC table).
        let perFrame: Int
        switch config {
        case 0, 4, 8, 12, 14: perFrame = 480        // 10 ms (SILK/Hybrid)
        case 1, 5, 9, 13, 15: perFrame = 960        // 20 ms (SILK/Hybrid)
        case 2, 6, 10:        perFrame = 1920       // 40 ms (SILK)
        case 3, 7, 11:        perFrame = 2880       // 60 ms (SILK)
        case 16, 20, 24, 28:  perFrame = 120        // 2.5 ms (CELT)
        case 17, 21, 25, 29:  perFrame = 240        // 5 ms (CELT)
        case 18, 22, 26, 30:  perFrame = 480        // 10 ms (CELT)
        case 19, 23, 27, 31:  perFrame = 960        // 20 ms (CELT)
        default:              perFrame = 0
        }
        let frames: Int
        switch code {
        case 0: frames = 1
        case 1, 2: frames = 2
        default: frames = packet.count > 1 ? Int(packet[1] & 0b0011_1111) : 1
        }
        return perFrame * frames
    }

    // MARK: AC2 — codec-format match (encoder ⇄ pipeline decoder + door granule)

    func testMicOpusEncoderMatchesPipelineFormat() throws {
        let encoder = OpusEncoder48k()
        XCTAssertTrue(encoder.isReady, "AudioToolbox Opus encoder must initialize")

        let meter = OpusLevelMeter()
        var decodedAny = false
        for amp in [1.0, 0.6, 0.2] {
            guard let packet = encoder.encode(pcm960(amplitude: amp)) else {
                XCTFail("encode @\(amp) produced no packet"); continue
            }
            XCTAssertFalse(packet.isEmpty, "Opus packet non-empty @\(amp)")
            // The door reads each packet's TOC → granule; for our 20 ms frames that's 960.
            XCTAssertEqual(frameSamples48k(packet), 960,
                           "mic packet must declare a 20 ms / 960-sample frame (door granule) @\(amp)")
            // The SAME on-device decoder the Omi pipeline uses must decode it to PCM.
            meter.reset()
            _ = meter.level(for: packet)
            XCTAssertEqual(meter.lastStatus, 0, "production decoder status noErr @\(amp)")
            XCTAssertGreaterThan(meter.lastPCMFrames, 0, "production decoder yields PCM frames @\(amp)")
            decodedAny = true
        }
        XCTAssertTrue(decodedAny, "at least one encoded packet decoded through the pipeline")
    }

    // MARK: AC1/AC3 — phone-mic recording begins a session and finalizes normally

    func testPhoneMicRecordingFinalizesThroughNormalPath() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("foundryx-mic-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let rec = FinalizeRecorder()
        let omi = TestSource()
        let mic = TestSource()
        let target = DoorTarget(baseURL: URL(string: "http://127.0.0.1:1")!, bearer: "x")
        let mgr = CaptureManager(target: target, baseDir: dir, source: omi, micSource: mic,
                                 finalize: { id, _ in rec.record(id) })
        #if os(iOS)
        mgr.micPermissionOverrideForTests = true  // sim can't drive the real permission prompt
        #endif

        XCTAssertTrue(mgr.phoneMicAvailable, "a wired mic source makes the Record control available")
        XCTAssertFalse(mgr.isRecordingMic)

        // Start recording: manager flips the flag + asks the mic to start; the engine's
        // .streaming (simulated) begins the capture session.
        mgr.startMicRecording()
        XCTAssertTrue(mgr.isRecordingMic)
        XCTAssertEqual(mic.startCount, 1, "the mic source was started")
        mic.onState?(.streaming)
        try await waitUntil { mgr.active != nil }
        let capture = try XCTUnwrap(mgr.active).captureId

        // Encode enough real 48 kHz mic frames to clear the min-substance upload bar (a
        // shorter recording would be dropped as a junk fragment) into the SAME router/WAL.
        let encoder = OpusEncoder48k()
        for _ in 0..<(CaptureManager.minVoicedFramesToUpload + 20) {
            if let pkt = encoder.encode(pcm960(amplitude: 0.8)) { mic.onFrame?(pkt) }
        }
        try XCTUnwrap(mgr.active).flushAndWait()
        XCTAssertGreaterThan(try XCTUnwrap(mgr.active).snapshot().totalSegments, 0,
                             "mic frames are WAL'd just like Omi frames")

        // Stop: the mic's .stopped ends the session + marks it pending-finalize.
        mgr.stopMicRecording()
        XCTAssertEqual(mic.stopCount, 1, "the mic source was stopped")
        mic.onState?(.stopped)
        try await waitUntil { mgr.active == nil }
        XCTAssertFalse(mgr.isRecordingMic, "stopping clears the recording flag")

        // ACK the segments (door-free) then finalize fires once, exactly like Omi.
        ackAllSegments(dir, capture)
        await mgr.retryPendingFinalizes()
        XCTAssertEqual(rec.calls, [capture],
                       "a phone-mic capture finalizes through the normal path, once")
    }

    // MARK: AC4 — selecting a capture source persists and gates the Omi

    func testSelectingPhoneMicPersistsAndDoesNotAutoStartOmi() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("foundryx-src-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        CaptureSettings.captureSource = .omi   // known starting point
        let omi = TestSource()
        let mic = TestSource()
        let target = DoorTarget(baseURL: URL(string: "http://127.0.0.1:1")!, bearer: "x")
        let mgr = CaptureManager(target: target, baseDir: dir, source: omi, micSource: mic)
        #if os(iOS)
        mgr.micPermissionOverrideForTests = true  // sim can't drive the real permission prompt
        #endif

        // Pick the phone mic: the Omi is released, and startSource() must NOT start it.
        mgr.selectCaptureSource(.phoneMic)
        XCTAssertEqual(mgr.captureSource, .phoneMic)
        XCTAssertEqual(CaptureSettings.captureSource, .phoneMic, "the choice persists")
        let omiStartsBefore = omi.startCount
        mgr.startSource()
        XCTAssertEqual(omi.startCount, omiStartsBefore, "phone-mic mode must not auto-start the Omi")

        // Back to Omi: startSource() resumes the Omi connect flow.
        mgr.selectCaptureSource(.omi)
        XCTAssertEqual(mgr.captureSource, .omi)
        mgr.startSource()
        XCTAssertGreaterThan(omi.startCount, omiStartsBefore, "Omi mode starts the Omi source")

        CaptureSettings.captureSource = .omi   // restore default for other tests
    }

    // MARK: helpers

    private func ackAllSegments(_ dir: URL, _ captureId: String) {
        let cdir = dir.appendingPathComponent(captureId, isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: cdir, includingPropertiesForKeys: nil)) ?? []
        for f in files where f.pathExtension == "opus" {
            try? Data().write(to: f.deletingPathExtension().appendingPathExtension("ack"), options: [.atomic])
        }
    }

    private // Deadline is generous ON PURPOSE. The `flake` gate runs this suite a second time
    // under deliberately induced CPU load, where a capture session can be starved for
    // seconds. A 3s bound there tested the SCHEDULER, not the behaviour — it made the
    // flake gate fail ~70% of the time on a clean main, which trains everyone to ignore
    // the one gate whose job is catching real flakiness (track 20260726T0030).
    // The assertion is unchanged: the condition must still become true.
    func waitUntil(timeout: TimeInterval = 300, _ cond: @MainActor () -> Bool) async throws {
        let start = Date()
        while !cond() {
            if Date().timeIntervalSince(start) > timeout { XCTFail("waitUntil timed out"); return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}
