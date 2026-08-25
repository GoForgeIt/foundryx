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
public enum CaptureLifecycleStage: String, Sendable, Equatable, CaseIterable {
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
        case .recording: return "🔴 Note in progress"
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
public enum ConversationProgress: String, Sendable, Equatable, CaseIterable {
    case recording          // mic live, frames arriving
    case savedOnPhone       // ≥1 segment durable on the phone, not all ACK'd yet
    case savedToComputer    // every segment ACK'd; door hasn't reported Lore progress yet
    case transcribing       // reached the desktop/Lore; transcript still cooking
    case ready              // transcript/title available — openable
    case failed             // terminal transcription failure (retry affordance)

    /// The calm chip label, per tier.
    ///
    /// THIS TOOK `local: Bool` AND THAT BOOL SHIPPED A FALSE CHIP. One bit cannot answer
    /// "which of three places", and `App/` derived it as `destination == .phone`, so
    /// `.computer` and `.vault` were indistinguishable and a Vault owner's chip read
    /// "Saved to computer". Worse, there was a `var label` convenience that defaulted the
    /// bit to `false` — a DEFAULT THAT NAMED A COMPUTER, chosen by whoever forgot to pass
    /// anything. Both are gone: the tier is required and the switch is exhaustive, so a
    /// fourth brain fails to compile until it picks its own words.
    ///
    /// Where a label names NO place ("Transcribing…") two tiers may share it — a sentence
    /// that names nowhere cannot name the wrong somewhere.
    public func label(destination: CaptureDestination) -> String {
        switch self {
        case .recording: return "Taking a note"
        case .savedOnPhone: return "Saved on phone"
        case .savedToComputer:
            switch destination {
            case .phone:    return "Saved on phone"
            case .computer: return "Saved to computer"
            case .vault:    return "Saved to your Vault"
            }
        case .transcribing:
            switch destination {
            case .phone:              return "Transcribing on this phone…"
            case .computer, .vault:   return "Transcribing…"
            }
        case .ready: return "Ready"
        case .failed: return "Transcription failed — retry"
        }
    }

    /// Whether the card should offer a retry affordance.
    public var needsRetry: Bool { self == .failed }

    // MARK: - stepper (visible "where is this conversation" progress)

    /// The ordered pipeline steps a conversation moves through, for the visual
    /// stepper on the detail view. Deliberately coarse + honest — only steps the
    /// phone has a real signal for (we never claim "diarizing"/"titling" as their
    /// own step without a signal; those happen inside the transcribe→ready span).
    public enum Step: Int, CaseIterable, Sendable {
        case recorded = 0    // audio captured
        case saved           // durable (on phone, or safely on the computer)
        case transcribing    // transcript being produced (STT + speakers + title)
        case ready           // openable — transcript/title available

        /// Brand-honest label, per tier. Exhaustive over `CaptureDestination` for the
        /// same reason the chip is: the Bool this replaced could not tell a Vault from a
        /// Mac, so the stepper on a Vault owner's voice note said "Saved to computer".
        public func label(destination: CaptureDestination) -> String {
            switch self {
            case .recorded: return "Captured"
            case .saved:
                switch destination {
                case .phone:    return "Saved on phone"
                case .computer: return "Saved to computer"
                case .vault:    return "Saved to your Vault"
                }
            case .transcribing:
                switch destination {
                case .phone:            return "Transcribing on phone"
                case .computer, .vault: return "Transcribing"
                }
            case .ready: return "Ready"
            }
        }
    }

    /// How a single step should render in the stepper for THIS progress.
    public enum StepState: Sendable, Equatable { case done, active, pending, failed }

    /// The state of `step` for this progress — the whole stepper is `Step.allCases`
    /// mapped through this. Pure + unit-tested: no clever UI derivation, just the
    /// honest "have we finished this, are we on it, or is it still ahead."
    public func state(of step: Step) -> StepState {
        // The furthest step reached (as an index), and whether we're mid-flight ON it.
        // ready ⇒ every step done; failed ⇒ the transcribing step shows the failure.
        switch self {
        case .failed:
            switch step {
            case .recorded, .saved: return .done
            case .transcribing: return .failed
            case .ready: return .pending
            }
        case .ready:
            return .done
        case .recording:
            return step == .recorded ? .active : .pending
        case .savedOnPhone:
            switch step {
            case .recorded: return .done
            case .saved: return .active
            default: return .pending
            }
        case .savedToComputer, .transcribing:
            switch step {
            case .recorded, .saved: return .done
            case .transcribing: return .active
            case .ready: return .pending
            }
        }
    }

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

