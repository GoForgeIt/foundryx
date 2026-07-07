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

/// The calm, human "what's happening to this conversation" chip shown on each card
/// (track 20260626). Distinct from `CaptureLifecycleStage` (the raw door wire stage):
/// this folds the LOCAL WAL sync stage and the door pipeline stage into one ordered,
/// user-legible progression so the user can SEE motion rather than a flat "Saved".
///
///   Recording → Saved on phone → Saved to computer → Transcribing… → Ready
///
/// `failed` is the terminal-failure chip. Pure + unit-tested via `resolve`.
public enum ConversationProgress: String, Sendable, Equatable {
    case recording          // mic live, frames arriving
    case savedOnPhone       // ≥1 segment durable on the phone, not all ACK'd yet
    case savedToComputer    // every segment ACK'd; door hasn't reported Lore progress yet
    case transcribing       // reached the desktop/Lore; transcript still cooking
    case ready              // transcript/title available — openable
    case failed             // terminal transcription failure (retry affordance)

    /// The calm chip label.
    public var label: String {
        switch self {
        case .recording: return "Recording"
        case .savedOnPhone: return "Saved on phone"
        case .savedToComputer: return "Saved to computer"
        case .transcribing: return "Transcribing…"
        case .ready: return "Ready"
        case .failed: return "Transcription failed — retry"
        }
    }

    /// Whether the card should offer a retry affordance.
    public var needsRetry: Bool { self == .failed }

    /// A specific, honest failure line derived from Lore's terminal drop reason —
    /// shown on a `.failed` card instead of the generic chip. `nil` when there's no
    /// specific reason (falls back to the generic label).
    public static func failureMessage(droppedReason: String?) -> String? {
        switch droppedReason {
        case "silent_no_transcript", "noise", "junk_purge": return "No speech detected"
        case "key_lost": return "Audio couldn't be recovered"
        case .some(let r) where !r.isEmpty: return "Couldn't transcribe (\(r))"
        default: return nil
        }
    }

    /// Whether retrying is actually useful. A terminal Lore DROP (silent/noise/junk/
    /// key-lost) is Lore's final verdict — retry can't change it — so a dropped card
    /// shows the honest reason with NO retry. A `.failed` with no drop reason (an
    /// engine/transport failure) keeps retry.
    public static func retryUseful(droppedReason: String?) -> Bool {
        droppedReason == nil
    }

    /// Derive the card's progress from the local WAL stage, whether the source is
    /// still streaming, the door's pipeline stage, whether a Kiln title is known, and
    /// whether a transcript has been cached locally. Pure — the view maps the result
    /// to a Grain status dot.
    ///
    /// A cached transcript is the strongest signal: Lore could only have produced it
    /// by transcribing the audio, so it always reads as Ready (this also keeps a
    /// pruned/tombstoned capture — whose audio is gone — reading correctly).
    public static func resolve(wal: CaptureStage,
                               streaming: Bool,
                               door: CaptureLifecycleStage,
                               hasTitle: Bool,
                               hasCachedTranscript: Bool) -> ConversationProgress {
        if hasCachedTranscript { return .ready }
        switch wal {
        case .recording:
            // The WAL only reports .recording while segments are still absent; trust
            // it ONLY while genuinely streaming. A dead empty capture must never
            // render as a live recording (the "Recording · 0/0" zombie cards).
            return streaming ? .recording : .savedOnPhone
        case .savedOnPhone:
            return streaming ? .recording : .savedOnPhone
        case .savedToComputer:
            // Audio is safely on the computer; the door owns the rest of the journey.
            switch door {
            case .recording, .stored: return .savedToComputer
            case .transcribing: return .transcribing
            // in_lore but not yet transcribed reads as Transcribing… (something IS
            // happening); once a title exists it's Ready.
            case .inLore: return hasTitle ? .ready : .transcribing
            case .transcribed, .organized: return .ready
            case .failed: return .failed
            }
        }
    }
}

/// The status-fetch dependency the poller drives. `DoorClient` is the production
/// conformer; door-free tests inject a stub to drive the stage machine without HTTP.
public protocol CaptureStatusFetching: Sendable {
    func captureStatus(captureId: String) async throws -> CaptureStatusResponse
}

extension DoorClient: CaptureStatusFetching {}

/// Polls one capture's door status until it reaches a terminal stage. Observable so
/// the card binds to `stage` directly.
///
/// LAG FIX (track 20260626): the poller is deliberately NOT fully `@MainActor`. The
/// network fetch + JSON decode run OFF the main actor (`pollAndApply()` is
/// nonisolated and the polling loop runs on a detached task); only the final
/// `@Published` state assignment hops back to the main actor (`apply(_:)`). With
/// dozens of cards on screen, doing the fetch/decode on the main actor stuttered the
/// UI for ~1–2s; isolating just the published mutation keeps the main thread free.
public final class CaptureStatusPoller: ObservableObject, @unchecked Sendable {
    public let captureId: String
    @Published public private(set) var stage: CaptureLifecycleStage
    @Published public private(set) var loreCaptureId: String?
    /// The Kiln-generated title once the door has it (drives the card's primary line).
    @Published public private(set) var title: String?
    /// The Kiln-generated summary/description once the door has it (the card's
    /// secondary line — what the conversation was about).
    @Published public private(set) var summary: String?
    /// Lore's terminal drop reason once a capture failed (`silent_no_transcript` |
    /// `noise` | `junk_purge` | `key_lost`) — drives the card's SPECIFIC failure line
    /// and whether a (useless-for-a-drop) retry is offered.
    @Published public private(set) var droppedReason: String?

