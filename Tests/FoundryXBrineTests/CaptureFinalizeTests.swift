import XCTest
import Foundation
import AudioToolbox
import CoreAudioTypes
import FoundryXKit

/// Door-free state-machine test for finalize-on-conversation-close (M4). When a
/// silence gap closes a conversation, the CaptureManager must — once the closed
/// capture's segments are durably on the desktop (ACK'd) — POST finalize to the
/// door so the capture advances to the Lore inbox. The DoorClient.finalize call is
/// injected at the boundary (no live Foundry.app door is touched), so we assert it
/// fires exactly once per closed capture, with the right capture id, AFTER the
/// segments are ACK'd — and that a failed finalize stays retryable.
@MainActor
final class CaptureFinalizeTests: XCTestCase {

    /// A source the test drives directly (start/stop no-ops).
    final class TestSource: AudioFrameSource, @unchecked Sendable {
        var onFrame: ((Data) -> Void)?
        var onState: ((AudioSourceState) -> Void)?
        func start() {}
        func stop() {}
    }

    /// Records finalize calls; can be made to fail to exercise the retry path.
    final class FinalizeRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _calls: [String] = []
        var shouldFail = false
        var calls: [String] { lock.lock(); defer { lock.unlock() }; return _calls }
        func record(_ id: String) throws {
            lock.lock(); _calls.append(id); let fail = shouldFail; lock.unlock()
            if fail { throw DoorError.http(502) }
        }
    }

    /// Real Opus packets (16 kHz, mono, 20 ms = 320 samples) so they exercise the
    /// production OpusLevelMeter decode path end-to-end. A loud sine decodes to a high
    /// RMS (→ level ≫ silenceThreshold, counts as voice); a near-silent block decodes
    /// to RMS ≈ 0 (→ silence). This replaces the old byte-size garbage frames, which
    /// the true RMS meter (correctly) reads as silence.
    private lazy var loudPacket: Data = RealOmiFrames.voiced()
    private lazy var quietPacket: Data = RealOmiFrames.silent()
    private func voiceFrame() -> Data { loudPacket }
    private func silentFrame() -> Data { quietPacket }

    /// Mark every on-disk segment of a capture as ACK'd (door-free) by writing the
    /// `.ack` sibling the WAL uses to mean "durably on the desktop."
    private func ackAllSegments(_ dir: URL, _ captureId: String) {
        let cdir = dir.appendingPathComponent(captureId, isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: cdir, includingPropertiesForKeys: nil)) ?? []
        for f in files where f.pathExtension == "opus" {
            let ack = f.deletingPathExtension().appendingPathExtension("ack")
            try? Data().write(to: ack, options: [.atomic])
        }
    }

    /// Regression: the OpusLevelMeter must actually DECODE real Opus packets to PCM.
    /// The pre-fix converter declared the Opus source at 16 kHz / variable-frames,
    /// which made AudioConverterFillComplexBuffer return noErr but ZERO PCM frames
    /// for every real packet (status=0, pcm=0 → flat bars + a silence-blind
    /// segmenter, exactly what the on-device diag showed). The canonical 48 kHz /
    /// 960-frames declaration decodes them. Assert the decode produces PCM frames
    /// with a noErr status and a finite, in-range level — the precise inverse of the
    /// pcm=0 failure. (Voice-vs-silence discrimination over a real frame STREAM is
    /// covered by testSilenceGapCloseFinalizesOncePerCapture; a single isolated
    /// packet through the 48k→16k resampler carries a priming transient.)
    func testOpusLevelMeterDecodesRealPacketsToPCM() throws {
        let meter = OpusLevelMeter()
        for amp in [1.0, 0.5, 0.0] {
            meter.reset()
            let packet = try XCTUnwrap(OpusTestEncoder.shared.encode(amplitude: amp), "encode \(amp)")
            let level = meter.level(for: packet)
            XCTAssertGreaterThan(meter.lastPCMFrames, 0, "decode must produce PCM frames (was 0 pre-fix) @\(amp)")
            XCTAssertEqual(meter.lastStatus, 0, "decode status noErr @\(amp)")
            XCTAssertTrue(level >= 0 && level <= 1, "level in 0…1 @\(amp)")
        }
    }

    func testSilenceGapCloseFinalizesOncePerCapture() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("foundryx-finalize-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let rec = FinalizeRecorder()
        let src = TestSource()
        let target = DoorTarget(baseURL: URL(string: "http://127.0.0.1:1")!, bearer: "x")
        let mgr = CaptureManager(target: target, baseDir: dir, source: src,
                                 finalize: { id, _ in try rec.record(id) })

        // silenceGap 0 → a silence frame right after voice closes the conversation
        // deterministically (the gap is measured from last voice; 0 ≥ 0). No clock
        // injection / real 2-minute wait needed.
        mgr.setSilenceGap(0)

        // Source streams → ambient capture ARMS; a real speech onset opens the conversation.
        src.onState?(.streaming)
        RealOmiFrames.openSession(src.onFrame)
        try await waitUntil { mgr.active != nil }
        let firstCapture = try XCTUnwrap(mgr.active).captureId

        // Voice opens the conversation; feed enough frames to write ≥1 segment.
        for _ in 0..<(CaptureManager.minVoicedFramesToUpload + 20) { src.onFrame?(voiceFrame()) }
        try XCTUnwrap(mgr.active).flushAndWait()

        // A silent frame now exceeds the (zero) gap → conversation closes + the next
        // opens. The closed capture is firstCapture; a new active capture replaces it.
        src.onFrame?(silentFrame())
        try await waitUntil { mgr.active?.captureId != firstCapture }

        // Segments are durably on the desktop (door-free ACK), then retry finalize.
        ackAllSegments(dir, firstCapture)
        await mgr.retryPendingFinalizes()

        XCTAssertEqual(rec.calls, [firstCapture],
                       "closing a conversation finalizes the CLOSED capture exactly once, with its id")

        // Idempotent: a second retry must NOT re-finalize the already-finalized one.
        await mgr.retryPendingFinalizes()
        XCTAssertEqual(rec.calls, [firstCapture], "a finalized capture is not finalized again")
    }

    // A LARGE, fully-uploaded capture (thousands of ACK'd segments) still finalizes —
    // the finalize path is NOT size-gated. Uses the real stuck giant capture's id so
    // this is the exact recovery shape: once it has drained, it advances to Lore.
    func testLargeCaptureFinalizesNotSizeGated() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("foundryx-finalize-large-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // Pre-seed a large capture, every segment durably ACK'd + pending-finalize.
        let bigId = "omi-20260623-202901-66651093"
        let cdir = dir.appendingPathComponent(bigId, isDirectory: true)
        try FileManager.default.createDirectory(at: cdir, withIntermediateDirectories: true)
        let n = 1500
        for seq in 0..<n {
            let name = String(format: "seg-%012llu", UInt64(seq))
            try Data([1, 2, 3, 4]).write(to: cdir.appendingPathComponent("\(name).opus"))
            try Data().write(to: cdir.appendingPathComponent("\(name).ack"))   // durably on desktop
        }
        try Data().write(to: cdir.appendingPathComponent(".needs-finalize"))   // closed, awaiting finalize

        let rec = FinalizeRecorder()
        let src = TestSource()
        let target = DoorTarget(baseURL: URL(string: "http://127.0.0.1:1")!, bearer: "x")
        let mgr = CaptureManager(target: target, baseDir: dir, source: src,
                                 finalize: { id, _ in try rec.record(id) })
        await mgr.hydration?.value

        await mgr.retryPendingFinalizes()
        XCTAssertEqual(rec.calls, [bigId],
                       "a large, fully-uploaded capture finalizes once — finalize is NOT size-gated")
    }

    func testFinalizeDeferredUntilSegmentsAreAckd() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("foundryx-finalize-defer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let rec = FinalizeRecorder()
        let src = TestSource()
        let target = DoorTarget(baseURL: URL(string: "http://127.0.0.1:1")!, bearer: "x")
        let mgr = CaptureManager(target: target, baseDir: dir, source: src,
                                 finalize: { id, _ in try rec.record(id) })
        mgr.setSilenceGap(0)

        src.onState?(.streaming)
        RealOmiFrames.openSession(src.onFrame)   // speech onset opens the conversation
        try await waitUntil { mgr.active != nil }
        let firstCapture = try XCTUnwrap(mgr.active).captureId
        for _ in 0..<(CaptureManager.minVoicedFramesToUpload + 20) { src.onFrame?(voiceFrame()) }
        try XCTUnwrap(mgr.active).flushAndWait()
        src.onFrame?(silentFrame())
        try await waitUntil { mgr.active?.captureId != firstCapture }

        // Segments NOT yet ACK'd → finalize must be deferred (door has nothing to
        // assemble until the audio is durably on the desktop).
        await mgr.retryPendingFinalizes()
        XCTAssertEqual(rec.calls, [], "finalize must wait until segments are ACK'd")

        // Now ACK + retry → it fires.
        ackAllSegments(dir, firstCapture)
        await mgr.retryPendingFinalizes()
        XCTAssertEqual(rec.calls, [firstCapture], "finalize fires once segments are ACK'd")
    }

    func testFailedFinalizeStaysRetryable() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("foundryx-finalize-retry-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let rec = FinalizeRecorder()
        rec.shouldFail = true              // door/Lore down at close
        let src = TestSource()
        let target = DoorTarget(baseURL: URL(string: "http://127.0.0.1:1")!, bearer: "x")
        let mgr = CaptureManager(target: target, baseDir: dir, source: src,
                                 finalize: { id, _ in try rec.record(id) })
        mgr.setSilenceGap(0)

        src.onState?(.streaming)
        RealOmiFrames.openSession(src.onFrame)   // speech onset opens the conversation
        try await waitUntil { mgr.active != nil }
        let firstCapture = try XCTUnwrap(mgr.active).captureId
        for _ in 0..<(CaptureManager.minVoicedFramesToUpload + 20) { src.onFrame?(voiceFrame()) }
        try XCTUnwrap(mgr.active).flushAndWait()
        src.onFrame?(silentFrame())
        try await waitUntil { mgr.active?.captureId != firstCapture }
        ackAllSegments(dir, firstCapture)

        // First attempt fails — capture must NOT be dropped (mirrors WAL retry).
        await mgr.retryPendingFinalizes()
        XCTAssertEqual(rec.calls, [firstCapture], "the failed attempt happened")

        // Door recovers; the next retry succeeds (the capture was still pending).
        rec.shouldFail = false
        await mgr.retryPendingFinalizes()
        XCTAssertEqual(rec.calls, [firstCapture, firstCapture],
                       "a failed finalize stays retryable and succeeds on the next tick")

        // And now it's cleared — no further attempts.
        await mgr.retryPendingFinalizes()
        XCTAssertEqual(rec.calls, [firstCapture, firstCapture], "no retry after success")
    }

    /// Captures the `endedAt` the finalize POST body carried (P2 regression).
    final class EndCapture: @unchecked Sendable {
        private let lock = NSLock()
        private var _end: UInt64??
        var recorded: Bool { lock.lock(); defer { lock.unlock() }; return _end != nil }
        var endedAt: UInt64? { lock.lock(); defer { lock.unlock() }; return _end ?? nil }
        func record(_ e: UInt64?) { lock.lock(); _end = .some(e); lock.unlock() }
    }

    // P2 — a capture's recorded end must never predate its own newest audio. On 07-16 an
    // orphan-reconcile froze endedAt +12s after start while Omi buffered catch-up audio
    // kept landing for ~2 minutes. Finalize must ship the TRUE end (the newest on-disk
    // segment's wall-clock), not the frozen stub end (which drove premature ingest +
    // replace churn on the desktop).
    func testFinalizeBumpsStaleEndToNewestSegment() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("foundryx-finalize-catchup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let id = "omi-20260716-145612-catchup"
        let cdir = dir.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: cdir, withIntermediateDirectories: true)

        let start = UInt64(Date().timeIntervalSince1970) - 200   // started 200s ago
        let staleEnd = start + 12                                 // orphan-reconcile froze it +12s
        let newestMTime = Date(timeIntervalSince1970: Double(start) + 120)   // catch-up ran ~2 min

        for seq in 0..<6 {
            let name = String(format: "seg-%012llu", UInt64(seq))
            try Data([1, 2, 3, 4]).write(to: cdir.appendingPathComponent("\(name).opus"))
            try Data().write(to: cdir.appendingPathComponent("\(name).ack"))   // durably on desktop
        }
        for f in try FileManager.default.contentsOfDirectory(at: cdir, includingPropertiesForKeys: nil)
            where f.pathExtension == "opus" {
            try FileManager.default.setAttributes([.modificationDate: newestMTime], ofItemAtPath: f.path)
        }
        ConversationMetaStore.save(ConversationMeta(startedAt: start, endedAt: staleEnd),
                                   captureId: id, baseDir: dir)
        try Data().write(to: cdir.appendingPathComponent(".needs-finalize"))

        let captured = EndCapture()
        let src = TestSource()
        let target = DoorTarget(baseURL: URL(string: "http://127.0.0.1:1")!, bearer: "x")
        let mgr = CaptureManager(target: target, baseDir: dir, source: src,
                                 finalize: { _, meta in captured.record(meta?.endedAt) })
        await mgr.hydration?.value

        await mgr.retryPendingFinalizes()

        XCTAssertEqual(captured.endedAt, start + 120,
                       "finalize ships the TRUE end (newest segment), not the frozen +12s stub end")
        XCTAssertEqual(ConversationMetaStore.load(captureId: id, baseDir: dir)?.endedAt, start + 120,
                       "the bumped end is persisted durably")
    }

    private func waitUntil(timeout: TimeInterval = 3, _ cond: @MainActor () -> Bool) async throws {
        let start = Date()
        while !cond() {
            if Date().timeIntervalSince(start) > timeout { XCTFail("waitUntil timed out"); return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

/// Test-only Opus encoder (16 kHz, mono, 20 ms frames) built on AudioToolbox — the
/// inverse of the production OpusLevelMeter decode. Lets the finalize tests inject
/// REAL Opus packets so the true RMS level path is exercised, not a byte-size proxy.
final class OpusTestEncoder: @unchecked Sendable {
    static let shared = OpusTestEncoder()
    private let converter: AudioConverterRef?

    init() {
        var src = AudioStreamBasicDescription()
        src.mSampleRate = 16000
        src.mFormatID = kAudioFormatLinearPCM
        src.mFormatFlags = kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked
        src.mChannelsPerFrame = 1; src.mBitsPerChannel = 16
        src.mBytesPerFrame = 2; src.mFramesPerPacket = 1; src.mBytesPerPacket = 2

        var dst = AudioStreamBasicDescription()
        dst.mSampleRate = 16000
        dst.mFormatID = kAudioFormatOpus
        dst.mChannelsPerFrame = 1
        dst.mFramesPerPacket = 0

        var conv: AudioConverterRef?
        converter = AudioConverterNew(&src, &dst, &conv) == noErr ? conv : nil
    }

    /// One 20 ms (320-sample) Opus packet of a 440 Hz sine at the given amplitude
    /// (0…1). amplitude 0 → near-silence (RMS ≈ 0); 1 → full-scale (loud voice).
    func encode(amplitude: Double) -> Data? {
        guard let conv = converter else { return nil }
        let samples: [Int16] = (0..<320).map { i in
            Int16(amplitude * 32000 * sin(2.0 * .pi * 440.0 * Double(i) / 16000.0))
        }
        final class Ctx { var samples: [Int16]; var done = false; init(_ s: [Int16]) { samples = s } }
        let ctx = Ctx(samples)
        let inProc: AudioConverterComplexInputDataProc = { _, ioNum, ioData, _, ud in
            let c = Unmanaged<Ctx>.fromOpaque(ud!).takeUnretainedValue()
            if c.done { ioNum.pointee = 0; return noErr }
            let n = UInt32(c.samples.count)
            c.samples.withUnsafeMutableBytes { raw in
                ioData.pointee.mBuffers.mData = raw.baseAddress
                ioData.pointee.mBuffers.mDataByteSize = UInt32(raw.count)
                ioData.pointee.mBuffers.mNumberChannels = 1
            }
            ioNum.pointee = n
            c.done = true
            return noErr
        }
        let ud = Unmanaged.passUnretained(ctx).toOpaque()
        var out = [UInt8](repeating: 0, count: 4000)
        return out.withUnsafeMutableBytes { ob -> Data? in
            var abl = AudioBufferList(mNumberBuffers: 1,
                mBuffers: AudioBuffer(mNumberChannels: 1,
                                      mDataByteSize: UInt32(ob.count),
                                      mData: ob.baseAddress))
            var pd = AudioStreamPacketDescription()
            var ioNum: UInt32 = 1
            let st = AudioConverterFillComplexBuffer(conv, inProc, ud, &ioNum, &abl, &pd)
            if (st != noErr && st != 1) || ioNum == 0 { return nil }
            return Data(bytes: ob.baseAddress!.advanced(by: Int(pd.mStartOffset)),
                        count: Int(pd.mDataByteSize))
        }
    }
}
