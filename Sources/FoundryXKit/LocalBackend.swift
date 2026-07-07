// LocalBackend — the "Just my phone" brain (onboarding track 20260705T1100, Phase 2).
// A CaptureBackend that never dials anywhere: finalize reads the capture's own WAL
// segments off disk, transcribes them with an on-device STT engine, and persists the
// transcript through the SAME stores the door path uses (so the event log, card, and
// detail view all behave identically whichever brain is attached). Status + content
// are served from those local stores.
//
// The STT engine is a seam (`LocalSTT`) so the pipeline is testable hermetically;
// the real engine is WhisperKit (locked decision #2 — WhisperKit runs on essentially
// every modern iPhone; title/summary/chat come from Foundation Models in Phase 3).

import Foundation

/// On-device speech-to-text over a finished capture's raw Opus frames.
public protocol LocalSTT: Sendable {
    /// Whether the engine can run here (model present, OS support). An unavailable
    /// engine makes `LocalBackend.finalize` throw — the capture stays pending and
    /// retries later (same ethos as a door that's down).
    var isAvailable: Bool { get }
    /// Transcribe the conversation's Opus frames (in capture order) to plain text.
    func transcribe(opusFrames: [Data]) async throws -> String
}

public enum LocalBackendError: Error, Equatable {
    case sttUnavailable
    case noAudio(String)
}

/// The phone-only brain. Stage vocabulary mirrors the door's (`transcribed` is what
/// the poller/card logic keys on), with `on_phone` marking where processing ran.
public final class LocalBackend: CaptureBackend, @unchecked Sendable {
    private let baseDir: URL
    private let stt: LocalSTT

    public init(baseDir: URL, stt: LocalSTT) {
        self.baseDir = baseDir
        self.stt = stt
    }

    /// "Assemble + process" locally: segments → frames → on-device STT → the same
    /// durable stores the door reply path writes (TranscriptCacheStore emits the
    /// `transcript_set` event; the card merge sets the stage).
    public func finalize(captureId: String, meta: ConversationMeta?) async throws {
        guard stt.isAvailable else { throw LocalBackendError.sttUnavailable }
        let frames = Self.loadFrames(captureId: captureId, baseDir: baseDir)
        guard !frames.isEmpty else { throw LocalBackendError.noAudio(captureId) }
        let text = try await stt.transcribe(opusFrames: frames)
        TranscriptCacheStore.save(
            CachedTranscript(transcript: text, title: nil, summary: nil,
                             fetchedAt: UInt64(max(0, Date().timeIntervalSince1970))),
            captureId: captureId, baseDir: baseDir)
        ConversationCardStore.merge(captureId: captureId, baseDir: baseDir, stage: "transcribed")
    }

    public func captureStatus(captureId: String) async throws -> CaptureStatusResponse {
        let card = ConversationCardStore.load(captureId: captureId, baseDir: baseDir)
        let transcribed = TranscriptCacheStore.hasCachedTranscript(captureId: captureId, baseDir: baseDir)
        return CaptureStatusResponse(stage: card?.stage ?? "on_phone",
                                     loreCaptureId: nil,
                                     transcribed: transcribed,
                                     title: card?.title,
                                     summary: card?.summary)
    }

    public func captureContent(captureId: String) async throws -> CaptureContent {
        let cached = TranscriptCacheStore.load(captureId: captureId, baseDir: baseDir)
        let card = ConversationCardStore.load(captureId: captureId, baseDir: baseDir)
        let capturedAt = ConversationMetaStore.load(captureId: captureId, baseDir: baseDir)?.startedAt
            ?? card?.startedAt ?? 0
        return CaptureContent(transcript: cached?.transcript ?? "",
                              capturedAt: Int(capturedAt),
                              found: cached != nil,
                              title: card?.title ?? cached?.title,
                              summary: card?.summary ?? cached?.summary)
    }

    /// All of a capture's Opus frames, in segment order, split back out of the
    /// length-prefixed WAL segment files.
    static func loadFrames(captureId: String, baseDir: URL) -> [Data] {
        let dir = baseDir.appendingPathComponent(captureId, isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.pathExtension == "opus" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }   // seg-%012llu sorts lexically
            .flatMap { (try? Data(contentsOf: $0)).map(CaptureWAL.decodeSegment) ?? [] }
    }
}
