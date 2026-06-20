// CaptureStatusPoller — drives the conversation card's stage chip by polling the
// door's status endpoint (Phase A, F11/F10). The phone only knows its OWN capture
// id; the door owns the phone→Lore join, so the poller asks
// GET /foundryx/capture/{phone_id}/status and advances the chip:
//   stored → transcribing → transcribed → in_lore → organized
// with `failed` as the terminal-failure state (a retry affordance, not infinite
// "Transcribing…").
//
// Cadence: ~5s, with capped backoff on transport errors, and it STOPS once a
// terminal stage (organized / failed) is reached — an organized capture never
// changes again, so we must not hammer the door for it (F11).

import Foundation

/// The door pipeline stage as the card understands it. Mirrors the door's
/// `stage_str` strings; unknown strings degrade to `.stored` (never crash on a
/// stage the phone doesn't recognise).
public enum CaptureLifecycleStage: String, Sendable, Equatable {
    case recording
    case stored
    case transcribing
    case transcribed
    case inLore = "in_lore"
    case organized
    case failed

    public init(wire: String) {
        self = CaptureLifecycleStage(rawValue: wire) ?? .stored
    }

    /// Terminal stages stop the poll — no further change is expected (F11/F10).
    public var isTerminal: Bool { self == .organized || self == .failed }

    /// The chip label shown on the card. Phase A is stage-only (no title yet).
    public var chipLabel: String {
        switch self {
        case .recording: return "🔴 Recording"
        case .stored: return "💾 Saved"
        case .transcribing: return "📝 Transcribing…"
        case .transcribed: return "📝 Transcribed"
        case .inLore: return "📥 In Lore"
        case .organized: return "🗂️ Organized"
        case .failed: return "⚠️ Transcription failed — retry"
        }
    }

    /// Whether the card should offer a retry affordance (terminal failure, F10).
    public var needsRetry: Bool { self == .failed }
}

/// The status-fetch dependency the poller drives. `DoorClient` is the production
/// conformer; door-free tests inject a stub to drive the stage machine without HTTP.
public protocol CaptureStatusFetching: Sendable {
    func captureStatus(captureId: String) async throws -> CaptureStatusResponse
}

extension DoorClient: CaptureStatusFetching {}

/// Polls one capture's door status until it reaches a terminal stage. Observable so
/// the card binds to `stage` directly. `@MainActor` — it mutates published state and
/// is owned by the timeline.
@MainActor
public final class CaptureStatusPoller: ObservableObject {
    public let captureId: String
    @Published public private(set) var stage: CaptureLifecycleStage
    @Published public private(set) var loreCaptureId: String?

    private let client: CaptureStatusFetching
    private let baseInterval: TimeInterval
    private let maxInterval: TimeInterval
    private var task: Task<Void, Never>?

    public init(captureId: String,
                client: CaptureStatusFetching,
                initialStage: CaptureLifecycleStage = .stored,
                baseInterval: TimeInterval = 5,
                maxInterval: TimeInterval = 60) {
        self.captureId = captureId
        self.client = client
        self.stage = initialStage
        self.baseInterval = baseInterval
        self.maxInterval = maxInterval
    }

    /// Start polling. No-op if already running or already terminal.
    public func start() {
        guard task == nil, !stage.isTerminal else { return }
        task = Task { [weak self] in await self?.loop() }
    }

    /// Stop polling (call from the card's onDisappear).
    public func stop() {
        task?.cancel()
        task = nil
    }

    /// One poll-and-apply, exposed for tests (drives the state machine without a
    /// timer). Returns true once the stage is terminal (the loop should stop).
    @discardableResult
    public func pollOnce() async -> Bool {
        do {
            let resp = try await client.captureStatus(captureId: captureId)
            let next = CaptureLifecycleStage(wire: resp.stage)
            stage = next
            if let id = resp.loreCaptureId { loreCaptureId = id }
            return next.isTerminal
        } catch {
            // Transport / non-2xx (incl. 404 before the door has the manifest) — keep
            // the current stage and let the loop back off + retry.
            return false
        }
    }

    private func loop() async {
        var interval = baseInterval
        while !Task.isCancelled {
            let terminal = await pollOnce()
            if terminal { break }            // organized / failed → stop polling (F11)
            // Healthy poll resets the cadence; a stuck/erroring poll backs off.
            interval = min(interval * 1.5, maxInterval)
            if stage != .stored { interval = baseInterval }  // mid-pipeline → keep snappy
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        }
        task = nil
    }
}
