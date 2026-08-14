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

/// ACCUMULATE 48 kHz MONO Int16 AND EMIT ONE OPUS PACKET PER 960 SAMPLES.
///
/// This is the single home of "PCM becomes the frames the pipeline speaks". It was lifted out
/// of `MicFrameSource.ingest` verbatim — the `pending` accumulator plus the
/// `while pending.count >= frameSamples` drain — because a SECOND producer of pipeline frames
/// now exists (`PocketAudioTranslator`, which decodes a file a recorder handed over), and two
/// copies of the framing rule is how two producers drift into two subtly different framings
/// that the door's TOC-based granule parser then reads differently.
///
/// Everything downstream — `CaptureWAL.encodeSegment`, the door's `mux_ogg_opus`, Lore's STT —
/// therefore cannot tell a microphone from a brought-over file, which is the entire point.
///
/// NOT thread-safe. `MicFrameSource` drives it on its serial encode queue; the translator
/// drives it on one call stack.
public final class Opus48kFramePacker {
    private let encoder: OpusEncoder48k
    private var pending: [Int16] = []

    public init(encoder: OpusEncoder48k = OpusEncoder48k()) {
        self.encoder = encoder
    }

    public var isReady: Bool { encoder.isReady }

    /// How many packets this packer has emitted. Diagnostics + the translator's return value.
    public private(set) var packetsEmitted = 0

    public func reset() {
        pending.removeAll(keepingCapacity: true)
    }

    /// Append samples and emit every COMPLETE 20 ms packet they now make up. A partial tail
    /// stays buffered for the next call.
    public func append(_ samples: UnsafeBufferPointer<Int16>, emit: (Data) -> Void) {
        pending.append(contentsOf: samples)
        drain(emit: emit)
    }

    /// Append samples from an array. Same rule, for callers that already hold one.
    public func append(_ samples: [Int16], emit: (Data) -> Void) {
        pending.append(contentsOf: samples)
        drain(emit: emit)
    }

    /// ZERO-PAD THE TAIL AND EMIT IT. Only a FINISHED source may call this: a live stream's
    /// buffered tail belongs to the frame that has not arrived yet, so `MicFrameSource` never
    /// calls it. A file, by contrast, has a real last 3 milliseconds, and dropping them
    /// silently is audio the owner recorded and this app threw away.
    public func flush(emit: (Data) -> Void) {
        guard !pending.isEmpty else { return }
        let fs = OpusEncoder48k.frameSamples
        pending.append(contentsOf: repeatElement(0, count: fs - pending.count % fs))
        drain(emit: emit)
    }

    private func drain(emit: (Data) -> Void) {
        let fs = OpusEncoder48k.frameSamples
        while pending.count >= fs {
            let frame = Array(pending.prefix(fs))
            pending.removeFirst(fs)
            if let packet = encoder.encode(frame) {
                packetsEmitted += 1
                emit(packet)
            }
        }
    }
}

#if os(iOS) && canImport(AVFoundation)

/// The phone microphone as an AudioFrameSource (iOS). `start()` requests mic
/// permission, configures the record audio session, taps the input node, normalises
/// to 48 kHz mono Int16, Opus-encodes 20 ms frames, and emits them through `onFrame`
/// — exactly the Omi stream shape. `stop()` tears the engine down and emits `.stopped`
/// (which finalizes the capture through the normal path).
public final class MicFrameSource: NSObject, AccountAudioSourceExposure, @unchecked Sendable {
    public var onFrame: ((Data) -> Void)?
    public var onState: ((AudioSourceState) -> Void)?
    /// Optional DIRECT decoded-PCM tap for live transcription (Feature 2): the already-
    /// normalised 48 kHz mono PCM, handed off BEFORE Opus encoding so the on-device
    /// recognizer never waits on an encode→decode round-trip. Fired on the serial encode
    /// queue (same ordering guarantee as `onFrame`). nil ⇒ no direct tap (the live
    /// preview falls back to the FrameRouter's Opus-decode tap).
    public var onPCM: ((AVAudioPCMBuffer) -> Void)?

    /// Input-tap buffer size (frames). ~20 ms at a 48 kHz hardware input — small so the
    /// direct live-STT PCM tap fires often (lower live-transcription latency, Feature 1)
    /// while staying above the realtime-render minimum. Reduced from 1920 (~40 ms).
    private static let tapBufferSize: AVAudioFrameCount = 1024

