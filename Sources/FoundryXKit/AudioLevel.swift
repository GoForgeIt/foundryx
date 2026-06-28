// AudioLevel — the phone-side audio-level signal that powers BOTH the live meter
// (req 8) and silence-gap auto-segmentation (req 9), from a SINGLE source of truth
// so the bars the user sees and the boundaries the segmenter draws are the same
// signal.
//
// The level is now a TRUE decoded-amplitude RMS, not a byte-size proxy. Omi streams
// Opus (16 kHz, mono, one packet per BLE notification, already de-framed by the time
// `onFrame` fires). `OpusLevelMeter` decodes each raw Opus packet → Int16 PCM via
// Apple's AudioToolbox `AudioConverter` (kAudioFormatOpus → LinearPCM) and computes
// RMS over the decoded samples, then maps it to a perceptual 0…1. A 20 ms frame
// decodes in microseconds, so this runs cheaply inside the serial FrameRouter lock.
//
// Why AudioToolbox and not libopus-via-SPM: the only maintained Opus SPM package
// (alta/swift-opus) vendors the xiph C source as a git *submodule*, which SPM does
// NOT fetch for a package dependency — it would resolve to an empty Copus target and
// break the iOS build. AudioToolbox is a system framework (zero resolution risk) and
// a roundtrip test proved it decodes 16 kHz mono Omi-sized packets correctly
// (full-scale sine → RMS ≈ 0.58, near-silence → RMS ≈ 0).
//
// `opusFrameLevel` (the legacy byte-size PROXY) is kept only so the byte-proxy unit
// test still documents the old seam; the live pipeline uses `OpusLevelMeter`.

import Foundation
import AudioToolbox
import CoreAudioTypes
#if canImport(AVFoundation)
import AVFoundation
#endif

/// Stateful Opus→PCM RMS level meter for one capture stream. Hold one instance per
/// session (recreate on session start so a new stream begins clean). NOT thread-safe
/// on its own; the FrameRouter calls `level(for:)` under its serial lock.
///
/// `level(for:)` returns a perceptual 0…1 audio level: it decodes the raw Opus
/// packet to Int16 PCM, computes RMS, converts to dBFS, and maps a useful speech
/// window (`floorDB`…`ceilDB`) to 0…1 so the meter fills on loud speech and reads ~0
/// on silence — with real dynamics in between (the byte proxy pegged near-full for
/// any audio). The same value feeds the SilenceSegmenter, so its threshold is tuned
/// to this scale (see `SilenceSegmenter` default).
public final class OpusLevelMeter: @unchecked Sendable {
    private var converter: AudioConverterRef?
    private var pcm = [Int16](repeating: 0, count: 5760)   // max 120 ms @ 48 k upper bound

    /// dBFS window mapped to 0…1. Conversational speech RMS sits roughly -40…-12 dBFS
    /// (a full-scale sine is -3 dBFS / RMS 0.707; real speech is far below that). This
    /// window gives the meter visible dynamics and a stable silence floor.
    private let floorDB: Float = -55
    private let ceilDB: Float = -15

    public init() { converter = Self.makeConverter() }

    deinit { if let c = converter { AudioConverterDispose(c) } }

    /// Recreate the decoder so a new capture stream starts with clean decoder state
    /// (no carried-over PLC / stereo / gain state from the previous conversation).
    public func reset() {
        if let c = converter { AudioConverterDispose(c) }
        converter = Self.makeConverter()
    }

    // Diagnostics: the most recent decode outcome, surfaced to the capture log so
    // a flat meter's cause is visible server-side (decode error vs 0 frames vs
    // sub-floor rms vs no converter).
    public private(set) var lastStatus: OSStatus = 0
    public private(set) var lastPCMFrames: Int = 0
    public private(set) var lastRMS: Float = 0
    public private(set) var hasConverter = true
    /// Status of the OpusHead magic-cookie set (0 = accepted). Surfaced to diag so a
    /// still-flat meter shows whether the cookie was the missing piece.
    public var lastCookieStatus: OSStatus { Self.cookieStatus }
    nonisolated(unsafe) private static var cookieStatus: OSStatus = 0

