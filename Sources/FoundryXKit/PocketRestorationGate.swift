// PocketRestorationGate.swift — WHAT A RESTORED RADIO IS ALLOWED TO HAND THE APP.
//
// `20260821T0153_the_drain_survives_termination` Phase 2, task P2.1 — and it is first in that
// phase because it is the mechanism the rest of the ordering rests on.
//
// THE HAZARD. iOS can restore a peripheral with LIVE SUBSCRIPTIONS, mid-file. The transport
// survives; nothing above it does. The `PocketBLEClient` that knew the protocol, the meter that
// knew how many bytes were expected, and the writer that owned the `.partial` are all gone with
// the process. A rebind that simply installs a delegate then receives chunks belonging to a
// transfer THIS PROCESS NEVER STARTED, with no way to know what they are or how many should
// follow. **Those bytes must never be committed.**
//
// WHY "DISCARD FIRST" IS NOT ENOUGH ON ITS OWN, which a cross-vendor review of the spec named:
// it states an ORDER, and an order is not a mechanism. `BluetoothSeam.routeEventsToSink()` is
// what installs the peripheral delegate (`BluetoothSeam.swift:327`), and the Omi path calls it
// IMMEDIATELY on `willRestoreState` (`DeviceManager.swift:1056`). Any Pocket coordinator that
// copies that shape installs its sink and then begins discarding asynchronously — and a
// notification arriving in between reaches a fresh parser. The window is real by construction.
//
// SO THE GATE IS A GENERATION, ESTABLISHED SYNCHRONOUSLY BEFORE THE DELEGATE IS INSTALLED.
// Everything the radio delivers carries the generation that was current when its transfer began.
// A restored stream carries a generation this process never issued, so it is refused at ingress —
// before a writer exists, not after one has been handed bytes.
//
// A NOTE ON WHAT THIS DELIBERATELY DOES NOT DO. It does not try to salvage the partial transfer.
// The protocol has no offset resume: `PocketTransferJob` restarts a recording from byte zero
// (`:17,20`). Salvage would mean guessing which bytes belong where, on a file whose expected
// length this process does not know.

import Foundation

/// A monotonically increasing stamp identifying which run of the app opened a transfer.
///
/// It is not a timestamp: two launches inside the same second must differ, and a clock that moves
/// backwards must not make an old generation look current.
public struct PocketTransferGeneration: Sendable, Equatable, Hashable, Comparable, Codable {
    public let value: UInt64
    public init(_ value: UInt64) { self.value = value }
    public static func < (a: Self, b: Self) -> Bool { a.value < b.value }
}

/// WHY A DELIVERY WAS REFUSED, as a value. Never a bare `false`: an operator reading a log needs
/// to tell "this is from a previous life of the app" from "nothing is running".
public enum PocketIngressVerdict: Sendable, Equatable {
    /// This process opened the transfer these bytes belong to.
    case accept
    /// The bytes carry a generation this process never issued — a restored stream mid-file.
    case refuseRestoredStream(carried: PocketTransferGeneration,
                              current: PocketTransferGeneration)
    /// Nothing is open. A delivery with no transfer to belong to.
    case refuseNoTransferOpen

    public var isAccepted: Bool { self == .accept }
}

/// THE GATE ITSELF. Cheap, synchronous, and answerable before any writer is constructed.
///
/// Deliberately a plain value with a lock rather than an actor: an actor's `await` is the
/// asynchronous gap this type exists to close. The whole point is that the question can be
/// answered in the same turn the delivery arrives.
public final class PocketRestorationGate: @unchecked Sendable {
    private let lock = NSLock()
    private let current: PocketTransferGeneration
    private var openTransfer: PocketTransferGeneration?
    private var refusals: [PocketIngressVerdict] = []

    /// Starts one generation past whatever the previous run reached, so a stream restored from
    /// that run can never carry the current stamp.
    public init(startingAfter previous: PocketTransferGeneration? = nil) {
        current = PocketTransferGeneration((previous?.value ?? 0) + 1)
    }

    /// The generation a transfer opened NOW would carry.
    public var generation: PocketTransferGeneration {
        lock.lock(); defer { lock.unlock() }; return current
    }

    /// Open a transfer in this process. The returned stamp is what its deliveries must carry.
    @discardableResult
    public func openTransferInThisProcess() -> PocketTransferGeneration {
        lock.lock(); defer { lock.unlock() }
        openTransfer = current
        return current
    }

    /// Close it. A delivery arriving afterwards is refused for having no transfer, which is a
    /// different fact from carrying a stale generation and is reported as one.
    public func closeTransfer() {
        lock.lock(); defer { lock.unlock() }
        openTransfer = nil
    }

    /// THE QUESTION, ASKED AT INGRESS. Called before a writer exists, not after.
    public func admit(_ carried: PocketTransferGeneration) -> PocketIngressVerdict {
        lock.lock(); defer { lock.unlock() }
        guard let open = openTransfer else {
            let verdict = PocketIngressVerdict.refuseNoTransferOpen
            refusals.append(verdict)
            return verdict
        }
        guard carried == open else {
            let verdict = PocketIngressVerdict.refuseRestoredStream(carried: carried,
                                                                    current: open)
            refusals.append(verdict)
            return verdict
        }
        return .accept
    }

    /// EVERYTHING THE GATE TURNED AWAY. The count is the observable that makes a refusal
    /// provable — a gate that silently drops is indistinguishable from one that never ran.
    public var refusalsSoFar: [PocketIngressVerdict] {
        lock.lock(); defer { lock.unlock() }; return refusals
    }

    /// Finish reconciling a restoration: whatever the restored run left open is no longer open.
    ///
    /// AN EARLIER VERSION ALSO INCREMENTED `current`, "so the next transfer cannot be confused
    /// with anything that preceded it". **Mutation testing killed that line and nothing went
    /// red** — because `init(startingAfter:)` already guarantees this run's generation exceeds
    /// the previous run's, so a restored stream is refused with or without the increment. Rather
    /// than invent a scenario to justify it, the redundant state change was removed: **a line
    /// whose deletion breaks nothing is a line that is not doing the work its comment claims.**
    public func reconcileRestoration() {
        lock.lock(); defer { lock.unlock() }
        openTransfer = nil
    }
}
