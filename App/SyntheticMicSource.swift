// SyntheticMicSource — the DEV-only frame source that makes the phone-mic recording
// proof DETERMINISTIC in the simulator (track 20260722T1601, `-SyntheticMic`).
//
// WHY IT EXISTS (the measured root cause, not a guess). In the iOS simulator
// `AVAudioEngine.inputNode.inputFormat(forBus: 0)` returns a DEGENERATE format —
// `rate=0.0 ch=0` — even with microphone privacy pre-granted and
// `AVAudioSession.isInputAvailable == true` (1 available input). `MicFrameSource`
// correctly refuses to tap a 0 Hz input and emits
// `.failed("no microphone input available")`; `CaptureManager.onSourceState` then
// resets `isRecordingMic` back to false, so the full-screen recording surface —
// whose `fullScreenCover` binding is `(isRecordingMic || active != nil) &&
// !recordingScreenMinimized` — tears down in the same runloop turn it presented.
// That is a SIMULATOR-ENVIRONMENT limitation, not an app defect: on a real device
// the input node reports a real format and the surface presents.
//
// WHAT IT DOES. It is a real `AudioFrameSource`: it synthesises 48 kHz mono PCM and
// runs it through the SAME `OpusEncoder48k` the phone mic uses, emitting one 20 ms
// Opus packet per `onFrame` at realtime cadence — byte-shape-identical to what the
// mic (and the Omi) deliver. So everything downstream is the REAL path: FrameRouter →
// level meter → SilenceSegmenter → `beginSession` → CaptureWAL → finalize, plus the
// live-title pipeline. Nothing about the recording surface, the session clock, the
// meter or the live text is mocked — only the microphone hardware is stood in for.
//
// TEST-ONLY. The whole file is `#if DEBUG || PERF_HARNESS`, and RootView only substitutes
// it when the process was launched with `-SyntheticMic`. Plain Release builds cannot reach
// it (proven by BINARY in `scripts/ci-gates.sh leak`, which fails if the launch-argument
// string appears in the shipping executable), and a normal DEBUG launch without the
// argument still gets the real `MicFrameSource`.
//
// PERF_HARNESS was added for the perf gate (track 20260722T1244): sim-perf builds the
// PerfRelease configuration, in which the record-start leg of `PerfBudgetNavUITests` could
// NEVER present — the simulator's AVAudioEngine input node reports a degenerate
// `rate=0.0 ch=0` format, so the real MicFrameSource correctly refuses. The nav gate was
// therefore red on its record leg for reasons that had nothing to do with performance.

#if DEBUG || PERF_HARNESS
import Foundation

final class SyntheticMicFrameSource: AudioFrameSource, @unchecked Sendable {
    var onFrame: ((Data) -> Void)?
    var onState: ((AudioSourceState) -> Void)?

    /// 20 ms Opus frames per timer tick. One tick per 100 ms → 5 frames = 100 ms of
    /// audio, i.e. realtime, so the WAL/segmenter/meter see the same frame rate the
    /// mic produces (and the elapsed clock and audio duration agree).
    private static let framesPerTick = 5
    private static let tickMillis = 100

    private let log: DoorLog?
    private let encoder = OpusEncoder48k()
    /// Serial emit queue — `FrameRouter.route` assumes a serial source callback queue,
    /// exactly as `MicFrameSource`'s encode queue guarantees.
    private let queue = DispatchQueue(label: "foundryx.synthetic-mic")
    private var timer: DispatchSourceTimer?
    private var running = false     // queue only
    private var phase: Double = 0   // queue only — carrier phase, seconds

    init(log: DoorLog? = nil) { self.log = log }

    func start() {
        queue.async { [self] in
            guard !running else { return }
            guard encoder.isReady else {
                onState?(.failed("opus encoder unavailable"))
                return
            }
            running = true
            onState?(.streaming)
            log?.info("synthetic mic: engine live (-SyntheticMic harness, 48k/960 Opus)")
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now(), repeating: .milliseconds(Self.tickMillis))
            t.setEventHandler { [weak self] in self?.emitTick() }
            timer = t
            t.resume()
        }
    }

    func stop() {
        queue.async { [self] in
            guard running else { onState?(.stopped); return }
            running = false
            timer?.cancel()
            timer = nil
            log?.info("synthetic mic: capture stopped")
            onState?(.stopped)
        }
    }

    // MARK: signal

    /// One tick = `framesPerTick` × 20 ms of synthetic voiced audio, Opus-encoded and
    /// emitted frame by frame. The signal is a 220 Hz carrier under a 3 Hz amplitude
    /// envelope — voiced-band energy that reads on the OpusLevelMeter's perceptual
    /// scale well above `SilenceSegmenter.silenceThreshold` (0.06), so the segmenter
    /// keeps the conversation open and the meter ring visibly moves.
    private func emitTick() {
        guard running else { return }
        let n = OpusEncoder48k.frameSamples
        for _ in 0..<Self.framesPerTick {
            var samples = [Int16](repeating: 0, count: n)
            for i in 0..<n {
                let envelope = 0.45 + 0.35 * sin(2 * .pi * 3 * phase)
                let value = sin(2 * .pi * 220 * phase) * envelope
                samples[i] = Int16(max(-1, min(1, value)) * 11000)
                phase += 1.0 / 48000.0
            }
            if let packet = encoder.encode(samples) { onFrame?(packet) }
        }
    }
}
#endif