    /// Decode one raw Opus packet and return its perceptual 0…1 level. Returns 0 on a
    /// failed/empty decode (e.g. a DTX/comfort-noise packet decodes to ~silence → 0).
    public func level(for frame: Data) -> Float {
        hasConverter = converter != nil
        guard !frame.isEmpty, let conv = converter else { return 0 }
        let rms = decodeRMS(frame, conv: conv)
        lastRMS = rms
        if rms <= 0 { return 0 }
        let db = 20 * log10(rms)
        let norm = (db - floorDB) / (ceilDB - floorDB)
        return min(1, max(0, norm))
    }

    // MARK: decode

    private func decodeRMS(_ frame: Data, conv: AudioConverterRef) -> Float {
        // Decode each packet INDEPENDENTLY: reset the converter first. The input proc
        // below returns 0 packets after handing over our one packet, which the
        // converter reads as END-OF-STREAM — without a reset that EOS state persists
        // and EVERY subsequent packet decodes to 0 frames (on-device: only the very
        // first frame ever produced PCM). Reset clears it so each BLE packet decodes
        // cleanly for its RMS. CELT frames are self-contained enough for metering.
        AudioConverterReset(conv)
        let pktDesc = AudioStreamPacketDescription(
            mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(frame.count))

        // Input proc context: hand the converter our one packet exactly once.
        final class FeedCtx { var bytes: [UInt8]; var desc: AudioStreamPacketDescription; var done = false
            init(_ b: [UInt8], _ d: AudioStreamPacketDescription) { bytes = b; desc = d } }
        let ctx = FeedCtx([UInt8](frame), pktDesc)

        let inputProc: AudioConverterComplexInputDataProc = { _, ioNumPackets, ioData, outDesc, ud in
            let c = Unmanaged<FeedCtx>.fromOpaque(ud!).takeUnretainedValue()
            if c.done { ioNumPackets.pointee = 0; return noErr }
            c.bytes.withUnsafeMutableBytes { raw in
                ioData.pointee.mBuffers.mData = raw.baseAddress
                ioData.pointee.mBuffers.mDataByteSize = UInt32(raw.count)
                ioData.pointee.mBuffers.mNumberChannels = 1
            }
            ioNumPackets.pointee = 1
            if let outDesc { outDesc.pointee = withUnsafeMutablePointer(to: &c.desc) { $0 } }
            c.done = true
            return noErr
        }

        let ud = Unmanaged.passUnretained(ctx).toOpaque()
        var ioNumFrames: UInt32 = UInt32(pcm.count)
        let status: OSStatus = pcm.withUnsafeMutableBytes { out in
            var abl = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(mNumberChannels: 1,
                                      mDataByteSize: UInt32(out.count),
                                      mData: out.baseAddress))
            return AudioConverterFillComplexBuffer(conv, inputProc, ud, &ioNumFrames, &abl, nil)
        }
        lastStatus = status
        // noErr (0) or "input ran out" (1) both yield valid decoded frames.
        if status != noErr && status != 1 { lastPCMFrames = 0; return 0 }
        let n = Int(ioNumFrames)
        lastPCMFrames = n
        if n == 0 { return 0 }

        var acc: Double = 0
        pcm.withUnsafeBufferPointer { p in
            for i in 0..<n { let s = Double(p[i]) / 32768.0; acc += s * s }
        }
        return Float((acc / Double(n)).squareRoot())
    }

    private static func makeConverter() -> AudioConverterRef? {
        let (conv, status) = buildOpusToPCMConverter()
        cookieStatus = status
        return conv
    }
}