    /// **THIS RECORDING'S JOURNEY, DERIVED FROM WHAT THE DOOR ACTUALLY SAID.**
    ///
    /// Published from the poller rather than assembled by a view, so the band is bound to a
    /// live seam. A reading some view composed is a reading no test can hold, because
    /// `swift test` cannot compile `App/`.
    ///
    /// **IT CLAIMS ONE STAGE, BECAUSE THE DOOR'S REPLY SUPPORTS ONE STAGE.** `speakers`,
    /// `naming` and `intelligence` stay `.notEstablished` unless something actually reports
    /// them. That is this surface's whole purpose: the shipped build said "transcribing
    /// locally" while the Vault already held the transcript, and the door's own `summarizing`
    /// flag was `transcribed && title.is_none()` — **the absence of a title, not work in
    /// flight** — which read `true` for four days on a capture that could never be titled.
    ///
    /// So a missing title maps to `.notEstablished`, NEVER to `.inFlight`. "Nobody told us"
    /// and "it is running" are different facts, and only the first is true here.
    @Published public private(set) var journey = RecordingJourneyReading()

    private let client: CaptureStatusFetching
    private let baseInterval: TimeInterval
    private let maxInterval: TimeInterval
    /// When set, each poll merges the title/summary/stage into the durable card
    /// metadata tombstone (`card.json`), so the conversation shows a name + description
    /// across launches and after its transcript text has been pruned.
    private let baseDir: URL?
    /// Fired (on the main actor) ONLY when a poll's card merge actually WROTE card.json —
    /// so the manager can invalidate its per-capture sidecar memo + rebuild the list. The
    /// poller writes the durable card tombstone outside the manager's sight, so without
    /// this the manager's memo would go stale after a title/summary landed (track
    /// 20260717T0448 F1). nil in door-free unit tests that don't seed a manager.
    private let onCardWritten: (@MainActor @Sendable (String) -> Void)?
    // Touched only on the main actor (start/stop + the @MainActor apply).
    @MainActor private var task: Task<Void, Never>?
    @MainActor private var lastTranscribed = false
    @MainActor private var accountExposureClosing = false
    @MainActor private var accountExposureClosed = false
    @MainActor private var closingWaitersForTests:
        [CheckedContinuation<Void, Never>] = []

    public init(captureId: String,
                client: CaptureStatusFetching,
                initialStage: CaptureLifecycleStage = .stored,
                baseInterval: TimeInterval = 5,
                maxInterval: TimeInterval = 60,
                baseDir: URL? = nil,
                onCardWritten: (@MainActor @Sendable (String) -> Void)? = nil) {
        self.captureId = captureId
        self.client = client
        self.stage = initialStage
        self.baseInterval = baseInterval
        self.maxInterval = maxInterval
        self.baseDir = baseDir
        self.onCardWritten = onCardWritten
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
        guard !accountExposureClosing,
              !accountExposureClosed,
              task == nil,
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

    /// Terminal close, distinct from the card's restartable onDisappear `stop`.
    /// The ACK joins a suspended fetch and rejects its continuation before publish
    /// or card.json merge.
    @MainActor public func close() async {
        if accountExposureClosed { return }
        if accountExposureClosing {
            let running = task
            if let running { await running.value }
            return
        }
        accountExposureClosing = true
        let waiters = closingWaitersForTests
        closingWaitersForTests.removeAll()
        for waiter in waiters { waiter.resume() }
        let running = task
        running?.cancel()
        if let running { await running.value }
        task = nil
        accountExposureClosed = true
        accountExposureClosing = false
    }

    @MainActor func waitUntilClosingForTests() async {
        guard !accountExposureClosing else { return }
        await withCheckedContinuation { continuation in
            closingWaitersForTests.append(continuation)
        }
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
            guard !Task.isCancelled,
                  await MainActor.run(body: {
                      !self.accountExposureClosing
                          && !self.accountExposureClosed
                  }) else {
                return PollOutcome(
                    terminal: true, titlePending: false, stored: false)
            }
            return await apply(resp)
        } catch {
            // Transport / non-2xx (incl. 404 before the door has the manifest) — keep
            // the current stage and let the loop back off + retry.
            return PollOutcome(terminal: false, titlePending: false, stored: stage == .stored)
        }
    }

