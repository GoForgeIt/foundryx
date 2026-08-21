// PocketRadioArbiter.swift — ONE RADIO, ONE ERRAND, ACROSS TWO COMPONENTS THAT CANNOT SEE EACH OTHER.
//
// `20260821T0153_the_drain_survives_termination` P3.0, and it comes FIRST in Phase 3 because the
// automatic trigger is not safe without it.
//
// WHAT BREAKS WITHOUT THIS. `PocketRecorderCheckModel.inFlight` is a field on the recorder PAGE
// (`App/DeviceScreen.swift:1940,1948`), and manual bring-over consults only it (`:2671`). That was
// correct while a person tapping a button was the only way to start anything: one screen, one
// flag, one errand. An automatic drain has no screen. So a drain running in the background while
// the owner opens the page gives a fresh page model that sees no local errand — and it opens a
// SECOND authenticated session on ONE phone, against hardware that permits one.
//
// AC16 covers a session another PHONE opened. Nothing covered two components inside this one, and
// a cross-vendor review of the plan named it.
//
// WHY A LEASE AND NOT A FLAG. A flag is set and cleared, and the clearing is what gets lost — a
// crashed errand, an early return, a task cancelled between the two. A lease is HELD, and a holder
// that goes away releases it whether or not it remembered to. The owner's tap must also be able to
// take the radio from a background drain, because a person waiting is worth more than a drain that
// can restart; so the lease records WHO holds it and the manual path may pre-empt.

import Foundation

/// Who wants the radio. Ranked: a person waiting outranks work that can be redone later.
public enum PocketRadioClaimant: Sendable, Equatable, Comparable {
    /// A background drain nobody is watching.
    case automaticDrain
    /// A restoration recovering from a kill. Above the drain because it clears wreckage the drain
    /// would otherwise trip over.
    case restorationRecovery
    /// Somebody tapped something and is looking at a screen.
    case owner

    private var rank: Int {
        switch self {
        case .automaticDrain: return 0
        case .restorationRecovery: return 1
        case .owner: return 2
        }
    }
    public static func < (a: Self, b: Self) -> Bool { a.rank < b.rank }
}

/// The outcome of asking for the radio. Never a bare bool: "no" and "no, and here is who has it"
/// are different answers, and only the second lets a surface say something true to a person.
public enum PocketRadioGrant: Sendable, Equatable {
    case granted(PocketRadioLease)
    /// Refused because somebody with an equal or better claim holds it.
    case heldBy(PocketRadioClaimant)
}

/// Proof of holding the radio. **Releasing is `deinit`, not a method a caller must remember** —
/// the clearing is the half that gets lost, so it is not left to a caller at all.
public final class PocketRadioLease: @unchecked Sendable, Equatable {
    public let claimant: PocketRadioClaimant
    private weak var arbiter: PocketRadioArbiter?
    private let id: UUID

    fileprivate init(claimant: PocketRadioClaimant, arbiter: PocketRadioArbiter, id: UUID) {
        self.claimant = claimant
        self.arbiter = arbiter
        self.id = id
    }

    deinit { arbiter?.release(id) }

    public static func == (a: PocketRadioLease, b: PocketRadioLease) -> Bool { a.id == b.id }
}

/// The single place that knows whether this phone's radio is busy.
public final class PocketRadioArbiter: @unchecked Sendable {
    private let lock = NSLock()
    private var holder: (claimant: PocketRadioClaimant, id: UUID)?

    public init() {}

    /// Who has the radio, if anybody.
    public var currentHolder: PocketRadioClaimant? {
        lock.withLock { holder?.claimant }
    }

    /// Ask for the radio.
    ///
    /// **A strictly higher claim PRE-EMPTS a lower one**: an owner's tap takes the radio from a
    /// background drain, because the drain can start again and the person is waiting now. An equal
    /// claim does NOT pre-empt — two automatic drains racing each other is the failure this type
    /// exists to prevent, not a case to arbitrate.
    public func claim(_ claimant: PocketRadioClaimant) -> PocketRadioGrant {
        lock.lock()
        if let held = holder, claimant <= held.claimant {
            let who = held.claimant
            lock.unlock()
            return .heldBy(who)
        }
        let id = UUID()
        holder = (claimant, id)
        lock.unlock()
        return .granted(PocketRadioLease(claimant: claimant, arbiter: self, id: id))
    }

    /// Called by a lease's `deinit`. Ignores a stale id, so a pre-empted holder's release cannot
    /// take the radio away from whoever pre-empted it — the bug a naive "clear the flag" release
    /// would have.
    fileprivate func release(_ id: UUID) {
        lock.withLock { if holder?.id == id { holder = nil } }
    }
}