/// Shared Opus(48k/960)→Int16-PCM(48k mono) AudioConverter builder, with the RFC 7845
/// OpusHead magic cookie. Used by BOTH the level meter (per-packet RMS) and the live
/// on-device STT decoder. Returns the converter + the cookie-set status (0 = accepted).
func buildOpusToPCMConverter() -> (AudioConverterRef?, OSStatus) {
        // Apple's kAudioFormatOpus decoder REQUIRES the source declared at 48 kHz /
        // 960 frames-per-packet — Opus always decodes to 48 kHz internally and the
        // per-packet TOC byte carries the real bandwidth, so this declaration is
        // correct regardless of the rate Omi encodes at. Declaring 16 kHz / variable
        // (0) made AudioConverterFillComplexBuffer return noErr but ZERO PCM frames
        // for real packets (the synthetic roundtrip test passed only because it
        // encoded AND decoded with the same self-consistent 16 kHz config). We let
        // the converter resample 48 k → 16 k so the RMS window + buffer sizing are
        // unchanged. (Apple's sanctioned example: 48000 / mFramesPerPacket = 960.)
        var src = AudioStreamBasicDescription()
        src.mSampleRate = 48000
        src.mFormatID = kAudioFormatOpus
        src.mChannelsPerFrame = 1
        src.mFramesPerPacket = 960

        var dst = AudioStreamBasicDescription()
        dst.mSampleRate = 48000
        dst.mFormatID = kAudioFormatLinearPCM
        dst.mFormatFlags = kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked
        dst.mChannelsPerFrame = 1
        dst.mBitsPerChannel = 16
        dst.mBytesPerFrame = 2
        dst.mFramesPerPacket = 1
        dst.mBytesPerPacket = 2

        var conv: AudioConverterRef?
        let st = AudioConverterNew(&src, &dst, &conv)
        guard st == noErr, let c = conv else { return (nil, 0) }

        // Opus magic cookie (RFC 7845 OpusHead). REAL libopus-encoded Omi packets
        // need this for Apple's decoder to know the channel-mapping / pre-skip / input
        // rate; without it the decoder initializes empty and emits 0 PCM frames
        // (status=noErr, pcm=0) — exactly what on-device diag showed even after the
        // 48k/960 fix. (Apple's OWN encoder is lenient with its own packets, which is
        // why the synthetic roundtrip test decoded without a cookie.) 19 bytes:
        //   "OpusHead"(8) ver=1(1) channels=1(1) preSkip(2,LE) inputRate(4,LE)
        //   outputGain=0(2,LE) mappingFamily=0(1).
        var cookie = [UInt8]()
        cookie.append(contentsOf: Array("OpusHead".utf8))
        cookie.append(1)                       // version
        cookie.append(1)                       // channel count (mono)
        let preSkip: UInt16 = 0                // 0: we decode each packet INDEPENDENTLY for
                                               // metering (converter is reset per packet), so
                                               // a non-zero encoder-delay trim would eat each
                                               // short 20ms frame down to near-silence.
        cookie.append(UInt8(preSkip & 0xff)); cookie.append(UInt8(preSkip >> 8))
        let inRate: UInt32 = 16000             // Omi's original encode rate (informational)
        cookie.append(UInt8(inRate & 0xff)); cookie.append(UInt8((inRate >> 8) & 0xff))
        cookie.append(UInt8((inRate >> 16) & 0xff)); cookie.append(UInt8((inRate >> 24) & 0xff))
        cookie.append(0); cookie.append(0)     // output gain Q7.8 = 0 dB
        cookie.append(0)                       // channel mapping family 0 (mono/stereo)
        let setStatus = cookie.withUnsafeBytes {
            AudioConverterSetProperty(c, kAudioConverterDecompressionMagicCookie,
                                      UInt32($0.count), $0.baseAddress!)
        }
        return (c, setStatus)               // setStatus surfaced to diag (0 = accepted)
}

/// Legacy byte-size PROXY (VBR/DTX): tiny DTX/silence frames → ~0; full speech
/// frames → ~1. NO LONGER drives the live meter or segmenter — those use the true
/// RMS `OpusLevelMeter`. Retained so the byte-proxy unit test keeps documenting the
/// old seam; do not reintroduce into the capture pipeline.
public func opusFrameLevel(_ frame: Data) -> Float {
    let silenceBytes = 10.0
    let voiceBytes = 80.0
    let v = (Double(frame.count) - silenceBytes) / (voiceBytes - silenceBytes)
    return Float(min(1.0, max(0.0, v)))
}

/// A boundary the segmenter draws in the continuous ambient stream.
public enum SegmentEvent: Equatable, Sendable {
    case opened   // first voice after idle → a conversation begins
    case closed   // silence has exceeded the gap → the conversation ends
}

