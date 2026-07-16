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
    /// Main-actor status sink for the "setting up your private on-device brain"
    /// banner (nil = no UI, e.g. background use). Reported to as download/load
    /// proceed; only ever touched on the main actor.
    private let status: LocalBrainStatus?

    public init(model: String = "base", status: LocalBrainStatus? = nil) {
        self.modelName = model
        self.status = status
    }

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
        do {
            // Download WITH progress into WhisperKit's default cache, then build
            // the engine from that local folder (download:false → no re-fetch).
            // Capture only the (main-actor, Sendable) status — never `self` — so the
            // progress closure is Sendable for WhisperKit's downloader.
            let sink = status
            let folder = try await WhisperKit.download(
                variant: modelName,
                progressCallback: { @Sendable progress in
                    let f = progress.fractionCompleted
                    Task { @MainActor in sink?.setDownloading(f) }
                })
            await report { $0.setLoading() }
            let config = WhisperKitConfig(model: modelName,
                                          modelFolder: folder.path,
                                          download: false)
            let fresh = try await WhisperKit(config)
            engine = fresh
            await report { $0.setReady() }
            return fresh
        } catch {
            await report { $0.setFailed(error.localizedDescription) }
            throw error
        }
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