    private let client: CaptureStatusFetching
    private let baseInterval: TimeInterval
    private let maxInterval: TimeInterval
    /// When set, each poll merges the title/summary/stage into the durable card
    /// metadata tombstone (`card.json`), so the conversation shows a name + description
    /// across launches and after its transcript text has been pruned.
    private let baseDir: URL?
    // Touched only on the main actor (start/stop + the @MainActor apply).
    @MainActor private var task: Task<Void, Never>?
    @MainActor private var lastTranscribed = false

    public init(captureId: String,
                client: CaptureStatusFetching,
                initialStage: CaptureLifecycleStage = .stored,
                baseInterval: TimeInterval = 5,
                maxInterval: TimeInterval = 60,
                baseDir: URL? = nil) {
        self.captureId = captureId
        self.client = client
        self.stage = initialStage
        self.baseInterval = baseInterval
        self.maxInterval = maxInterval
        self.baseDir = baseDir
        // Seed the live state from the durable card tombstone so the card shows its
        // name/description immediately on launch, before the first poll returns.
        if let baseDir, let card = ConversationCardStore.load(captureId: captureId, baseDir: baseDir) {
            self.title = card.title
            self.summary = card.summary
        }
    }

    /// What the loop needs back from a poll, computed on the main actor alongside the
    /// published-state mutation so the loop itself never touches @Published state.
    private struct PollOutcome { let terminal: Bool; let titlePending: Bool; let stored: Bool }

    /// Start polling. No-op if already running or already terminal. Driven by the
    /// card's `onAppear` (main actor).
    @MainActor public func start() {
        // Poll if not terminal, OR if we're terminal but still have no title (an
        // already-organized capture still needs its background-generated title for
        // the card). Nothing to do once terminal AND titled. An in_lore capture whose
        // durable card already carries a title has likewise received everything a
        // poll can deliver (title exists ⇒ transcript exists) — never re-poll it on
        // relaunch/scroll (this was the standing ~2,000 polls/hour storm).
        guard task == nil,
              !(stage.isTerminal && title != nil),
              !(stage == .inLore && title != nil) else { return }
        // Detached so the loop (fetch + decode + sleep) runs off the main actor; only
        // the @Published mutation in `apply` hops back to main.
        task = Task.detached(priority: .utility) { [weak self] in await self?.loop() }
    }

    /// Stop polling (call from the card's onDisappear).
    @MainActor public func stop() {
        task?.cancel()
        task = nil
    }

    /// One poll-and-apply, exposed for tests (drives the state machine without a
    /// timer). Returns true once the stage is terminal (the loop should stop). The
    /// fetch + decode happen here, off the main actor.
    @discardableResult
    public func pollOnce() async -> Bool {
        await pollAndApply().terminal
    }

    /// The off-main poll: fetch + decode here (nonisolated), then hop to the main
    /// actor only to publish the new state.
    private func pollAndApply() async -> PollOutcome {
        do {
            let resp = try await client.captureStatus(captureId: captureId)
            return await apply(resp)
        } catch {
            // Transport / non-2xx (incl. 404 before the door has the manifest) — keep
            // the current stage and let the loop back off + retry.
            return PollOutcome(terminal: false, titlePending: false, stored: stage == .stored)
        }
    }

    /// Publish the polled state on the main actor and return what the loop needs.
    @MainActor private func apply(_ resp: CaptureStatusResponse) -> PollOutcome {
        let next = CaptureLifecycleStage(wire: resp.stage)
        stage = next
        if let id = resp.loreCaptureId { loreCaptureId = id }
        if let t = resp.title, !t.isEmpty { title = t }
        if let s = resp.summary, !s.isEmpty { summary = s }
        lastTranscribed = resp.transcribed
        droppedReason = resp.droppedReason
        // Persist name/description/stage into the durable card tombstone so the whole
        // timeline stays browsable (with a title + summary) offline + after pruning.
        if let baseDir {
            ConversationCardStore.merge(captureId: captureId, baseDir: baseDir,
                                        title: resp.title, summary: resp.summary, stage: resp.stage)
        }
        // Keep polling past a terminal stage ONLY while a transcribed (non-failed)
        // capture is still waiting on its background-generated title.
        let titlePending = title == nil && lastTranscribed && next != .failed
        // in_lore + transcribed + titled = everything a status poll can EVER deliver
        // has been delivered (the door never advances captures past in_lore today, so
        // "wait for organized" meant polling every 5s forever — measured ~2,000
        // polls/hour across the visible list, 65% of all door traffic). Treat it as
        // terminal-for-polling; the transcript/speakers load on open via /content.
        let doneDelivering = next == .inLore && resp.transcribed && title != nil
        return PollOutcome(terminal: next.isTerminal || doneDelivering,
                           titlePending: titlePending, stored: next == .stored)
    }

    private func loop() async {
        var interval = baseInterval
        var titleWaits = 0
        while !Task.isCancelled {
            let r = await pollAndApply()
            if r.terminal {
                // Bounded wait so a never-titled terminal capture doesn't poll forever.
                if !r.titlePending { break }
                titleWaits += 1
                if titleWaits > 8 { break }
            }
            // Healthy poll resets the cadence; a stuck/erroring poll backs off.
            interval = min(interval * 1.5, maxInterval)
            if !r.stored { interval = baseInterval }  // mid-pipeline → keep snappy
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        }
        await MainActor.run { [weak self] in self?.task = nil }
    }
}
