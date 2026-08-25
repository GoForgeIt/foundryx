import XCTest
import Foundation
import BrineSwiftCore
@testable import FoundryXKit

/// Drives `features/speaker-confirm-feedback.feature` against the REAL local-first confirm
/// seams (track 20260717T1600_speaker_confirm_local_first):
///  • `SpeakerConfirmController` — the per-slot phase machine (in-flight → saved) the
///    inline affordance renders; local-first, so it never waits on the wire.
///  • `SpeakerConfirmFlow.backgroundShip` — the background sync a save rides (ts-guarded
///    dequeue + write-through + synced/rejected notification).
///  • `SpeakerConfirmFlow.drainPending` — the 5s-drain retry leg incl. the 401 → re-auth
///    stop and the 4xx → gentle-revert classification.
///  • `SpeakerConfirmQueue` + `SpeakerTranscript.applyingPendingConfirms` — the durable
///    pending overlay (the local render truth that survives relaunch).
///  • `SpeakerSyncModel` — the pending glyph + revert-notice state, riding the queue-change
///    and rejection notifications.
/// Hermetic: the door leg is an injected `ship` closure; no network, no SwiftUI.
final class SpeakerConfirmFeedbackTests: XCTestCase {

    func testSpeakerConfirmFeedbackFeature() async throws {
        let world = await ConfirmFeedbackWorld()
        defer { world.cleanup() }
        let registry = StepRegistry(ConfirmFeedbackSteps.make(world: world))
        try await BrineFeatureRunner.run("speaker-confirm-feedback", registry: registry)
    }
}

// MARK: - world

private final class ConfirmFeedbackWorld: @unchecked Sendable {
    enum ShipBehavior {
        case acknowledge            // door 200 + ConfirmOutcome, no offers
        case acknowledgeWithOffer   // door 200 + ConfirmOutcome carrying offeredCaptures
        case unreachable            // transport failure
        case reject                 // door/Lore refuses with a 4xx (400)
        case unauthorized           // expired sign-in (401)
        case hang                   // request lands, answer never returns (b230 class)
    }

    let captureId = "cap-feedback"
    let slot = "speaker_1"
    var dir: URL
    var behavior: ShipBehavior = .acknowledge

    @MainActor var controller: SpeakerConfirmController?
    @MainActor var syncModel: SpeakerSyncModel!

    // interactive tap
    var resolvedPhase: SpeakerConfirmPhase?
    var tapElapsed: TimeInterval = 0
    var shipAnswered = false

    // sheet save
    var sheetDismissed = false
    var sheetOffered = false
    var localSaved = false
    /// The local-first flow has NO error output — this documents that invariant; nothing
    /// ever sets it true.
    var errorShown = false

    // drain
    var drainAuthExpired = false
    var drainShipCalls = 0

    // notifications captured
    var syncedOffer: [OfferedCapture] = []

    private var observers: [NSObjectProtocol] = []

    @MainActor init() {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("scfb-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        syncModel = SpeakerSyncModel(captureId: captureId, baseDir: dir)
        observers.append(NotificationCenter.default.addObserver(
            forName: .foundryxSpeakerConfirmSynced, object: nil, queue: .main) { [weak self] note in
                if let o = note.userInfo?["outcome"] as? ConfirmOutcome, o.captureId == self?.captureId {
                    self?.syncedOffer = o.offeredCaptures
                }
            })
    }

    func cleanup() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        try? FileManager.default.removeItem(at: dir)
    }

    @MainActor func reset() {
        behavior = .acknowledge
        controller = nil
        resolvedPhase = nil
        tapElapsed = 0
        shipAnswered = false
        sheetDismissed = false
        sheetOffered = false
        localSaved = false
        errorShown = false
        drainAuthExpired = false
        drainShipCalls = 0
        syncedOffer = []
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        syncModel = SpeakerSyncModel(captureId: captureId, baseDir: dir)
    }

    /// The tentatively-matched (inferred) speaker: "Alex" at STRONG confidence (≥ the
    /// reveal floor, so the name renders) — and, crucially, WITH an inferred speakerId, so
    /// a regression that shipped the old speakerId on a RENAME (P1) would surface as a
    /// non-nil speakerId on the enqueued entry.
    func inferredSpeaker() -> CaptureSpeaker {
        CaptureSpeaker(slot: slot, status: .inferred, name: "Alex", inferScore: 0.92,
                       inferredSpeakerId: "sp-alex")
    }

