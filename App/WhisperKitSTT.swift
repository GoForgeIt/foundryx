// WhisperKitSTT — the REAL on-device speech engine behind the LocalSTT seam
// (onboarding track 20260705T1100, Phase 2; locked decision #2: WhisperKit for STT
// on essentially every modern iPhone — no MLX fallback anywhere).
//
// Pipeline: stored Opus frames → OpusPCMDecoder (48 kHz mono Int16, the same
// decoder the live-preview path uses) → AVAudioConverter down to WhisperKit's
// 16 kHz Float mono → WhisperKit.transcribe. The model (base) is fetched on first
// use — "setting up your private on-device brain"; model weights are the ONLY
// bytes that ever come IN, and no audio ever goes OUT.
//
// Lives in the App target (not FoundryXKit/SPM) so `swift test` never builds
// WhisperKit; tests drive the LocalSTT seam with a fake.

import Foundation
import AVFoundation
#if canImport(WhisperKit)
@preconcurrency import WhisperKit

public actor WhisperKitSTT: LocalSTT {
    private let modelName: String
    private var engine: WhisperKit?
    /// The folder the weights landed in — kept between the download and build steps so
    /// a retry never re-fetches bytes that are already on disk.
    private var downloadedFolder: URL?
    /// Main-actor status sink for the "setting up your private on-device brain"
    /// banner (nil = no UI, e.g. background use). Reported to as download/load
    /// proceed; only ever touched on the main actor.
    private let status: LocalBrainStatus?
    /// How long the setup may be STUCK before it fails honestly (track 20260722T1244).
    private let policy: BrainSetupPolicy

    public init(model: String = "base",
                status: LocalBrainStatus? = nil,
                policy: BrainSetupPolicy = .default) {
        self.modelName = model
        self.status = status
        self.policy = policy
    }

    /// Bounded, honest setup: the download is stall-watched (progress that stops
    /// ADVANCING for `stallTimeout` fails), the build is time-bounded, and a failure
    /// installs a working "Try again" on the banner — no relaunch. A slow-but-moving
    /// download is never killed.
    private lazy var preparer: LocalBrainPreparer = LocalBrainPreparer(
        steps: LocalBrainPreparer.Steps(
            download: { [self] onProgress in try await self.downloadWeights(onProgress) },
            build: { [self] in try await self.buildEngine() }),
        policy: policy,
        status: status)

    /// WhisperKit runs wherever the app runs (iOS 17+ deployment target); the
    /// model download happens on first need (or an explicit `prewarm`).
    public nonisolated var isAvailable: Bool { true }

    /// Kick the model fetch/load NOW (call when the phone tier mounts) so the
    /// first recording isn't the first time ~150 MB downloads. Idempotent; safe to
    /// call repeatedly. Failures are surfaced on the banner, never fatal — the
    /// next transcribe retries.
    public func prewarm() async {
        _ = try? await loadEngine()
    }

    enum WhisperKitSTTError: Error, LocalizedError {
        case engineUnavailable
        public var errorDescription: String? { "the on-device speech model isn't ready" }
    }

    public func transcribe(opusFrames: [Data]) async throws -> String {
        try await PerfHook.timed("whisper-stt") {
            let samples = Self.pcm16k(from: opusFrames)
            guard !samples.isEmpty else { return "" }
            let whisper = try await self.loadEngine()
            let results = try await whisper.transcribe(audioArray: samples)
            return results.map(\.text).joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private func loadEngine() async throws -> WhisperKit {
        if let engine {
            await report { $0.setReady() }
            return engine
        }
        // The preparer owns the phases, the stall watchdog, and the failure/retry
        // reporting; it throws if setup timed out, so the banner is never immortal.
        try await preparer.prepare()
        guard let engine else { throw WhisperKitSTTError.engineUnavailable }
        return engine
    }

    /// Download WITH progress into WhisperKit's default cache. Reports every real
    /// fraction so the stall watchdog can tell "slow" from "stuck".
    private func downloadWeights(_ onProgress: @escaping @Sendable (Double) -> Void) async throws {
        if downloadedFolder != nil { return }   // already on disk (e.g. a retry)
        downloadedFolder = try await WhisperKit.download(
            variant: modelName,
            progressCallback: { @Sendable progress in onProgress(progress.fractionCompleted) })
    }

    /// Build the engine from the local folder (download:false → no re-fetch).
    private func buildEngine() async throws {
        if engine != nil { return }
        let config = WhisperKitConfig(model: modelName,
                                      modelFolder: downloadedFolder?.path,
                                      download: false)
        engine = try await WhisperKit(config)
    }

    private func report(_ body: @escaping @MainActor (LocalBrainStatus) -> Void) async {
        guard let status else { return }
        await MainActor.run { body(status) }
    }

    /// Opus frames → 16 kHz mono Float samples (WhisperKit's input format).
    /// Decode at the canonical 48 kHz (the proven OpusPCMDecoder path), then
    /// resample 48k Int16 → 16k Float through AVAudioConverter.
    static func pcm16k(from opusFrames: [Data]) -> [Float] {
        let decoder = OpusPCMDecoder()
        let inFormat = decoder.format                              // 48k mono Int16
        guard let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                            sampleRate: 16_000, channels: 1,
                                            interleaved: false),
              let converter = AVAudioConverter(from: inFormat, to: outFormat) else { return [] }
        var out: [Float] = []
        for frame in opusFrames {
            guard let pcm48 = decoder.decode(frame), pcm48.frameLength > 0 else { continue }
            let capacity = AVAudioFrameCount((Double(pcm48.frameLength) / 3.0).rounded(.up) + 16)
            guard let pcm16 = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { continue }
            var fed = false
            var err: NSError?
            converter.convert(to: pcm16, error: &err) { _, outStatus in
                if fed { outStatus.pointee = .noDataNow; return nil }
                fed = true
                outStatus.pointee = .haveData
                return pcm48
            }
            if err == nil, pcm16.frameLength > 0, let ch = pcm16.floatChannelData {
                out.append(contentsOf: UnsafeBufferPointer(start: ch[0], count: Int(pcm16.frameLength)))
            }
        }
        return out
    }
}
#endif
