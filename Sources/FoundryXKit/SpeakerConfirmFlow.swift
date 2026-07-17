// SpeakerConfirmFlow — the ONE path a speaker confirm/save takes from a tap to an
// outcome the UI can render honestly (track 20260717T0900_speaker_confirm_feedback).
//
// Why: the inline "Confirm: <name>" affordance and the tag sheet used to fire the door
// call with no in-flight state, no success state, and no failure state — a lost relay
// response or an expired sign-in read exactly like nothing happening (Nick, b230).
// This flow makes every confirm:
//   1. DURABLE first — the intent is on disk (SpeakerConfirmQueue) before the wire.
//   2. DEADLINE-BOUNDED — a hung round-trip resolves to an honest `.unreachable`
//      instead of a dead button (the drain re-ships the queued intent later).
//   3. CLASSIFIED — the UI gets `confirmed | failed(authExpired|unreachable|rejected)`,
//      never a silent nothing.
//
// FoundryXKit (UI-free): pure state + copy + an injectable `ship` closure, so the
// brine step-defs drive the REAL flow hermetically.

import Foundation

// MARK: - phases + failures (what the UI renders)

/// The lifecycle of one confirm affordance. The UI must flip to `.inFlight` within one
/// frame of the tap and may only show `.confirmed` when the door ACKNOWLEDGED the
/// confirm — never on hope.
public enum SpeakerConfirmPhase: Equatable, Sendable {
    case idle
    case inFlight
    case confirmed
    case failed(SpeakerConfirmFailure)
}

/// Why a confirm did not complete. The intent is ALWAYS kept durably queued on
/// failure — these distinguish what the user should be told (and whether a retry
/// right now can help).
public enum SpeakerConfirmFailure: Error, Equatable, Sendable {
    /// The door rejected our sign-in (401 / expired id_token). A retry cannot succeed
    /// until re-authentication; the queue keeps the intent for after that.
    case authExpired
    /// The computer could not be reached (transport failure, or the round trip blew
    /// the deadline — the b230 lost-relay-response class). Retry may help; the drain
    /// re-ships regardless.
    case unreachable
    /// The door/Lore answered with an error status — the confirm was actively refused.
    case rejected(Int)

    /// Map a thrown error from the ship leg onto the honest failure class.
    public static func classify(_ error: Error) -> SpeakerConfirmFailure {
        if let door = error as? DoorError {
            switch door {
            case .unauthorized: return .authExpired
            case .http(let code): return .rejected(code)
            case .transport: return .unreachable
            }
        }
        return .unreachable   // cancellation/timeout/URLSession — the computer is out of reach
    }
}

/// What the tag sheet must do after a confirm attempt resolves. Pure — the SwiftUI
/// sheet just executes it, the brine step-defs assert it.
public enum SpeakerSheetReaction: Equatable, Sendable {
    /// Success with nothing more the user must see → the sheet dismisses ITSELF.
    case dismiss
    /// Success that matched past captures → surface the apply-to-past offer (stay).
    case showOffer(ConfirmOutcome)
    /// Failure → the sheet STAYS OPEN with the honest error (never a silent dismiss
    /// that reads exactly like success).
    case stayOpen(SpeakerConfirmFailure)
}

/// Honest, non-technical copy for a failed confirm. One source of truth so the inline
/// affordance and the tag sheet never drift apart.
public enum SpeakerConfirmPresentation {
    public struct FailureCopy: Equatable, Sendable {
        /// What happened + where the change lives now.
        public let message: String
        /// Whether an immediate retry is worth offering (false when only re-auth helps).
        public let retryable: Bool
    }

    /// The sheet's post-confirm behavior, decided in ONE place.
    public static func sheetReaction(
        _ result: Result<ConfirmOutcome, SpeakerConfirmFailure>
    ) -> SpeakerSheetReaction {
        switch result {
        case .success(let outcome):
            return outcome.offeredCaptures.isEmpty ? .dismiss : .showOffer(outcome)
        case .failure(let failure):
            return .stayOpen(failure)
        }
    }

    public static func failureCopy(_ failure: SpeakerConfirmFailure) -> FailureCopy {
        switch failure {
        case .authExpired:
            return FailureCopy(
                message: "Your sign-in expired — the change is saved on your phone and will sync after you reconnect.",
                retryable: false)
        case .unreachable:
            return FailureCopy(
                message: "Can't reach your computer — the change is saved on your phone and will sync automatically.",
                retryable: true)
        case .rejected:
            return FailureCopy(
                message: "Your computer couldn't apply this change. It's saved on your phone to try again.",
                retryable: true)
        }
    }
}

// MARK: - the flow