    /// Publish the polled state on the main actor and return what the loop needs.
    /// THE DERIVATION, AS A PURE FUNCTION so it is testable without a poller, a clock or a door.
    ///
    /// **Every field it does not set stays at the reading's honest default.** That is deliberate
    /// and it is the criterion: this function may only produce a claim it can point at a source
    /// for. Adding a field here without a source in `CaptureStatusResponse` is how the surface
    /// starts inventing progress again.
    static func journey(stage: CaptureLifecycleStage,
                        transcribed: Bool,
                        title: String?,
                        droppedReason: String?,
                        transcribeWindows: CaptureStatusResponse.TranscribeWindowsPayload? = nil,
                        naming: String? = nil)
        -> RecordingJourneyReading {
        var reading = RecordingJourneyReading()

        // TRANSCRIPT — the one thing the door genuinely reports.
        if stage == .failed {
            reading.transcript = .failed(droppedReason)
        } else if transcribed {
            reading.transcript = .done
        } else if stage == .transcribing {
            // THE WINDOW COUNTS, WHEN THE DOOR ACTUALLY COUNTED THEM.
            //
            // This read `.inProgress(nil)` unconditionally until the door could report
            // `transcribeWindows` — Lore counts one `transcribe_chunk` row per finished
            // window and carries the total in `chunk_count`, so both numbers are read
            // rather than inferred from a duration or a rate.
            //
            // **`nil` REMAINS THE ORDINARY CASE and still means no bar.** A recording
            // under the 600 s threshold is transcribed whole and has no windows; one
            // that has not started has none yet. Neither is 0%, and the reading stays
            // optional the whole way down so an absence cannot be drawn as a zero.
            //
            // A count that exceeds its total is REFUSED rather than clamped: it means
            // the counts disagree, and a bar pinned at 100% while work continues is the
            // same lie as a bar at 0% for work nobody measured.
            if let w = transcribeWindows,
               w.windowCount > 0,
               w.windowsDone >= 0,
               w.windowsDone <= w.windowCount {
                reading.transcript = .inProgress(
                    TranscribeWindowsReading(windowsDone: w.windowsDone,
                                             windowCount: w.windowCount))
            } else {
                reading.transcript = .inProgress(nil)
            }
        }

        // NAMING — a title that EXISTS, else EVIDENCE, and still never an inference.
        //
        // There is STILL no branch turning an absent title into `.inFlight`. The door's
        // `summarizing` was exactly that inference — `transcribed && title.is_none()` — and it
        // told people work was running on a capture that could never be titled.
        //
        // ⚠ `.inFlight` IS NOW REACHABLE, AND ONLY FROM EVIDENCE. Lore records the
        // `conversation_processing` run id and resolves it through its runtime's
        // `GET /status/{run_id}`, so `"inFlight"` here means a run that is ACTUALLY RUNNING —
        // not a marker that was set before the fire and kept when the fire failed. That
        // distinction is the whole reason this arrives as a field instead of being derived.
        //
        // `"failed"` and `"completed"` both fall through to `.notEstablished`, deliberately:
        //   · failed    → nothing is running and no name exists. That IS "the seam says nothing".
        //   · completed → the run finished and produced no title, which the runner documents as
        //                 a correct outcome ("abstention … is a correct, scored-positive
        //                 outcome — never a null fabricated over"). Showing "naming" for a run
        //                 that deliberately declined to name would be the same lie inverted.
        // Surfacing failure to a PERSON is a product question and would need a fifth
        // `NamingState` case plus every rendering that switches on it; not invented here.
        if let title, !title.isEmpty {
            reading.naming = .done
        } else if naming == "inFlight" {
            reading.naming = .inFlight
        }

        // SPEAKERS and INTELLIGENCE are left `.notEstablished` on purpose: nothing in a status
        // poll reports either. (Naming used to be listed here too — that is no longer true.)
        return reading
    }

    @MainActor private func apply(_ resp: CaptureStatusResponse) -> PollOutcome {
        guard !accountExposureClosing, !accountExposureClosed else {
            return PollOutcome(
                terminal: true, titlePending: false, stored: false)
        }
        let next = CaptureLifecycleStage(wire: resp.stage)
        stage = next
        if let id = resp.loreCaptureId { loreCaptureId = id }
        if let t = resp.title, !t.isEmpty { title = t }
        if let s = resp.summary, !s.isEmpty { summary = s }
        lastTranscribed = resp.transcribed
        droppedReason = resp.droppedReason
        journey = Self.journey(stage: next,
                               transcribed: resp.transcribed,
                               title: title,
                               droppedReason: resp.droppedReason,
                               transcribeWindows: resp.transcribeWindows,
                               naming: resp.naming)
        // Persist name/description/stage into the durable card tombstone so the whole
        // timeline stays browsable (with a title + summary) offline + after pruning.
        if let baseDir {
            let wrote = ConversationCardStore.merge(captureId: captureId, baseDir: baseDir,
                                                    title: resp.title, summary: resp.summary,
                                                    stage: resp.stage,
                                                    // The reason outlives this poller: the
                                                    // detail view opens long after it stops.
                                                    droppedReason: resp.droppedReason)
            // Only signal a REAL change — repeat polls with unchanged content don't churn
            // the manager's memo/rebuild (mirrors merge's own change-gated event log).
            if wrote { onCardWritten?(captureId) }
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
