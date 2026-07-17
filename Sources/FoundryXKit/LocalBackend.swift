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

/// On-device title + summary over a finished transcript (Phase 3). The real engine
/// is Apple Foundation Models; on phones without Apple-Intelligence hardware
/// `isAvailable` is false and the conversation honestly stays untitled (the
/// upgrade-prompt state, locked decision #2 — no MLX fallback, ever).
public protocol LocalTitleSummary: Sendable {
    var isAvailable: Bool { get }
    func titleAndSummary(for transcript: String) async throws -> (title: String, summary: String)
    /// A TITLE-ONLY refresh for the LIVE rolling title (track 20260717T1015): called
    /// on a debounced cadence mid-recording, so it must not pay for a summary.
    func liveTitle(for transcript: String) async throws -> String
}

public extension LocalTitleSummary {
    /// Default: fall back to the full call (engines that can do better override —
    /// FoundationModelsTitler answers with a single model turn).
    func liveTitle(for transcript: String) async throws -> String {
        try await titleAndSummary(for: transcript).title
    }
}

/// The phone-only brain. Stage vocabulary mirrors the door's (`transcribed` is what
/// the poller/card logic keys on); `ready` once title+summary landed too.
public final class LocalBackend: CaptureBackend, @unchecked Sendable {
    private let baseDir: URL
    private let stt: LocalSTT
    private let titler: LocalTitleSummary?

    public init(baseDir: URL, stt: LocalSTT, titler: LocalTitleSummary? = nil) {
        self.baseDir = baseDir
        self.stt = stt
        self.titler = titler
    }

    /// "Assemble + process" locally: segments → frames → on-device STT → the same
    /// durable stores the door reply path writes (TranscriptCacheStore emits the
    /// `transcript_set` event; the card merge sets the stage). Title + summary are
    /// BEST-EFFORT on top: unavailable or failing Foundation Models never cost the
    /// transcript — the conversation just stays at `transcribed`, untitled.
    public func finalize(captureId: String, meta: ConversationMeta?) async throws {
        guard stt.isAvailable else { throw LocalBackendError.sttUnavailable }
        let frames = Self.loadFrames(captureId: captureId, baseDir: baseDir)
        guard !frames.isEmpty else { throw LocalBackendError.noAudio(captureId) }
        let text = try await stt.transcribe(opusFrames: frames)
        TranscriptCacheStore.save(
            CachedTranscript(transcript: text, title: nil, summary: nil,
                             fetchedAt: UInt64(max(0, Date().timeIntervalSince1970))),
            captureId: captureId, baseDir: baseDir,
            markConfirmed: false)   // on-phone transcript ≠ Lore-confirmed (seed depends on this)
        ConversationCardStore.merge(captureId: captureId, baseDir: baseDir, stage: "transcribed")

        if let titler, titler.isAvailable,
           let (title, summary) = try? await titler.titleAndSummary(for: text) {
            ConversationCardStore.merge(captureId: captureId, baseDir: baseDir,
                                        title: title, summary: summary, stage: "ready")
        }
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
                              summary: card?.summary ?? cached?.summary,
                              segments: cached?.segments ?? [],
                              speakers: cached?.speakers ?? [],
                              paragraphs: cached?.paragraphs ?? [])
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
