// SpeakerConfirmFlow — the ONE path a speaker confirm/save takes from a tap to an
// outcome the UI can render honestly. LOCAL-FIRST as of track
// 20260717T1600_speaker_confirm_local_first.
//
// Why local-first (Nick, b232): "the saving spinner is a nice touch but I ran into
// 'couldn't connect to the computer'. Is it possible to save on the phone locally first
// then get it to the computer in the background?" — YES. The name + slot are known at tap
// time; the ONLY things the phone learns from the Mac are the propagation OFFER ("this
// voice also matches N past conversations") and the canonical speakerId/name (a merge may
// resolve a different record). Neither needs a live response.
//
// So every confirm now:
//   1. DURABLE first — the intent is on disk (SpeakerConfirmQueue) before the wire.
//   2. INSTANT local success — the change applies to the local view immediately (the
//      pending overlay renders it, survives relaunch) and the affordance/sheet reads
//      "Saved" right away. No spinner waits on the wire.
//   3. SILENT background sync — the ship rides in the background; a subtle pending glyph
//      sits by the name until the Mac ACKs (queue-change notification clears it).
//   4. Failure is NOT an error — unreachable/timeout stays quietly pending (the drain
//      retries); auth-expiry is handled ONCE by the drain's re-auth seam; a rare 4xx
//      rejection drops the intent and reverts gently.
//
// FoundryXKit (UI-free): pure state + copy + injectable `ship`/callback closures, so the
// brine step-defs drive the REAL flow hermetically (no network, no SwiftUI). It may use
// Foundation + NotificationCenter (the sync model rides queue-change notifications).

import Foundation

// MARK: - notifications (the observable sync seam)

public extension Notification.Name {
    /// Posted (main queue) after any mutating queue op that changed the file, so the sync
    /// model can refresh the pending-glyph state. `userInfo["captureId"]` = the affected
    /// capture.
    static let foundryxSpeakerConfirmQueueChanged = Notification.Name("foundryxSpeakerConfirmQueueChanged")
    /// Posted after the Mac ACKNOWLEDGES a queued confirm (interactive background ship OR
    /// the drain). `userInfo["outcome"]` = the `ConfirmOutcome` — carries the canonical
    /// speakerId/name to reconcile and any propagation `offeredCaptures` to surface.
    static let foundryxSpeakerConfirmSynced = Notification.Name("foundryxSpeakerConfirmSynced")
    /// Posted when the Mac REJECTS a queued confirm with a 4xx (non-401) — the intent was
    /// dropped from the queue; the open conversation reverts the name to server truth and
    /// shows a gentle transient notice. `userInfo`: captureId, slot, name (all String?).
    static let foundryxSpeakerConfirmRejected = Notification.Name("foundryxSpeakerConfirmRejected")
}

// MARK: - what a confirm SHIPS (the name-vs-speakerId decision, in one pure place)

/// The `(name, speakerId)` a confirm should SHIP through the door, decided in ONE pure,
/// unit-tested place so the tag sheet and the tests can never drift (adversarial review
/// P1). The rule matters because Lore's `confirm_slot` lets `speaker_id` WIN over `name`
/// when both are present:
///   • A TYPED name is NAME-ONLY (`speakerId == nil`) — Lore then confirms/creates/merges
///     BY NAME. Shipping the slot's existing inferred/confirmed speakerId alongside a typed
///     name would make Lore assign-to-the-OLD-speaker and silently DROP the typed name
///     (the user sees the new name for a beat, then it flips back on the ACK reconcile).
///   • A BARE confirm (no typed name) ships the slot's known speakerId to confirm the
///     existing match (also robust for drain re-ships).
public enum SpeakerConfirmIntent {
    /// `typedName` is what the user typed (nil/blank = a bare confirm of the inferred match).
    public static func make(typedName: String?, speaker: CaptureSpeaker)
        -> (name: String?, speakerId: String?) {
        let trimmed = typedName?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty {
            return (trimmed, nil)   // NAME-ONLY — never ride the old speakerId
        }
        return (nil, speaker.confirmedSpeakerId ?? speaker.inferredSpeakerId)   // bare confirm
    }

