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
import WhisperKit

public final class WhisperKitSTT: LocalSTT, @unchecked Sendable {
    private let modelName: String
    private var engine: WhisperKit?
    private let engineLock = NSLock()

    public init(model: String = "base") {
        self.modelName = model
    }

    /// WhisperKit runs wherever the app runs (iOS 17+ deployment target); the
    /// model download happens lazily inside `transcribe`.
    public var isAvailable: Bool { true }

    public func transcribe(opusFrames: [Data]) async throws -> String {
        let samples = Self.pcm16k(from: opusFrames)
        guard !samples.isEmpty else { return "" }
        let whisper = try await loadEngine()
        let results = try await whisper.transcribe(audioArray: samples)
        return results.map(\.text).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func loadEngine() async throws -> WhisperKit {
        engineLock.lock()
        let cached = engine
        engineLock.unlock()
        if let cached { return cached }
        let fresh = try await WhisperKit(WhisperKitConfig(model: modelName))
        engineLock.lock()
        engine = fresh
        engineLock.unlock()
        return fresh
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
