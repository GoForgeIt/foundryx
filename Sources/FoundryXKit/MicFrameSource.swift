// MicFrameSource — the PHONE'S OWN MICROPHONE as an AudioFrameSource, so a user can
// record a conversation with the phone when the Omi wearable isn't connected. It is
// "just another frame source": it emits raw Opus packets through `onFrame` in the
// EXACT format the rest of the pipeline (CaptureWAL → door mux_ogg_opus → Lore → STT)
// already speaks, so capture id / finalize / upload / live-transcription all behave
// identically to an Omi stream. Nothing downstream knows the difference.
//
// Codec match (the load-bearing detail): the Omi delivers Opus packets; the phone mic
// delivers PCM via AVAudioEngine. So we encode the mic PCM into Opus and frame it the
// same way:
//   • 48 kHz, mono, 20 ms (960-sample) frames — the SAME framing the door's TOC-based
//     granule parser and the on-device OpusLevelMeter/OpusPCMDecoder (48 kHz/960
//     OpusHead) already assume. The door reads each packet's TOC byte for its granule,
//     so a standard 48 kHz Opus packet (config 20 ms → 960 samples) is parsed exactly.
//   • each `onFrame` carries ONE raw Opus packet — the same shape an Omi notification
//     yields AFTER its 3-byte BLE header is stripped (so we add no header here).
//
// Encoding uses AudioToolbox's `kAudioFormatOpus` AudioConverter — the inverse of the
// proven OpusLevelMeter decode (same system framework, no third-party Opus). The mic's
// hardware PCM (whatever rate/format the input node gives) is first normalised to
// 48 kHz mono Int16 via AVAudioConverter, then grouped into 960-sample frames and
// Opus-encoded.

import Foundation
import AudioToolbox
import CoreAudioTypes
#if canImport(AVFoundation)
import AVFoundation
#endif

/// Which device is the active capture source. Persisted so the choice survives relaunch.
public enum CaptureSourceKind: String, Sendable, Equatable {
    case omi
    case phoneMic
}

/// Stateful Int16-PCM(48 kHz mono) → Opus(48 kHz/960, 20 ms) encoder. The inverse of
/// `buildOpusToPCMConverter()`'s decoder. Feed it exactly `frameSamples` samples per
/// `encode` call to get one 20 ms Opus packet; the converter keeps its encoder state
/// across calls (unlike the per-packet-reset DECODER) so cross-frame Opus continuity is
/// preserved. NOT thread-safe on its own — the MicFrameSource calls it on its serial
/// encode queue (and tests call it serially).
public final class OpusEncoder48k: @unchecked Sendable {
    /// 20 ms at 48 kHz — the canonical frame the whole pipeline assumes.
    public static let frameSamples = 960

    private let converter: AudioConverterRef?

    public init() {
        var src = AudioStreamBasicDescription()
        src.mSampleRate = 48000
        src.mFormatID = kAudioFormatLinearPCM
        src.mFormatFlags = kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked
        src.mChannelsPerFrame = 1
        src.mBitsPerChannel = 16
        src.mBytesPerFrame = 2
        src.mFramesPerPacket = 1
        src.mBytesPerPacket = 2

        var dst = AudioStreamBasicDescription()
        dst.mSampleRate = 48000
        dst.mFormatID = kAudioFormatOpus
        dst.mChannelsPerFrame = 1
        dst.mFramesPerPacket = 0   // let the encoder pick its frame size (defaults to 20 ms)

        var conv: AudioConverterRef?
        converter = AudioConverterNew(&src, &dst, &conv) == noErr ? conv : nil
    }

    deinit { if let c = converter { AudioConverterDispose(c) } }

    public var isReady: Bool { converter != nil }