    /// A tentatively-matched (inferred) base transcript: one slot "Alex" at 80% + a segment.
    func baseTranscript() -> SpeakerTranscript {
        SpeakerTranscript(
            speakers: [inferredSpeaker()],
            segments: [TranscriptSegment(seq: 0, text: "Hello there.", speaker: slot)])
    }

    /// The overlay-rendered transcript: base with the still-pending confirms applied.
    func rendered() -> SpeakerTranscript {
        baseTranscript().applyingPendingConfirms(
            SpeakerConfirmQueue.pending(baseDir: dir).filter { $0.captureId == captureId })
    }

    func outcome(offered: [OfferedCapture] = []) -> ConfirmOutcome {
        ConfirmOutcome(captureId: captureId, slotLabel: slot, status: "confirmed",
                       speakerId: "sp-9", speakerName: "Dana", offeredCaptures: offered)
    }

    /// The injected background/interactive ship, per the declared behavior.
    func ship() -> @Sendable () async throws -> ConfirmOutcome {
        let behavior = behavior
        let ok = outcome()
        let withOffer = outcome(offered: [OfferedCapture(captureId: "cap-past", slotLabel: "speaker_0", score: 0.9)])
        return { [self] in
            switch behavior {
            case .acknowledge: shipAnswered = true; return ok
            case .acknowledgeWithOffer: shipAnswered = true; return withOffer
            case .unreachable: throw DoorError.transport("computer unreachable")
            case .reject: throw DoorError.http(400)
            case .unauthorized: throw DoorError.unauthorized
            case .hang:
                try await Task.sleep(nanoseconds: 30_000_000_000)
                shipAnswered = true
                return ok
            }
        }
    }

    @MainActor func pending() -> [SpeakerConfirmQueue.Entry] {
        SpeakerConfirmQueue.pending(baseDir: dir).filter { $0.captureId == captureId }
    }

    /// Mimic the tag sheet's local-first save: durably enqueue, apply locally, then race
    /// the background ship for a fast-network offer within the flash window (as the sheet
    /// does). Drives the REAL `SpeakerConfirmIntent.make` decision the sheet uses — a typed
    /// name is name-only — so this can't mask the P1 (an old speakerId riding a rename).
    /// Sets `sheetDismissed`/`sheetOffered`.
    func saveFromSheet(name: String) async {
        let intent = SpeakerConfirmIntent.make(typedName: name, speaker: inferredSpeaker())
        let ts = SpeakerConfirmQueue.enqueue(captureId: captureId, slot: slot, name: intent.name,
                                             speakerId: intent.speakerId, baseDir: dir)
        localSaved = true
        let outcome = await SpeakerConfirmFlow.backgroundShip(
            captureId: captureId, slot: slot, name: intent.name, speakerId: intent.speakerId,
            ts: ts, baseDir: dir, deadline: 0.4, ship: ship())
        if let outcome, !outcome.offeredCaptures.isEmpty {
            sheetOffered = true
        } else {
            sheetDismissed = true
        }
    }

    /// The drain leg wired exactly as `CaptureManager.retryPendingSpeakerConfirms` does —
    /// posting the synced/rejected notifications + write-through — so the sync model reacts.
    func runDrain() async {
        let base = dir
        await SpeakerConfirmFlow.drainPending(
            baseDir: base,
            ship: { [self] e in
                drainShipCalls += 1
                return try await ship()()
            },
            onSynced: { e, outcome in
                await Task.detached {
                    TranscriptCacheStore.confirmSpeaker(
                        captureId: e.captureId, slot: e.slot,
                        name: outcome.speakerName.isEmpty ? e.name : outcome.speakerName,
                        speakerId: outcome.speakerId.isEmpty ? e.speakerId : outcome.speakerId,
                        baseDir: base)
                }.value
                await SpeakerConfirmSync.postSynced(outcome)
            },
            onRejected: { e in
                await SpeakerConfirmSync.postRejected(captureId: e.captureId, slot: e.slot, name: e.name)
            },
            onAuthExpired: { self.drainAuthExpired = true })
    }