/// Silence-gap auto-segmentation (req 9, à la Omi). Fed the same per-frame level
/// that drives the meter; when voice has been quiet for longer than `silenceGap`
/// it emits `.closed` (the owner rotates to a new conversation). The first voice
/// after a close emits `.opened`. Pure + clock-injectable so it's deterministically
/// testable without sleeping out a real 2-minute gap.
public final class SilenceSegmenter: @unchecked Sendable {
    /// Omi's conversation boundary is a single silence-gap timeout of 120s (clamped
    /// [120s, 4h]); there is NO speaker-change or max-duration boundary. We adopt it
    /// (`foundryx-hearth/research/20260628_omi_segmentation_learnings.md`). Tunable.
    public static let defaultSilenceGap: TimeInterval = 120
    /// Minimum VOICED frames a conversation must accumulate before a silence gap will
    /// CLOSE it into its own conversation. Below this the gap is ignored and the
    /// conversation stays open to ABSORB the next utterance — so a 1–2 word noise burst
    /// merges forward (Omi's adjacent-fragment merge) instead of spawning a tiny card.
    /// ~100 frames ≈ 2 s of real voice at the Omi's ~50 frames/s. Tunable.
    public static let defaultMinVoicedFramesToClose = 100

    /// Quiet span (seconds) that ends a conversation. User-configurable (default 120s).
    public var silenceGap: TimeInterval
    /// Levels below this count as silence.
    public var silenceThreshold: Float
    /// Min voiced frames before a gap may close the conversation (else: merge forward).
    public var minVoicedFramesToClose: Int

    private enum State { case idle, open }
    private var state: State = .idle
    private var lastVoice: TimeInterval?
    /// Voiced frames observed since the CURRENT conversation opened. Drives the
    /// merge-forward gate so a too-short burst never stands alone as its own capture.
    private var voicedFrames = 0

    // silenceThreshold is on the OpusLevelMeter perceptual 0…1 scale: a -55…-15 dBFS
    // window where decoded silence/DTX → 0 and conversational speech (≈ -40…-15 dBFS)
    // reads ≈ 0.37…1.0. 0.06 sits just above the silence floor so genuine voice opens
    // a conversation while the quiet background between utterances stays below it (the
    // silenceGap timer is what actually closes a conversation, not momentary dips).
    public init(silenceGap: TimeInterval = SilenceSegmenter.defaultSilenceGap,
                silenceThreshold: Float = 0.06,
                minVoicedFramesToClose: Int = SilenceSegmenter.defaultMinVoicedFramesToClose) {
        self.silenceGap = silenceGap
        self.silenceThreshold = silenceThreshold
        self.minVoicedFramesToClose = minVoicedFramesToClose
    }

    /// Feed one frame's `level` observed at time `t` (seconds, monotonic). Returns a
    /// boundary event, or nil if the conversation state is unchanged.
    public func observe(level: Float, at t: TimeInterval) -> SegmentEvent? {
        if level >= silenceThreshold {            // voice
            lastVoice = t
            if state == .idle { state = .open; voicedFrames = 1; return .opened }
            voicedFrames += 1
            return nil
        }
        // silence: a gap may close the conversation (gated on the same wall-clock +
        // min-content rule the watchdog timer uses).
        return checkSilence(at: t)
    }

    /// Wall-clock silence boundary check, INDEPENDENT of frame arrival. The Omi BLE
    /// stream stops delivering frames during silence (DTX / device idle), so `observe`
    /// is never called during a real gap and the boundary could never be detected from
    /// frames alone — this is the root cause of captures swallowing many conversations.
    /// A periodic watchdog tick (and the silence branch of `observe`) call this on the
    /// elapsed quiet since the last voice. Closes ONLY a conversation that has enough
    /// voiced content to stand alone; a too-short burst is left open (merge forward).
    public func checkSilence(at t: TimeInterval) -> SegmentEvent? {
        guard state == .open, let lv = lastVoice, (t - lv) >= silenceGap else { return nil }
        guard voicedFrames >= minVoicedFramesToClose else { return nil }  // too short → merge fwd
        state = .idle
        voicedFrames = 0
        return .closed
    }

    /// Back to "no conversation open" (fresh stream / device reconnect).
    public func reset() { state = .idle; lastVoice = nil; voicedFrames = 0 }

    /// Bump the voice baseline without changing open/closed state — used after a
    /// deliberate pause so the paused interval isn't mistaken for a silence gap.
    public func noteActive(at t: TimeInterval) { lastVoice = t }
}

/// Thread-safe peak-level mailbox between the off-main frame path and the main-thread
/// meter timer. The frame callback records levels (no main hop per frame); the timer
/// drains the peak ~12×/s to drive the bars.
final class LevelBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var peak: Float = 0
    func record(_ v: Float) { lock.lock(); if v > peak { peak = v }; lock.unlock() }
    func drainPeak() -> Float { lock.lock(); let p = peak; peak = 0; lock.unlock(); return p }
}