    /// PICK an existing durable person (track 20260717T1700): bind the slot to that
    /// person's opaque `entityId` — the dedup-at-entry authority. Ships the person's
    /// display name too (so the local overlay renders it and the door has a label), but
    /// NEVER the slot's old speakerId (Lore resolves speakerId over name/entity; riding the
    /// stale id would confirm the wrong record). `entityId` is the durable person key the
    /// backend links `speaker.entity_id` from — a chosen existing entity, never a mint.
    public static func pick(person: KnownPerson)
        -> (name: String?, speakerId: String?, entityId: String?) {
        (person.displayName, nil, person.entityId)
    }
}

/// The decision to surface the late (post-sheet-dismissal) propagation offer banner —
/// pure so it's unit-testable. Suppressed while a tag sheet is presenting, because the
/// sheet surfaces the offer itself within its flash window (otherwise the same offer would
/// double-surface: once in the modal sheet, once as a stale banner behind it — review P2#2).
public enum SpeakerLateOffer {
    public static func shouldSurface(offeredCount: Int, sheetPresenting: Bool) -> Bool {
        offeredCount > 0 && !sheetPresenting
    }
}

// MARK: - phases (what the inline affordance renders)

/// The lifecycle of one confirm affordance. Local-first: the tap flips to `.inFlight`
/// within a frame (the durable enqueue), then to `.confirmed` the instant the LOCAL save
/// lands — never waiting on the wire. There is no `.failed` interactive phase: a sync that
/// can't reach the Mac stays quietly pending (the glyph), it is not an error the affordance
/// shows.
public enum SpeakerConfirmPhase: Equatable, Sendable {
    case idle
    case inFlight
    /// Saved on THIS PHONE, not yet acknowledged by the second place.
    ///
    /// ⚠ THE STATE THAT MAKES A CONFIRMATION HONEST. The local write is optimistic on purpose
    /// — it keeps the tap from hanging on the network — but before this existed the row flipped
    /// straight to `.confirmed`, so a confirmation that NEVER LANDED was indistinguishable from
    /// one that did. That is the failure standing between 17 confirmed speakers and the
    /// captures waiting to be tagged: an owner cannot re-do work they were told succeeded.
    case pendingSync
    /// The second place has it. Claimed only on acknowledgement, never on the local save.
    case confirmed
}

// MARK: - the background ship + drain (the silent sync leg)

/// How a background/drain ship of a queued confirm resolved, so the interactive leg and
/// the drain classify it identically.
public enum SpeakerShipDisposition: Equatable, Sendable {
    /// The Mac acknowledged — dequeue (ts-guarded), write-through the cache, reconcile.
    case synced
    /// Sign-in expired (401). The drain's re-auth seam handles it; the intent stays queued.
    case authExpired
    /// The Mac actively refused with a 4xx (non-401) — drop the intent, revert gently.
    case rejected(Int)
    /// Unreachable / timeout / 5xx — stay queued, the drain retries. Not an error.
    case transient

    /// Map a thrown ship error onto its disposition. A `DeadlineExceeded` (a hung round
    /// trip) and any transport/cancellation are `.transient`; a 4xx (non-401) is a real
    /// rejection; 5xx is transient (the Mac is up but momentarily unhappy — retry).
    public static func classify(_ error: Error) -> SpeakerShipDisposition {
        if let door = error as? DoorError {
            switch door {
            case .unauthorized: return .authExpired
            case .http(let code): return (400..<500).contains(code) ? .rejected(code) : .transient
            case .transport: return .transient
            }
        }
        return .transient   // deadline / cancellation / URLSession — the Mac is out of reach
    }
}

public enum SpeakerConfirmFlow {
    /// Default ceiling on one background confirm round trip. Past it the ship resolves to
    /// `.transient` (the durable queue re-ships on a later drain). The door answers in well
    /// under a second when healthy; 12s covers a slow relay leg without wedging the ship.
    public static let defaultDeadline: TimeInterval = 12