    /// Encode one 20 ms block (`frameSamples` Int16 mono samples) → one Opus packet.
    /// Returns nil on a failed/empty encode.
    public func encode(_ samples: [Int16]) -> Data? {
        guard let conv = converter, !samples.isEmpty else { return nil }

        final class Ctx { var samples: [Int16]; var done = false
            init(_ s: [Int16]) { samples = s } }
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
            var abl = AudioBufferList(
                mNumberBuffers: 1,
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

#if os(iOS) && canImport(AVFoundation)

/// The phone microphone as an AudioFrameSource (iOS). `start()` requests mic
/// permission, configures the record audio session, taps the input node, normalises
/// to 48 kHz mono Int16, Opus-encodes 20 ms frames, and emits them through `onFrame`
/// — exactly the Omi stream shape. `stop()` tears the engine down and emits `.stopped`
/// (which finalizes the capture through the normal path).
public final class MicFrameSource: NSObject, AudioFrameSource, @unchecked Sendable {
    public var onFrame: ((Data) -> Void)?
    public var onState: ((AudioSourceState) -> Void)?

    private let log: DoorLog?
    private let engine = AVAudioEngine()
    private let encoder = OpusEncoder48k()
    private let target48k = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                          sampleRate: 48000, channels: 1, interleaved: true)!
    private var converter: AVAudioConverter?
    /// Serial encode queue — keeps `onFrame` ordered (the FrameRouter assumes a serial
    /// source callback queue) and the Int16 accumulator single-threaded.
    private let queue = DispatchQueue(label: "foundryx.mic-source")
    private var pending: [Int16] = []    // accumulates to 960-sample frames (queue only)
    private var running = false          // queue only
    private var frameCount = 0           // diagnostics (queue only)

    public init(log: DoorLog? = nil) {
        self.log = log
        super.init()
    }

    public func start() {
        // Request mic permission first; start the engine only once granted.
        requestPermission { [weak self] granted in
            guard let self else { return }
            guard granted else {
                self.log?.warn("phone mic: permission denied")
                self.onState?(.failed("microphone permission denied"))
                return
            }
            self.queue.async { self.startLocked() }
        }
    }

    public func stop() {
        queue.async { [weak self] in self?.stopLocked() }
    }

    // MARK: engine lifecycle (serial queue)

    private func startLocked() {
        guard !running else { return }
        guard encoder.isReady else { onState?(.failed("opus encoder unavailable")); return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .measurement,
                                    options: [.allowBluetooth, .defaultToSpeaker])
            try session.setActive(true, options: [])

            let input = engine.inputNode
            let inFormat = input.inputFormat(forBus: 0)
            guard inFormat.sampleRate > 0,
                  let conv = AVAudioConverter(from: inFormat, to: target48k) else {
                try? session.setActive(false)
                onState?(.failed("no microphone input available"))
                return
            }
            converter = conv
            pending.removeAll(keepingCapacity: true)
            frameCount = 0
            // Tap the raw hardware PCM; we normalise + encode on our serial queue.
            input.installTap(onBus: 0, bufferSize: 1920, format: inFormat) { [weak self] buf, _ in
                self?.ingest(buf)
            }
            engine.prepare()
            try engine.start()
            running = true
            onState?(.streaming)
            log?.info("phone mic: capture started (input \(Int(inFormat.sampleRate))Hz → Opus 48k/960)")
        } catch {
            engine.inputNode.removeTap(onBus: 0)
            try? AVAudioSession.sharedInstance().setActive(false)
            onState?(.failed("mic start failed: \((error as NSError).localizedDescription)"))
        }
    }

    private func stopLocked() {
        guard running else { onState?(.stopped); return }
        running = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        pending.removeAll(keepingCapacity: false)
        converter = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        log?.info("phone mic: capture stopped (\(frameCount) frames)")
        onState?(.stopped)
    }

    // MARK: PCM → 48 kHz mono Int16 → 960-sample Opus frames

    private func ingest(_ input: AVAudioPCMBuffer) {
        // Hop to the serial queue: the tap fires on a realtime render thread, but the
        // converter + accumulator + onFrame must be serial (the FrameRouter relies on a
        // serial source queue to preserve Opus frame order).
        queue.async { [weak self] in
            guard let self, self.running, let conv = self.converter else { return }
            let ratio = self.target48k.sampleRate / input.format.sampleRate
            let cap = AVAudioFrameCount(Double(input.frameLength) * ratio) + 1024
            guard let out = AVAudioPCMBuffer(pcmFormat: self.target48k, frameCapacity: cap) else { return }
            var consumed = false
            var err: NSError?
            let status = conv.convert(to: out, error: &err) { _, outStatus in
                if consumed { outStatus.pointee = .noDataNow; return nil }
                consumed = true
                outStatus.pointee = .haveData
                return input
            }
            guard status != .error, out.frameLength > 0, let ch = out.int16ChannelData else { return }
            let n = Int(out.frameLength)
            self.pending.append(contentsOf: UnsafeBufferPointer(start: ch[0], count: n))
            let fs = OpusEncoder48k.frameSamples
            while self.pending.count >= fs {
                let frame = Array(self.pending.prefix(fs))
                self.pending.removeFirst(fs)
                if let pkt = self.encoder.encode(frame) {
                    self.frameCount += 1
                    self.onFrame?(pkt)
                }
            }
        }
    }

    // MARK: permission

    private func requestPermission(_ done: @escaping (Bool) -> Void) {
        if #available(iOS 17.0, *) {
            AVAudioApplication.requestRecordPermission { granted in done(granted) }
        } else {
            AVAudioSession.sharedInstance().requestRecordPermission { granted in done(granted) }
        }
    }
}

#else

// Non-iOS host (macOS test runner / unsupported platforms): a no-op source so the
// type exists and the app/tests compile. The encoder above is exercised directly.
public final class MicFrameSource: AudioFrameSource, @unchecked Sendable {
    public var onFrame: ((Data) -> Void)?
    public var onState: ((AudioSourceState) -> Void)?
    public init(log: DoorLog? = nil) { _ = log }
    public func start() { onState?(.failed("phone microphone unavailable on this platform")) }
    public func stop() { onState?(.stopped) }
}

#endif
