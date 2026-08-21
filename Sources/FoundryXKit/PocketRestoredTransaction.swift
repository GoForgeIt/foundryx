// PocketRestoredTransaction.swift — WHAT A RESTORED SESSION IS ALLOWED TO KEEP.
//
// `20260821T0153_the_drain_survives_termination` P2.2, and the criterion the whole phase exists
// for: **a restored session commits nothing it cannot account for.**
//
// `PocketRestorationGate` (P2.1) refuses restored bytes at ingress, before a writer exists. This
// is the second wall, and it exists because the first one can only refuse what it is ASKED about.
// A coordinator that forgets to ask — a new code path, a refactor, a well-meaning retry — reaches
// custody directly, and custody's job is to keep bytes, not to interrogate their provenance.
//
// SO THE DECISION IS A TYPE, NOT A CONVENTION. `PocketBringOver.keep` takes bytes and writes
// them; it has no way to know whether the run that opened the transfer is the run handing them
// over. This type answers that question BEFORE the payload is offered anywhere, and answers it
// from facts a caller cannot fake by being confident: the generation the bytes carry, and the
// count the recorder announced.
//
// WHY THE ANNOUNCED COUNT IS PART OF IT, and not only the generation. A restored stream is the
// obvious hazard. The subtler one is a transfer THIS process opened whose expected length it no
// longer knows — the announcement arrives once, on the wire, and a coordinator rebuilt mid-file
// has missed it. Bytes with no expected total cannot be checked against anything, so a commit
// would be an assertion rather than a verification. `PocketBringOver`'s writer already re-reads
// and compares a digest, but a digest proves the bytes ARRIVED INTACT, not that they are ALL of
// them. A truncated file with a correct digest is exactly the failure this refuses.

import Foundation

/// Whether a payload may be offered to custody at all.
public enum PocketCommitAdmission: Sendable, Equatable {
    /// This run opened the transfer and knows what it should weigh.
    case admit
    /// The bytes belong to a transfer another run of the app opened.
    case refuseRestoredStream
    /// This run opened it and never saw the recorder's announcement, so there is no total to
    /// check the payload against.
    case refuseNoAnnouncedTotal
    /// The payload does not weigh what the recorder said it would. **Refused rather than
    /// truncated**: a short file that passes its own digest is still a short file.
    case refuseByteCountMismatch(got: Int, announced: Int)

    public var isAdmitted: Bool { self == .admit }

    /// What an operator reads. Every refusal names its own reason — a bare "not kept" beside a
    /// recorder that plainly sent bytes is the kind of report that costs an evening.
    public var reason: String? {
        switch self {
        case .admit: return nil
        case .refuseRestoredStream:
            return "these bytes belong to a transfer a previous run of the app opened"
        case .refuseNoAnnouncedTotal:
            return "the recorder's announced size was never seen, so nothing can be checked"
        case .refuseByteCountMismatch(let got, let announced):
            return "\(got) bytes arrived and the recorder announced \(announced)"
        }
    }
}

public enum PocketRestoredTransaction {

    /// THE GATE ON KEEPING. Called before `PocketBringOver.keep`, never after.
    ///
    /// - Parameters:
    ///   - carried: the generation the delivering transfer was opened under.
    ///   - announced: the recorder's own `MCU&U&<n>`, or nil if this run never saw it.
    public static func admit(payload: Data,
                             carried: PocketTransferGeneration,
                             gate: PocketRestorationGate,
                             announced: Int?) -> PocketCommitAdmission {
        guard gate.admit(carried).isAccepted else { return .refuseRestoredStream }
        guard let announced else { return .refuseNoAnnouncedTotal }
        guard payload.count == announced else {
            return .refuseByteCountMismatch(got: payload.count, announced: announced)
        }
        return .admit
    }
}