    /// Ship one already-durably-queued confirm in the BACKGROUND (detached from the phase
    /// machine) and apply the side effects of its disposition:
    ///   * synced   → ts-guarded remove + write-through the cached transcript + post
    ///                `foundryxSpeakerConfirmSynced` (glyph clears, name/id reconcile,
    ///                offers surface). Returns the outcome.
    ///   * rejected → ts-guarded remove + post `foundryxSpeakerConfirmRejected`.
    ///   * authExpired / transient → NOTHING (the intent stays queued; the drain retries /
    ///     the drain's 401 seam re-auths). Returns nil.
    /// `ts` is the queue entry's timestamp (from `enqueue`) so a stale ACK can't dequeue a
    /// newer rename. Idempotent + offline-safe.
    @discardableResult
    public static func backgroundShip(
        captureId: String,
        slot: String,
        name: String?,
        speakerId: String?,
        ts: UInt64,
        baseDir: URL,
        deadline: TimeInterval = defaultDeadline,
        ship: @escaping @Sendable () async throws -> ConfirmOutcome,
        /// Read the second place back and say whether it holds this confirmation LIVE.
        ///
        /// ⚠ THIS PARAMETER IS THE CRITERION. Without it "landed" meant "the POST
        /// returned", and a confirmation that never actually took still removed its queue
        /// entry and posted `.synced` — so the owner saw a name stick, the queue forgot
        /// it, and nothing ever retried. Against 1,005 taggable captures there are 17
        /// confirmations, the last on 2026-07-17.
        ///
        /// `nil` keeps the old behaviour for callers that cannot read back (tests, and
        /// paths with no door). That is deliberate and NOT a silent default: a caller
        /// passing nothing is choosing the weaker contract explicitly at the call site.
        readBack: (@Sendable () async -> Bool)? = nil
    ) async -> ConfirmOutcome? {
        do {
            let outcome = try await withDeadline(deadline, ship: ship)
            // ⚠ AN HTTP 200 IS NOT EVIDENCE. AC5a: a confirmation reads as landed ONLY
            // when a read-back proves the second place holds it live. A door can accept
            // the POST and still be serving a cached diarization, in which case the name
            // is not there and never will be.
            if let readBack, await readBack() == false {
                // NOT landed. The entry stays queued so the drain retries, and nothing
                // claims success — an unshipped confirmation must stay visibly unshipped.
                return nil
            }
            await Task.detached {
                SpeakerConfirmQueue.remove(captureId: captureId, slot: slot, ifTsMatches: ts, baseDir: baseDir)
                TranscriptCacheStore.confirmSpeaker(
                    captureId: captureId, slot: slot,
                    name: outcome.speakerName.isEmpty ? name : outcome.speakerName,
                    speakerId: outcome.speakerId.isEmpty ? speakerId : outcome.speakerId,
                    baseDir: baseDir)
            }.value
            await SpeakerConfirmSync.postSynced(outcome)
            return outcome
        } catch {
            switch SpeakerShipDisposition.classify(error) {
            case .rejected:
                await Task.detached {
                    SpeakerConfirmQueue.remove(captureId: captureId, slot: slot, ifTsMatches: ts, baseDir: baseDir)
                }.value
                await SpeakerConfirmSync.postRejected(captureId: captureId, slot: slot, name: name)
            case .authExpired, .transient, .synced:
                break   // stays queued — the drain retries / re-auths; never a scary error
            }
            return nil
        }
    }

