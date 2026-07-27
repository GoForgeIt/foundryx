// CaptureBackend — the BRAIN seam (onboarding track 20260705T1100, Phase 1).
// FoundryX is whole without a brain attached: the UI + CaptureManager talk to this
// protocol, never to a concrete door. Implementations:
//   DoorClient    — today's desktop brain over the 3a door (LAN-direct or relay)
//   LocalBackend  — phone-only tier (Phase 2+: WhisperKit STT, Foundation Models)
//   CellBackend   — future hosted cell (same thin-client wire shape as the door)
//
// The surface is deliberately the three calls the capture pipeline actually needs
// from a brain; chat/models/speaker verbs stay on their own seams until a phase
// needs them abstracted.

import Foundation

/// What a "brain" must do for the capture pipeline: accept a finalized capture,
/// report its processing status, and serve its content back.
public protocol CaptureBackend: Sendable {
    /// Close a capture — the brain assembles + processes it (STT, title, summary).
    func finalize(captureId: String, meta: ConversationMeta?) async throws
    /// The brain's processing status for a capture (stage, title, summary).
    func captureStatus(captureId: String) async throws -> CaptureStatusResponse
    /// The full processed content (transcript + title + summary).
    func captureContent(captureId: String) async throws -> CaptureContent
}

/// The desktop brain: DoorClient already speaks this surface verbatim.
extension DoorClient: CaptureBackend {}

extension CaptureManager {
    /// Build a CaptureManager whose finalize/content paths run through a
    /// `CaptureBackend` instead of raw closures — the Phase 1 seam call sites
    /// migrate onto ("just my phone" ⇒ a LocalBackend here, no door anywhere).
    /// `localMode: true` = the phone IS the durable store: per-segment "uploads"
    /// succeed immediately (the WAL's ack then means "durably on this phone"),
    /// which lets the existing finalize gate fire with no door anywhere. On a
    /// later brain connect, BrainSeeder drops these local acks so the drain
    /// re-uploads everything for real (Phase 7).
    @MainActor
    public convenience init(target: DoorTarget,
                            backend: CaptureBackend,
                            baseDir: URL? = nil,
                            log: DoorLog? = nil,
                            source: AudioFrameSource,
                            micSource: AudioFrameSource? = nil,
                            attachToSourcesImmediately: Bool = true,
                            locationProvider: ConversationLocationProviding? = nil,
                            liveTranscriber: LiveTranscriberFactory? = nil,
                            liveTitler: LocalTitleSummary? = nil,
                            liveTitleExternal: (@Sendable (String, String, Int) async throws -> String?)? = nil,
                            liveTitleBackoff: LiveTitleBackoff = .default,
                            localMode: Bool = false) {
        self.init(target: target,
                  baseDir: baseDir,
                  log: log,
                  source: source,
                  micSource: micSource,
                  attachToSourcesImmediately: attachToSourcesImmediately,
                  finalize: { captureId, meta in
                      try await backend.finalize(captureId: captureId, meta: meta)
                  },
                  fetchContent: { captureId in
                      try? await backend.captureContent(captureId: captureId)
                  },
                  locationProvider: locationProvider,
                  liveTranscriber: liveTranscriber,
                  liveTitler: liveTitler,
                  // External live-title stays OFF in "just my phone" mode by default (the
                  // on-device placeholder stands offline); the DEBUG proof harness injects
                  // a scripted external to demonstrate the sharpen in the simulator.
                  liveTitleExternal: liveTitleExternal,
                  liveTitleBackoff: liveTitleBackoff,
                  uploadSegment: localMode ? { @Sendable _, _, _ in } : nil)
    }
}