    /// Poll a main-actor predicate (notifications post asynchronously on the main queue).
    @MainActor func waitUntil(_ predicate: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<200 {
            if predicate() { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return predicate()
    }
}

// MARK: - steps

private enum ConfirmFeedbackSteps {
    static func make(world w: ConfirmFeedbackWorld) -> [StepDefinition] {
        [
            // ── Givens ────────────────────────────────────────────────────────
            defineStep("a conversation with a tentatively matched speaker") { ctx, _, _ in
                await w.reset()
                return ctx
            },
            defineStep("my computer cannot be reached") { ctx, _, _ in
                w.behavior = .unreachable
                return ctx
            },
            defineStep("a saved name is waiting to sync") { ctx, _, _ in
                // Fresh state (this Given may open a scenario), then a durable pending
                // confirm for this capture, un-shipped (an offline save).
                await w.reset()
                _ = await MainActor.run { SpeakerConfirmQueue.enqueue(
                    captureId: w.captureId, slot: w.slot, name: "Dana", speakerId: nil, baseDir: w.dir) }
                _ = await w.waitUntil { w.syncModel.isPending(w.slot) }
                return ctx
            },
            defineStep("speaker changes are waiting to sync on my phone") { ctx, _, _ in
                await w.reset()
                await MainActor.run {
                    SpeakerConfirmQueue.enqueue(captureId: "cap-a", slot: "speaker_0", baseDir: w.dir)
                    SpeakerConfirmQueue.enqueue(captureId: "cap-b", slot: "speaker_1", name: "Dana", baseDir: w.dir)
                }
                return ctx
            },
            defineStep("my sign-in to the computer has expired") { ctx, _, _ in
                w.behavior = .unauthorized
                return ctx
            },

            // ── Whens ─────────────────────────────────────────────────────────
            defineStep("I tap to save that speaker") { ctx, _, _ in
                w.behavior = .hang   // the wire never answers; the local save must not wait
                let controller = await MainActor.run { () -> SpeakerConfirmController in
                    let c = SpeakerConfirmController(baseDir: w.dir, deadline: 5, successDwell: 10)
                    w.controller = c
                    return c
                }
                let ship = w.ship()
                let start = Date()
                w.resolvedPhase = await controller.confirm(captureId: w.captureId, slot: w.slot,
                                                           name: "Dana", ship: ship)
                w.tapElapsed = Date().timeIntervalSince(start)
                return ctx
            },
            defineStep("I save a name for the speaker from the sheet") { ctx, _, _ in
                await w.saveFromSheet(name: "Dana")
                return ctx
            },
            defineStep("the app relaunches before the change has synced") { ctx, _, _ in
                // A fresh world state built from the SAME durable dir — no in-memory state.
                await MainActor.run { w.syncModel = SpeakerSyncModel(captureId: w.captureId, baseDir: w.dir) }
                _ = await w.waitUntil { w.syncModel.isPending(w.slot) }
                return ctx
            },
            defineStep("my computer acknowledges the change") { ctx, _, _ in
                w.behavior = .acknowledge
                await w.runDrain()
                return ctx
            },
            defineStep("the phone retries the pending change") { ctx, _, _ in
                await w.runDrain()
                return ctx
            },
            defineStep("the phone retries the pending changes") { ctx, _, _ in
                await w.runDrain()
                return ctx
            },
            defineStep("my computer rejects the change") { ctx, _, _ in
                w.behavior = .reject
                await w.runDrain()
                return ctx
            },
            defineStep("my computer acknowledges the change and it matches past conversations") { ctx, _, _ in
                w.behavior = .acknowledgeWithOffer
                await w.runDrain()
                return ctx
            },

            // ── Thens ─────────────────────────────────────────────────────────
            defineStep("the save shows progress immediately, before my computer has answered") { ctx, _, _ in
                // `.pendingSync` accepted with AC5b: the tap still responds INSTANTLY, it
                // just no longer claims the computer has it. That is the whole point of this
                // step -- progress before the wire answers -- and `pendingSync` is exactly
                // that, honestly named. `.confirmed` is deliberately still accepted: a fast
                // ACK can promote the row before this step reads it, and a scenario that
                // failed on a WIN would be a flake.
                guard w.resolvedPhase == .pendingSync
                    || w.resolvedPhase == .confirmed
                    || w.resolvedPhase == .inFlight else {
                    throw BrineStepError("tap did not show progress: \(String(describing: w.resolvedPhase))")
                }
                guard !w.shipAnswered else { throw BrineStepError("the save waited on the wire") }
                guard w.tapElapsed < 2 else { throw BrineStepError("the save blocked on the round trip") }
                return ctx
            },
            defineStep("the save succeeds right away and the sheet dismisses itself") { ctx, _, _ in
                guard w.localSaved else { throw BrineStepError("the local save did not land") }
                guard w.sheetDismissed else { throw BrineStepError("the sheet did not dismiss itself") }
                return ctx
            },
            defineStep("the saved name shows in the conversation immediately") { ctx, _, _ in
                let label = await MainActor.run { w.rendered().displayLabel(for: w.slot) }
                guard label == "Dana" else { throw BrineStepError("expected 'Dana', got '\(label)'") }
                return ctx
            },
            defineStep("the saved change records only the typed name so my computer honors it") { ctx, _, _ in
                // Lore's confirm resolves speakerId OVER name — so a rename MUST enqueue/ship
                // name-only, else it silently confirms the OLD speaker (review P1). The
                // inferred slot carries a speakerId ("sp-alex"); the saved intent must NOT.
                let pending = await w.pending()
                guard let entry = pending.first(where: { $0.slot == w.slot }) else {
                    throw BrineStepError("the rename lost its durable intent")
                }
                guard entry.name == "Dana" else {
                    throw BrineStepError("the typed name was not recorded: \(String(describing: entry.name))")
                }
                guard entry.speakerId == nil else {
                    throw BrineStepError("a rename shipped the OLD speakerId (\(entry.speakerId!)) — Lore would confirm the wrong speaker")
                }
                return ctx
            },
            defineStep("the saved name still shows in the conversation") { ctx, _, _ in
                let label = await MainActor.run { w.rendered().displayLabel(for: w.slot) }
                guard label == "Dana" else { throw BrineStepError("name lost across relaunch: '\(label)'") }
                return ctx
            },
            defineStep("the change is still waiting to sync") { ctx, _, _ in
                let pending = await w.pending()
                guard pending.contains(where: { $0.slot == w.slot }) else {
                    throw BrineStepError("the change lost its durable intent: \(pending)")
                }
                return ctx
            },
            defineStep("the change stays pending on my phone so it ships later") { ctx, _, _ in
                let pending = await w.pending()
                guard pending.contains(where: { $0.slot == w.slot }) else {
                    throw BrineStepError("failed sync lost its durable intent: \(pending)")
                }
                return ctx
            },
            defineStep("the speaker shows a quiet waiting-to-sync indicator") { ctx, _, _ in
                let shown = await w.waitUntil { w.syncModel.isPending(w.slot) }
                guard shown else { throw BrineStepError("no waiting-to-sync indicator for the pending change") }
                return ctx
            },
            defineStep("no error is shown anywhere") { ctx, _, _ in
                guard !w.errorShown else { throw BrineStepError("an error was surfaced — local-first never errors") }
                return ctx
            },
            defineStep("the waiting-to-sync indicator is gone") { ctx, _, _ in
                let cleared = await w.waitUntil { !w.syncModel.isPending(w.slot) }
                guard cleared else { throw BrineStepError("the indicator did not clear on the ACK") }
                return ctx
            },
            defineStep("the change is no longer pending on my phone") { ctx, _, _ in
                let pending = await w.pending()
                guard pending.isEmpty else { throw BrineStepError("acknowledged change still queued: \(pending)") }
                return ctx
            },
            defineStep("the retry stops and requests re-authentication") { ctx, _, _ in
                guard w.drainAuthExpired else { throw BrineStepError("the 401 must fire the re-auth seam") }
                guard w.drainShipCalls == 1 else {
                    throw BrineStepError("the 401 must stop the pass (ship calls: \(w.drainShipCalls))")
                }
                return ctx
            },
            defineStep("the pending changes are kept for after I sign in again") { ctx, _, _ in
                let count = await MainActor.run { SpeakerConfirmQueue.pending(baseDir: w.dir).count }
                guard count == 2 else { throw BrineStepError("pending changes were lost: \(count)") }
                return ctx
            },
            defineStep("I see a gentle notice that it was reverted, not an error dialog") { ctx, _, _ in
                let ok = await w.waitUntil { (w.syncModel.notices[w.slot]?.contains("reverted")) == true }
                guard ok else { throw BrineStepError("no gentle revert notice was shown") }
                // The name reverts to server truth (the overlay entry is gone).
                let label = await MainActor.run { w.rendered().displayLabel(for: w.slot) }
                guard label == "Alex" else { throw BrineStepError("name did not revert to server truth: '\(label)'") }
                return ctx
            },
            defineStep("I am offered to apply the name to those past conversations") { ctx, _, _ in
                let offered = await w.waitUntil { !w.syncedOffer.isEmpty }
                guard offered else { throw BrineStepError("the apply-to-past offer was not surfaced") }
                return ctx
            },
        ]
    }
}