    /// Ship every queued speaker confirm (the 5s-drain retry leg), classifying each entry:
    ///   * synced       → ts-guarded remove + `onSynced(entry, outcome)` (write-through +
    ///                    post synced), then CONTINUE.
    ///   * authExpired  → `onAuthExpired()` and STOP — retrying an expired sign-in every 5s
    ///                    can never succeed (observed 2026-07-17: a silent ExpiredSignature
    ///                    401 loop). The confirms stay queued for after re-authentication.
    ///   * rejected     → ts-guarded remove + `onRejected(entry)`, then CONTINUE (a bad
    ///                    entry must not wedge the drain behind it).
    ///   * transient    → STOP (hub unreachable / 5xx) — keep the rest queued, retry next
    ///                    drain.
    /// `ship` now returns the `ConfirmOutcome` so callers can reconcile the canonical
    /// name/id and surface offers. Extracted from `CaptureManager.retryPendingSpeakerConfirms`
    /// so the behavior is drivable by the brine step-defs without a network.
    ///
    /// Every ship is TIME-BOXED (`deadline`), exactly as the interactive `backgroundShip`
    /// already was. It wasn't: the drain leg inherited whatever the transport felt like
    /// (30–90s URLSession timeouts; the relay mux leg, none at all), so one wedged round trip
    /// parked the whole confirm lane. A deadline classifies `.transient`, so the entry stays
    /// durably queued and the next drain re-ships it — no intent is ever lost by timing out.
    public static func drainPending(
        baseDir: URL,
        deadline: TimeInterval = defaultDeadline,
        ship: @escaping @Sendable (SpeakerConfirmQueue.Entry) async throws -> ConfirmOutcome,
        onSynced: @Sendable (SpeakerConfirmQueue.Entry, ConfirmOutcome) async -> Void = { _, _ in },
        onRejected: @Sendable (SpeakerConfirmQueue.Entry) async -> Void = { _ in },
        onAuthExpired: @MainActor () -> Void
    ) async {
        let entries = await Task.detached { SpeakerConfirmQueue.pending(baseDir: baseDir) }.value
        guard !entries.isEmpty else { return }
        for e in entries {
            do {
                let outcome = try await withDeadline(deadline) { try await ship(e) }
                await Task.detached {
                    SpeakerConfirmQueue.remove(captureId: e.captureId, slot: e.slot,
                                               ifTsMatches: e.ts, baseDir: baseDir)
                }.value
                await onSynced(e, outcome)
            } catch {
                switch SpeakerShipDisposition.classify(error) {
                case .authExpired:
                    await onAuthExpired()
                    return
                case .rejected:
                    await Task.detached {
                        SpeakerConfirmQueue.remove(captureId: e.captureId, slot: e.slot,
                                                   ifTsMatches: e.ts, baseDir: baseDir)
                    }.value
                    await onRejected(e)
                    continue
                case .transient, .synced:
                    return   // hub unreachable — keep the rest queued, retry next drain
                }
            }
        }
    }

    /// Race `ship` against a wall-clock deadline. On deadline `DeadlineExceeded` is thrown
    /// (classified `.transient`) and the ship task is cancelled best-effort.
    ///
    /// The race primitive itself now lives in `AsyncDeadline` so the pending-remote-delete
    /// drain can share it (same unstructured shape, same semantics — see that file for the
    /// adversarial-review P1 reasoning). This wrapper keeps the error TYPE the confirm lane's
    /// `SpeakerShipDisposition.classify` matches on.
    struct DeadlineExceeded: Error {}
    static func withDeadline(
        _ seconds: TimeInterval,
        ship: @escaping @Sendable () async throws -> ConfirmOutcome
    ) async throws -> ConfirmOutcome {
        try await AsyncDeadline.race(seconds, timeoutError: { DeadlineExceeded() }, work: ship)
    }
}

// MARK: - sync notification posting (one place)

/// The single place both ship legs (interactive background + drain) post the sync
/// notifications, so the userInfo shape can never drift.
public enum SpeakerConfirmSync {
    @MainActor public static func postSynced(_ outcome: ConfirmOutcome) {
        NotificationCenter.default.post(
            name: .foundryxSpeakerConfirmSynced, object: nil,
            userInfo: ["outcome": outcome])
    }

    @MainActor public static func postRejected(captureId: String, slot: String, name: String?) {
        var info: [AnyHashable: Any] = ["captureId": captureId, "slot": slot]
        if let name { info["name"] = name }
        NotificationCenter.default.post(
            name: .foundryxSpeakerConfirmRejected, object: nil, userInfo: info)
    }
}

// MARK: - the ship leg