public enum SpeakerConfirmFlow {
    /// Default ceiling on one interactive confirm round trip. Past it the tap resolves
    /// to `.unreachable` (the durable queue still ships the intent on a later drain).
    /// The door answers in well under a second when healthy; 12s covers a slow relay
    /// leg without ever leaving a dead button.
    public static let defaultDeadline: TimeInterval = 12

    /// Run one confirm: durably enqueue the intent, race `ship` against `deadline`,
    /// and — only when the door acknowledged — dequeue and hand back the outcome.
    /// On ANY failure the intent stays queued (offline-safe, same ethos as pending
    /// finalizes/deletes) and the caller gets the classified failure to render.
    ///
    /// `ship` is the actual door call (`DoorClient.confirmSpeaker`); injected so tests
    /// drive the real flow without a network.
    public static func run(
        captureId: String,
        slot: String,
        name: String? = nil,
        speakerId: String? = nil,
        baseDir: URL,
        deadline: TimeInterval = defaultDeadline,
        ship: @escaping @Sendable () async throws -> ConfirmOutcome
    ) async -> Result<ConfirmOutcome, SpeakerConfirmFailure> {
        // Durable FIRST, but OFF the calling actor — the queue's file read+rewrite must
        // never hang the tap. Await so the intent is on disk before the wire (a crash
        // between them must not lose it).
        await Task.detached {
            SpeakerConfirmQueue.enqueue(captureId: captureId, slot: slot,
                                        name: name, speakerId: speakerId, baseDir: baseDir)
        }.value
        do {
            let outcome = try await withDeadline(deadline, ship: ship)
            // Acknowledged → the intent has shipped; drop it from the durable queue.
            await Task.detached {
                SpeakerConfirmQueue.remove(captureId: captureId, slot: slot, baseDir: baseDir)
            }.value
            return .success(outcome)
        } catch {
            return .failure(SpeakerConfirmFailure.classify(error))
        }
    }

    /// Ship every queued speaker confirm (the 5s-drain retry leg), stopping honestly:
    /// * transport failure → keep the rest queued, retry next drain (unchanged).
    /// * `DoorError.unauthorized` → fire `onAuthExpired` and STOP — retrying an
    ///   expired sign-in every 5s can never succeed (observed 2026-07-17: a silent
    ///   ExpiredSignature 401 loop, forever). The confirms stay queued for after
    ///   re-authentication.
    /// Extracted from `CaptureManager.retryPendingSpeakerConfirms` so the behavior is
    /// drivable by the brine step-defs without a network.
    public static func drainPending(
        baseDir: URL,
        ship: @Sendable (SpeakerConfirmQueue.Entry) async throws -> Void,
        onAuthExpired: @MainActor () -> Void
    ) async {
        let entries = await Task.detached { SpeakerConfirmQueue.pending(baseDir: baseDir) }.value
        guard !entries.isEmpty else { return }
        for e in entries {
            do {
                try await ship(e)
                let capId = e.captureId, slot = e.slot
                await Task.detached {
                    SpeakerConfirmQueue.remove(captureId: capId, slot: slot, baseDir: baseDir)
                }.value
            } catch DoorError.unauthorized {
                await onAuthExpired()
                break
            } catch {
                break   // hub unreachable — keep the rest queued, retry next drain
            }
        }
    }

    /// Race `ship` against a wall-clock deadline. On deadline `DeadlineExceeded` is
    /// thrown (classified `.unreachable`) and the ship task is cancelled best-effort.
    ///
    /// Deliberately UNSTRUCTURED (adversarial review P1): a task group cannot return
    /// until its children finish, so a ship leg parked on a non-cancellable
    /// continuation (the relay mux turn — the exact b230 lost-response hang) would
    /// defeat a group-based race and leave a forever-spinner. Here the deadline
    /// resumes the caller REGARDLESS; the orphaned ship task resolves (or is torn
    /// down with the transport) later, and its late result is discarded. The confirm
    /// is idempotent and stays durably queued, so nothing is lost either way.
    struct DeadlineExceeded: Error {}
    static func withDeadline(
        _ seconds: TimeInterval,
        ship: @escaping @Sendable () async throws -> ConfirmOutcome
    ) async throws -> ConfirmOutcome {
        let once = ResumeOnce()
        return try await withCheckedThrowingContinuation { cont in
            let shipTask = Task {
                do {
                    let outcome = try await ship()
                    await once.resume(cont, with: .success(outcome))
                } catch {
                    await once.resume(cont, with: .failure(error))
                }
            }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(max(0.05, seconds) * 1_000_000_000))
                await once.resume(cont, with: .failure(DeadlineExceeded()))
                shipTask.cancel()   // best-effort; a non-cancellable leg just gets orphaned
            }
        }
    }

    /// Single-resume gate for the deadline race — whichever side finishes first wins;
    /// the loser's result is discarded (never a double resume).
    private actor ResumeOnce {
        private var resumed = false
        func resume(_ cont: CheckedContinuation<ConfirmOutcome, Error>,
                    with result: Result<ConfirmOutcome, Error>) {
            guard !resumed else { return }
            resumed = true
            cont.resume(with: result)
        }
    }
}