    private let log: DoorLog?
    private let engine = AVAudioEngine()
    /// THE SHARED FRAMER, not a private accumulator. A brought-over file goes through the same
    /// type, so a Pocket import and a phone-mic recording produce byte-identical framing.
    private let packer = Opus48kFramePacker()
    private let target48k = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                          sampleRate: 48000, channels: 1, interleaved: true)!
    private var converter: AVAudioConverter?
    /// Serial encode queue — keeps `onFrame` ordered (the FrameRouter assumes a serial
    /// source callback queue) and the Int16 accumulator single-threaded.
    private let queue = DispatchQueue(label: "foundryx.mic-source")
    private var running = false          // queue only — the user's INTENT to record
    private var engineLive = false       // queue only — the AVAudioEngine is actually tapping
    private var interrupted = false      // queue only — paused by an OS audio interruption
    private var frameCount = 0           // diagnostics (queue only)
    private let exposureLock = NSLock()
    private var accountExposureClosed = false // exposureLock only

    public init(log: DoorLog? = nil) {
        self.log = log
        super.init()
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    public func start() {
        guard !isAccountExposureClosed else { return }
        // Request mic permission first; start the engine only once granted.
        requestPermission { [weak self] granted in
            guard let self else { return }
            self.queue.async {
                guard !self.isAccountExposureClosed else { return }
                guard granted else {
                    self.log?.warn("phone mic: permission denied")
                    self.emitState(.failed("microphone permission denied"))
                    return
                }
                self.startLocked()
            }
        }
    }

    public func stop() {
        queue.async { [weak self] in self?.stopLocked() }
    }

    public func closeAudioExposure() async -> AccountExposureCloseResult {
        guard claimAccountExposureClose() else { return .alreadyClosed }
        return await withCheckedContinuation {
            (continuation:
                CheckedContinuation<AccountExposureCloseResult, Never>) in
            queue.async {
                self.stopLocked(terminalNotification: true)
                continuation.resume(returning: .closed)
            }
        }
    }

    // MARK: engine lifecycle (serial queue)

    private func startLocked() {
        guard !isAccountExposureClosed else { return }
        guard !running else { return }
        guard packer.isReady else {
            emitState(.failed("opus encoder unavailable"))
            return
        }
        running = true
        interrupted = false
        // Observe OS audio-session interruptions (phone calls, Siri, other apps),
        // route changes (BT connect/disconnect, unplug), and media-server resets —
        // ANY of which stops the engine's input tap. Without these the recording
        // silently dies mid-conversation and never resumes (the phone-call data-loss
        // bug). Registered once per start; torn down on stop.
        registerAudioObservers()
        if !activateEngine() { running = false; tearDownAudioObservers() }
    }

    /// Activate the session + tap + engine. Reusable for BOTH the initial start and an
    /// auto-resume after an interruption/reset — resuming re-taps into the SAME capture
    /// (the WAL keeps every frame captured before the interruption). Returns whether the
    /// engine is live; on failure emits `.failed` so the capture can finalize its partial.
    @discardableResult
    private func activateEngine() -> Bool {
        guard !isAccountExposureClosed,
              running,
              !engineLive else { return engineLive }
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
                emitState(.failed("no microphone input available"))
                return false
            }
            converter = conv
            packer.reset()
            input.removeTap(onBus: 0)   // defensive: never stack taps on a resume
            // Tap the raw hardware PCM; we normalise + encode on our serial queue.
            input.installTap(onBus: 0, bufferSize: Self.tapBufferSize, format: inFormat) { [weak self] buf, _ in
                self?.ingest(buf)
            }
            engine.prepare()
            try engine.start()
            engineLive = true
            emitState(.streaming)
            log?.info("phone mic: engine live (input \(Int(inFormat.sampleRate))Hz → Opus 48k/960)")
            return true
        } catch {
            engine.inputNode.removeTap(onBus: 0)
            try? AVAudioSession.sharedInstance().setActive(false)
            emitState(.failed(
                "mic start failed: \((error as NSError).localizedDescription)"))
            return false
        }
    }

    /// Tear down the live engine WITHOUT ending the user's record intent — used on an
    /// interruption so the call gets the audio session while the capture stays "open"
    /// (its already-captured frames are durable in the WAL) and can resume.
    private func deactivateEngine(releaseSession: Bool) {
        guard engineLive else { return }
        engineLive = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        packer.reset()
        converter = nil
        if releaseSession {
            try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        }
    }

    private func stopLocked(terminalNotification: Bool = false) {
        guard running else {
            emitState(.stopped, terminal: terminalNotification)
            return
        }
        running = false
        interrupted = false
        tearDownAudioObservers()
        deactivateEngine(releaseSession: true)
        log?.info("phone mic: capture stopped (\(frameCount) frames)")
        frameCount = 0
        emitState(.stopped, terminal: terminalNotification)
    }

    // MARK: interruption / route-change / reset resilience

    private func registerAudioObservers() {
        let nc = NotificationCenter.default
        nc.removeObserver(self)
        nc.addObserver(self, selector: #selector(handleInterruption(_:)),
                       name: AVAudioSession.interruptionNotification, object: nil)
        nc.addObserver(self, selector: #selector(handleRouteChange(_:)),
                       name: AVAudioSession.routeChangeNotification, object: nil)
        nc.addObserver(self, selector: #selector(handleMediaReset(_:)),
                       name: AVAudioSession.mediaServicesWereResetNotification, object: nil)
        nc.addObserver(self, selector: #selector(handleEngineConfigChange(_:)),
                       name: .AVAudioEngineConfigurationChange, object: engine)
    }

    private func tearDownAudioObservers() {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func handleInterruption(_ note: Notification) {
        guard let info = note.userInfo,
              let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        queue.async { [weak self] in
            guard let self, self.running else { return }
            switch type {
            case .began:
                // A call/Siri/other app grabbed audio. Release the engine so the OS is
                // happy; KEEP the capture open. Everything captured so far is already
                // durable in the WAL — nothing is lost.
                self.interrupted = true
                self.deactivateEngine(releaseSession: false)
                self.log?.warn("phone mic: interrupted (call/Siri) — paused, audio preserved, will resume")
            case .ended:
                // Resume capture into the SAME conversation. iOS sets shouldResume when
                // the interruption cleanly ended; we resume regardless (best-effort) so
                // the user's recording keeps going.
                self.interrupted = false
                self.restartEngine(reason: "interruption ended")
            @unknown default:
                break
            }
        }
    }

    @objc private func handleRouteChange(_ note: Notification) {
        // A route change (BT (dis)connect, unplug) can silence the input node. Rebuild
        // the tap so capture continues on the new route rather than going quiet.
        queue.async { [weak self] in
            self?.restartEngine(reason: "route change")
        }
    }

    @objc private func handleEngineConfigChange(_ note: Notification) {
        queue.async { [weak self] in
            self?.restartEngine(reason: "config change")
        }
    }

    @objc private func handleMediaReset(_ note: Notification) {
        // mediaservicesd reset invalidates the whole audio stack — rebuild from scratch.
        // Bypasses the debounce: after a REAL media-services reset the old engine is
        // dead; keeping it "up" would just record silence.
        queue.async { [weak self] in
            guard let self, self.running else { return }
            self.interrupted = false
            self.restartEngine(reason: "media-services reset", bypassDebounce: true)
        }
    }

    /// Last engine restart (monotonic seconds). Restarting the engine ITSELF fires
    /// AVAudioEngineConfigurationChange (and can fire route-change), so an
    /// unconditional restart from ANY observer becomes a self-sustaining ~2 Hz
    /// restart loop (the 2026-07-12 "engine live" diag storm that gap-mangled mic
    /// recordings — build 142 debounced only the config-change path and the storm
    /// survived through the route-change/media-reset paths). Debounce hard, in ONE
    /// place, for every restart trigger.
    private var lastEngineRestart: TimeInterval = 0

    /// The ONE funnel through which every "audio stack changed — rebuild the engine"
    /// event goes (config change, route change, media-services reset, interruption
    /// ended). Serial-queue only. Behaviour:
    ///   • not running / interrupted → no-op (the interruption .began path already
    ///     tore the engine down on purpose).
    ///   • engine NOT live (e.g. resuming after an interruption) → straight
    ///     (re)activate; there is nothing to keep "up", so no debounce applies.
    ///   • engine live → tear down + rebuild, DEBOUNCED to one restart per 2 s
    ///     (`bypassDebounce` for media-services resets, where the live engine is a
    ///     zombie). The reason is logged either way so the next diag read names
    ///     exactly which notification is driving any storm.
    private func restartEngine(reason: String, bypassDebounce: Bool = false) {
        guard !isAccountExposureClosed, running, !interrupted else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard engineLive else {
            // Engine already down — this is a resume/recovery, not churn.
            lastEngineRestart = now
            log?.info("phone mic: engine restart (\(reason))")
            if !activateEngine() {
                log?.error("phone mic: engine restart (\(reason)) FAILED")
            }
            return
        }
        guard bypassDebounce || now - lastEngineRestart > 2.0 else {
            log?.info("phone mic: \(reason) within debounce — engine stays up")
            return
        }
        lastEngineRestart = now
        log?.info("phone mic: engine restart (\(reason))")
        deactivateEngine(releaseSession: false)
        if !activateEngine() {
            log?.error("phone mic: engine restart (\(reason)) FAILED")
        }
    }

    // MARK: PCM → 48 kHz mono Int16 → 960-sample Opus frames

    private func ingest(_ input: AVAudioPCMBuffer) {
        // Hop to the serial queue: the tap fires on a realtime render thread, but the
        // converter + accumulator + onFrame must be serial (the FrameRouter relies on a
        // serial source queue to preserve Opus frame order).
        queue.async { [weak self] in
            guard let self,
                  !self.isAccountExposureClosed,
                  self.running,
                  let conv = self.converter else { return }
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
            // Direct live-STT tap: hand the freshly-normalised PCM straight to the
            // recognizer (no Opus round-trip), BEFORE we encode it for the durable WAL.
            self.emitPCM(out)
            let n = Int(out.frameLength)
            // NO `flush()` HERE, and that is deliberate: a live stream's buffered tail belongs
            // to the 20 ms frame that has not finished arriving. Only a finished FILE flushes.
            self.packer.append(UnsafeBufferPointer(start: ch[0], count: n)) { pkt in
                self.frameCount += 1
                self.emitFrame(pkt)
            }
        }
    }

    private var isAccountExposureClosed: Bool {
        exposureLock.lock()
        defer { exposureLock.unlock() }
        return accountExposureClosed
    }

    private func claimAccountExposureClose() -> Bool {
        exposureLock.lock()
        defer { exposureLock.unlock() }
        guard !accountExposureClosed else { return false }
        accountExposureClosed = true
        return true
    }

    private func emitState(
        _ state: AudioSourceState,
        terminal: Bool = false
    ) {
        guard terminal || !isAccountExposureClosed else { return }
        onState?(state)
    }

    private func emitFrame(_ frame: Data) {
        guard !isAccountExposureClosed else { return }
        onFrame?(frame)
    }

    private func emitPCM(_ buffer: AVAudioPCMBuffer) {
        guard !isAccountExposureClosed else { return }
        onPCM?(buffer)
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
public final class MicFrameSource: AccountAudioSourceExposure, @unchecked Sendable {
    public var onFrame: ((Data) -> Void)?
    public var onState: ((AudioSourceState) -> Void)?
    private let exposureLock = NSLock()
    private let exposureEmissions = DispatchGroup()
    private var exposureClosed = false
    #if canImport(AVFoundation)
    /// Parity with the iOS source's direct-PCM tap (unused on this host platform).
    public var onPCM: ((AVAudioPCMBuffer) -> Void)?
    #endif
    public init(log: DoorLog? = nil) { _ = log }
    public func start() {
        exposureLock.lock()
        let closed = exposureClosed
        exposureLock.unlock()
        guard !closed else { return }
        emitState(.failed("phone microphone unavailable on this platform"))
    }
    public func stop() { emitState(.stopped) }
    public func closeAudioExposure() async -> AccountExposureCloseResult {
        guard claimExposureClose() else { return .alreadyClosed }
        await withCheckedContinuation { continuation in
            exposureEmissions.notify(queue: .global()) {
                continuation.resume()
            }
        }
        emitState(.stopped, terminal: true)
        return .closed
    }

    private func claimExposureClose() -> Bool {
        exposureLock.lock()
        defer { exposureLock.unlock() }
        guard !exposureClosed else { return false }
        exposureClosed = true
        return true
    }

    private func emitState(
        _ state: AudioSourceState,
        terminal: Bool = false
    ) {
        exposureLock.lock()
        let closed = exposureClosed
        if terminal || !closed { exposureEmissions.enter() }
        exposureLock.unlock()
        guard terminal || !closed else { return }
        defer { exposureEmissions.leave() }
        onState?(state)
    }
}

#endif