/// Builds the ship closure a confirm flow uses — the real `DoorClient.confirmSpeaker`
/// call. DEBUG `-ConfirmProof <mode>` substitutes a deterministic stub so the simulator
/// can screenshot the flow without a live door (precedent: `-AudioProof`). Modes:
///   * `ok-slow`          — a visible in-flight beat, then a confirmed outcome.
///   * `fail`             — a transport failure (stays quietly pending).
///   * `offline-then-ack` — the INTERACTIVE ship always fails transport (so the save reads
///                          instant-local + pending glyph); the DRAIN's ship (in
///                          `CaptureManager.retryPendingSpeakerConfirms`) succeeds ~10s
///                          after launch, clearing the glyph — the local-first proof.
/// Never active outside DEBUG.
public enum ConfirmShip {
    /// The active `-ConfirmProof` mode, or nil. Exposed so the drain leg can honor
    /// `offline-then-ack` in DEBUG.
    public static var proofMode: String? {
        #if DEBUG
        let a = ProcessInfo.processInfo.arguments
        if let i = a.firstIndex(of: "-ConfirmProof"), i + 1 < a.count { return a[i + 1] }
        #endif
        return nil
    }

    public static func make(target: DoorTarget, captureId: String, slot: String,
                            name: String? = nil, speakerId: String? = nil,
                            entityId: String? = nil)
        -> @Sendable () async throws -> ConfirmOutcome {
        #if DEBUG
        if let mode = proofMode {
            let resolved = (name?.isEmpty == false ? name! : "Nick")
            return {
                try? await Task.sleep(nanoseconds: 300_000_000)   // a brief wire beat
                // The interactive ship fails offline in this mode; the DRAIN ACKs later.
                if mode == "fail" || mode == "offline-then-ack" {
                    throw DoorError.transport("confirm-proof")
                }
                return ConfirmOutcome(captureId: captureId, slotLabel: slot,
                                      status: "confirmed",
                                      speakerId: entityId ?? "proof-speaker",
                                      speakerName: resolved, offeredCaptures: [])
            }
        }
        #endif
        return {
            try await DoorClient(target: target).confirmSpeaker(
                captureId: captureId, slot: slot, speakerId: speakerId, name: name,
                entityId: entityId)
        }
    }
}

// MARK: - per-slot phase controller (the inline affordance's state machine)

/// Owns the per-slot confirm phases for one transcript surface. The UI binds its inline
/// "Confirm: <name>" affordances to `phase(for:)`; `confirm(...)` runs the LOCAL-FIRST
/// flow: durably enqueue (the brief in-flight beat) → optimistic local apply +
/// `.confirmed` immediately → background ship detached from the phase machine. The
/// `.confirmed` check dwells briefly then clears back to the row's own rendering (which,
/// via the pending overlay, already shows the saved name with its sync glyph).
@MainActor
public final class SpeakerConfirmController: ObservableObject {
    @Published public private(set) var phases: [String: SpeakerConfirmPhase] = [:]

    private let baseDir: URL
    private let deadline: TimeInterval
    /// How long `.confirmed` lingers before clearing back to the row's own rendering.
    private let successDwell: TimeInterval

    /// Torn down with the controller so a released surface stops reconciling.
    private var syncObserver: NSObjectProtocol?

    public init(baseDir: URL,
                deadline: TimeInterval = SpeakerConfirmFlow.defaultDeadline,
                successDwell: TimeInterval = 1.8) {
        self.baseDir = baseDir
        self.deadline = deadline
        self.successDwell = successDwell
        // ⚠ THE ONLY PLACE `.confirmed` IS REACHED. The local save leaves the row at
        // `pendingSync`; ONLY the second place's acknowledgement promotes it. Without this
        // observer the phase would never reach `.confirmed` at all — which is not a stricter
        // machine but a broken one, and is why the paired test asserts an acknowledged
        // confirmation DOES read confirmed.
        syncObserver = NotificationCenter.default.addObserver(
            forName: .foundryxSpeakerConfirmSynced, object: nil, queue: .main
        ) { [weak self] note in
            guard let outcome = note.userInfo?["outcome"] as? ConfirmOutcome else { return }
            MainActor.assumeIsolated {
                guard let self else { return }
                // Promote only a row this surface has pending — never invent a phase for a
                // slot the owner never touched here.
                if self.phases[outcome.slotLabel] == .pendingSync {
                    self.phases[outcome.slotLabel] = .confirmed
                    let dwell = self.successDwell
                    Task { [weak self] in
                        try? await Task.sleep(nanoseconds: UInt64(dwell * 1_000_000_000))
                        if let self, self.phases[outcome.slotLabel] == .confirmed {
                            self.phases[outcome.slotLabel] = nil
                        }
                    }
                }
            }
        }
    }