// MARK: - the ship leg

/// Builds the ship closure a confirm flow uses — the real `DoorClient.confirmSpeaker`
/// call. DEBUG `-ConfirmProof <ok-slow|fail>` substitutes a deterministic stub so the
/// simulator can screenshot in-flight / success / failure without a live door
/// (precedent: `-AudioProof`). Never active outside DEBUG.
public enum ConfirmShip {
    public static func make(target: DoorTarget, captureId: String, slot: String,
                            name: String? = nil, speakerId: String? = nil)
        -> @Sendable () async throws -> ConfirmOutcome {
        #if DEBUG
        let a = ProcessInfo.processInfo.arguments
        if let i = a.firstIndex(of: "-ConfirmProof"), i + 1 < a.count {
            let mode = a[i + 1]
            let resolved = (name?.isEmpty == false ? name! : "Nick")
            return {
                try? await Task.sleep(nanoseconds: 1_500_000_000)   // visible in-flight beat
                if mode == "fail" { throw DoorError.transport("confirm-proof") }
                return ConfirmOutcome(captureId: captureId, slotLabel: slot,
                                      status: "confirmed", speakerId: "proof-speaker",
                                      speakerName: resolved, offeredCaptures: [])
            }
        }
        #endif
        return {
            try await DoorClient(target: target).confirmSpeaker(
                captureId: captureId, slot: slot, speakerId: speakerId, name: name)
        }
    }
}

// MARK: - per-slot phase controller (the UI's confirm state machine)

/// Owns the per-slot confirm phases for one transcript surface. The UI binds its
/// inline "Confirm: <name>" affordances to `phase(for:)`; `confirm(...)` runs the
/// durable flow and drives the phase transitions the feature scenarios assert:
/// tap → `.inFlight` within one frame → `.confirmed` (dwells briefly, then clears —
/// the row now renders the confirmed name itself) or `.failed` (sticky until retry).
@MainActor
public final class SpeakerConfirmController: ObservableObject {
    @Published public private(set) var phases: [String: SpeakerConfirmPhase] = [:]

    private let baseDir: URL
    private let deadline: TimeInterval
    /// How long `.confirmed` lingers before clearing back to the row's own rendering.
    private let successDwell: TimeInterval

    public init(baseDir: URL,
                deadline: TimeInterval = SpeakerConfirmFlow.defaultDeadline,
                successDwell: TimeInterval = 1.8) {
        self.baseDir = baseDir
        self.deadline = deadline
        self.successDwell = successDwell
    }

    public func phase(for slot: String) -> SpeakerConfirmPhase { phases[slot] ?? .idle }

    /// Run one confirm for `slot`. `onConfirmed` fires the instant the door
    /// acknowledges (the optimistic label flip); `onChanged` is the background
    /// authoritative reconcile. Returns the resolved phase (for tests).
    @discardableResult
    public func confirm(
        captureId: String,
        slot: String,
        name: String? = nil,
        speakerId: String? = nil,
        ship: @escaping @Sendable () async throws -> ConfirmOutcome,
        onConfirmed: @escaping (ConfirmOutcome) -> Void = { _ in },
        onChanged: @escaping () async -> Void = {}
    ) async -> SpeakerConfirmPhase {
        // Re-entrancy guard: a second tap (or a stale retry) while this slot is already
        // in flight must not start a second round trip.
        guard phases[slot] != .inFlight else { return .inFlight }
        phases[slot] = .inFlight
        let result = await SpeakerConfirmFlow.run(
            captureId: captureId, slot: slot, name: name, speakerId: speakerId,
            baseDir: baseDir, deadline: deadline, ship: ship)
        switch result {
        case .success(let outcome):
            onConfirmed(outcome)   // optimistic: the label flips in place NOW
            phases[slot] = .confirmed
            Task { await onChanged() }   // reconcile off the tap path
            let dwell = successDwell
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(dwell * 1_000_000_000))
                if let self, self.phases[slot] == .confirmed { self.phases[slot] = nil }
            }
        case .failure(let failure):
            phases[slot] = .failed(failure)
        }
        return phase(for: slot)
    }
}