#if canImport(AVFoundation)
/// Continuous Opus→PCM decoder for the live on-device STT tap (Feature 1). Mirrors the
/// proven per-packet decode in `OpusLevelMeter` (same 48 kHz/960 converter + RFC 7845
/// OpusHead cookie) but returns the decoded samples as an `AVAudioPCMBuffer` (48 kHz,
/// mono, Int16) for SpeechTranscriber instead of an RMS scalar. Side-effect-only;
/// created per capture session, called serially from FrameRouter's serial source queue.
///
/// Caveat (the "decode-config fork", design §7.2): like the level meter, this resets the
/// AudioConverter per packet — the input proc signals end-of-stream after handing over
/// one packet, which otherwise wedges the converter to 0 PCM frames on every subsequent
/// packet. That yields valid PER-PACKET PCM (proven by the level-meter decode) at the
/// cost of cross-packet PLC continuity, which is acceptable for a PROVISIONAL preview.
/// NOT yet verified against real Omi hardware end-to-end.
public final class OpusPCMDecoder: @unchecked Sendable {
    private var converter: AudioConverterRef?
    private var pcm = [Int16](repeating: 0, count: 5760)   // max 120 ms @ 48 k upper bound
    /// The decoded buffer format (48 kHz, mono, Int16 interleaved). SpeechTranscriber's
    /// own converter resamples this to the analyzer's required format.
    public let format = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                      sampleRate: 48000, channels: 1, interleaved: true)!

    public init() { let (c, _) = buildOpusToPCMConverter(); converter = c }
    deinit { if let c = converter { AudioConverterDispose(c) } }

    /// Recreate the decoder so a new capture stream starts clean.
    public func reset() {
        if let c = converter { AudioConverterDispose(c) }
        let (c, _) = buildOpusToPCMConverter(); converter = c
    }

    /// Decode one raw Opus packet → PCM buffer. nil on a failed/empty decode.
    public func decode(_ frame: Data) -> AVAudioPCMBuffer? {
        guard !frame.isEmpty, let conv = converter else { return nil }
        AudioConverterReset(conv)
        let pktDesc = AudioStreamPacketDescription(
            mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(frame.count))

        final class FeedCtx { var bytes: [UInt8]; var desc: AudioStreamPacketDescription; var done = false
            init(_ b: [UInt8], _ d: AudioStreamPacketDescription) { bytes = b; desc = d } }
        let ctx = FeedCtx([UInt8](frame), pktDesc)

        let inputProc: AudioConverterComplexInputDataProc = { _, ioNumPackets, ioData, outDesc, ud in
            let c = Unmanaged<FeedCtx>.fromOpaque(ud!).takeUnretainedValue()
            if c.done { ioNumPackets.pointee = 0; return noErr }
            c.bytes.withUnsafeMutableBytes { raw in
                ioData.pointee.mBuffers.mData = raw.baseAddress
                ioData.pointee.mBuffers.mDataByteSize = UInt32(raw.count)
                ioData.pointee.mBuffers.mNumberChannels = 1
            }
            ioNumPackets.pointee = 1
            if let outDesc { outDesc.pointee = withUnsafeMutablePointer(to: &c.desc) { $0 } }
            c.done = true
            return noErr
        }

        let ud = Unmanaged.passUnretained(ctx).toOpaque()
        var ioNumFrames: UInt32 = UInt32(pcm.count)
        let status: OSStatus = pcm.withUnsafeMutableBytes { out in
            var abl = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(mNumberChannels: 1,
                                      mDataByteSize: UInt32(out.count),
                                      mData: out.baseAddress))
            return AudioConverterFillComplexBuffer(conv, inputProc, ud, &ioNumFrames, &abl, nil)
        }
        if status != noErr && status != 1 { return nil }
        let n = Int(ioNumFrames)
        guard n > 0, let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n)),
              let dst = buf.int16ChannelData else { return nil }
        buf.frameLength = AVAudioFrameCount(n)
        pcm.withUnsafeBufferPointer { p in dst[0].update(from: p.baseAddress!, count: n) }
        return buf
    }
}
#endif