    // No explicit removal in `deinit`: the token is not Sendable and a nonisolated deinit
    // cannot touch it. The observer holds `self` WEAKLY, so a released controller stops
    // reconciling on its own and the block becomes a no-op.

    public func phase(for slot: String) -> SpeakerConfirmPhase { phases[slot] ?? .idle }

    /// Run one LOCAL-FIRST confirm for `slot`. `onConfirmed` fires the instant the local
    /// save lands (the optimistic label flip) with a locally-built outcome. The background
    /// ship then reconciles the canonical outcome via `foundryxSpeakerConfirmSynced`.
    /// Returns the resolved phase (`.confirmed` on the local save) for tests.
    @discardableResult
    public func confirm(
        captureId: String,
        slot: String,
        name: String? = nil,
        speakerId: String? = nil,
        ship: @escaping @Sendable () async throws -> ConfirmOutcome,
        onConfirmed: @escaping (ConfirmOutcome) -> Void = { _ in }
    ) async -> SpeakerConfirmPhase {
        // Re-entrancy guard: a second tap (or a stale retry) while this slot is already
        // in flight must not start a second enqueue+ship.
        guard phases[slot] != .inFlight else { return phase(for: slot) }
        phases[slot] = .inFlight
        // Durable FIRST, OFF the calling actor — the queue's file read+rewrite must never
        // hang the tap. Await so the intent is on disk before we claim success; the
        // returned `ts` guards the background ship's later dequeue.
        let base = baseDir
        let ts = await Task.detached {
            SpeakerConfirmQueue.enqueue(captureId: captureId, slot: slot,
                                        name: name, speakerId: speakerId, baseDir: base)
        }.value
        // The local outcome still fires immediately — the tap must not wait on the network.
        // What changed is the PHASE: the row reads `pendingSync`, not `confirmed`, until the
        // second place acknowledges. Claiming `confirmed` here is what made an unlanded
        // confirmation read as a landed one.
        onConfirmed(ConfirmOutcome(captureId: captureId, slotLabel: slot, status: "pending",
                                   speakerId: speakerId ?? "", speakerName: name ?? "",
                                   offeredCaptures: []))
        phases[slot] = .pendingSync
        // Background ship — detached from the phase machine. On ACK it reconciles via the
        // synced notification; on failure it stays quietly pending (drain retries).
        let dl = deadline
        Task.detached {
            await SpeakerConfirmFlow.backgroundShip(
                captureId: captureId, slot: slot, name: name, speakerId: speakerId,
                ts: ts, baseDir: base, deadline: dl, ship: ship)
        }
        // The confirmed check lingers, then clears back to the row's rendering. It clears
        // ONLY from `.confirmed`: a `pendingSync` row must keep saying so until it lands or the
        // drain gives up, or the distinction this phase exists for would evaporate on a timer.
        let dwell = successDwell
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(dwell * 1_000_000_000))
            if let self, self.phases[slot] == .confirmed { self.phases[slot] = nil }
        }
        return phase(for: slot)
    }
}

// MARK: - observable per-conversation sync state (the pending glyph + revert notices)

/// The UI-facing sync state for ONE open conversation: which slots have a still-pending
/// (un-synced) confirm — drives the subtle "waiting to sync" glyph — plus transient revert
/// notices for the rare rejection. Rides the queue-change + rejection notifications so the
/// glyph clears the instant the Mac ACKs and a rejection reverts gently. `@MainActor`
/// ObservableObject; the view owns one per conversation.
@MainActor
public final class SpeakerSyncModel: ObservableObject {
    /// The still-pending confirm entries for THIS capture (the pending overlay consumes
    /// them; the glyph shows for their slots).
    @Published public private(set) var pending: [SpeakerConfirmQueue.Entry] = []
    /// Transient revert notices keyed by slot (auto-clear ~6s).
    @Published public private(set) var notices: [String: String] = [:]

    private var captureId: String = ""
    private var baseDir: URL = URL(fileURLWithPath: NSTemporaryDirectory())
    private let noticeDwell: TimeInterval
    private var bound = false
    /// Monotonic refresh generation. Each `refresh()` reads the queue on a detached task;
    /// two notifications close together (enqueue then remove) start two reads whose
    /// MainActor writes can land in EITHER order. Stamping each read and dropping a result
    /// older than the newest already applied keeps the pending glyph from settling stale
    /// (review P2#3).
    private var refreshGen: UInt64 = 0
    private var appliedGen: UInt64 = 0
    // nonisolated(unsafe): mutated only on the main actor; deinit (nonisolated in
    // Swift 6) must still read it to unregister the notification observers.
    private nonisolated(unsafe) var observers: [NSObjectProtocol] = []

    /// Empty init for the SwiftUI `@StateObject` default-value path — call `bind` once the
    /// capture id is known (in `.onAppear`). Observers/refresh start on bind.
    public init(noticeDwell: TimeInterval = 6) {
        self.noticeDwell = noticeDwell
    }

    /// Bind-at-init for tests + direct callers that know the capture id up front.
    public convenience init(captureId: String, baseDir: URL, noticeDwell: TimeInterval = 6) {
        self.init(noticeDwell: noticeDwell)
        bind(captureId: captureId, baseDir: baseDir)
    }

    /// Attach to a capture's durable queue: start observing queue-change + rejection
    /// notifications and load the current pending state. Idempotent (a re-appearing view
    /// won't double-bind).
    public func bind(captureId: String, baseDir: URL) {
        guard !bound else { return }
        bound = true
        self.captureId = captureId
        self.baseDir = baseDir
        refresh()
        let capId = captureId
        observers.append(NotificationCenter.default.addObserver(
            forName: .foundryxSpeakerConfirmQueueChanged, object: nil, queue: .main) { [weak self] note in
                guard (note.userInfo?["captureId"] as? String) == capId else { return }
                MainActor.assumeIsolated { self?.refresh() }
            })
        observers.append(NotificationCenter.default.addObserver(
            forName: .foundryxSpeakerConfirmRejected, object: nil, queue: .main) { [weak self] note in
                guard (note.userInfo?["captureId"] as? String) == capId,
                      let slot = note.userInfo?["slot"] as? String else { return }
                let name = note.userInfo?["name"] as? String
                MainActor.assumeIsolated { self?.showRevertNotice(slot: slot, name: name) }
            })
    }

    deinit { observers.forEach { NotificationCenter.default.removeObserver($0) } }

    /// The slots with a pending (un-synced) confirm — the glyph shows for these.
    public var pendingSlots: Set<String> { Set(pending.map(\.slot)) }
    public func isPending(_ slot: String) -> Bool { pendingSlots.contains(slot) }

    /// Re-read the durable queue for THIS capture. Cheap (a small jsonl file). The read is
    /// off-main and generation-stamped so an older read's result can never overwrite a newer
    /// one's (out-of-order settle → a stuck glyph after an ACK; review P2#3).
    public func refresh() {
        let capId = captureId
        let base = baseDir
        refreshGen &+= 1
        let gen = refreshGen
        Task.detached { [weak self] in
            let all = SpeakerConfirmQueue.pending(baseDir: base).filter { $0.captureId == capId }
            await MainActor.run {
                guard let self, gen >= self.appliedGen else { return }
                self.appliedGen = gen
                self.pending = all
            }
        }
    }

    /// Honest, non-technical, non-scary copy for a rejection revert.
    public static func revertMessage(name: String?) -> String {
        if let name, !name.isEmpty {
            return "Your computer couldn't apply \(name) — reverted."
        }
        return "Your computer couldn't apply that change — reverted."
    }

    private func showRevertNotice(slot: String, name: String?) {
        notices[slot] = Self.revertMessage(name: name)
        refresh()   // the entry was dropped — clear the glyph
        let dwell = noticeDwell
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(dwell * 1_000_000_000))
            self?.notices[slot] = nil
        }
    }
}
