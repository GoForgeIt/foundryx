import Foundation

/// **WHAT THE OWNER PICKED, AND IN WHAT ORDER.**
///
/// A recorder holds nineteen recordings. Before this existed the owner's only choices were one at a
/// time or all of them — so an owner who wanted three, most-important first, took one, waited, took
/// the next. **Order is the difference between a queue the owner authored and a queue the device
/// authored.**
///
/// ## THIS TYPE IS TOLD WHAT IS SELECTABLE. IT NEVER DECIDES.
///
/// It holds a list of selectable recordings — in practice `PocketTransferJob.derivedBacklog`'s
/// output, which already dedupes the listing and excludes anything held that also has a
/// conversation — and it refuses anything outside that list.
///
/// It does this because the two obvious alternatives are both wrong:
///
///   * **Asking custody** would mean `await`, because `alreadyHeld` and `conversation(for:)` are
///     `async` protocol methods. A value that must await to decide whether a tap is legal is not a
///     value, and an `await` behind a row tap is exactly what the sibling journey track's AC9
///     forbids.
///   * **Asking the transfer job** would mean widening `stoppedRequests`, which is `private` for a
///     reason: it is the job's own record of the owner's stop decisions, and its privacy is why
///     `stop` is "the difference between a stop button and a decoration".
///
/// So: told, never asking. No `await` is reachable from a tap, and nothing here needs a lock.
///
/// ## IDENTITY IS `request`, NOT `PocketRecording`
///
/// `PocketRecordingRequest` is `Hashable`; `PocketRecording` is only `Equatable`. `enqueue`
/// deduplicates on `request` and so does this — deliberately the same key, because a selection that
/// counted differently from the queue is the consent defect below.
///
/// ## ⚠ RE-SELECTING PUTS A RECORDING AT THE END, AND THAT IS ON PURPOSE
///
/// An owner who deselected something and later changed their mind is making a **new** decision.
/// Silently restoring its old priority would be the surface deciding on their behalf — it would say
/// "you wanted this second" when what they said was "I want this now". Do not "fix" this to
/// preserve position.
///
/// ## THE COUNT THIS PRODUCES IS A COUNT SOMEBODY CONSENTS TO
///
/// `PocketTransferJob.derivedBacklog`'s own comment records what happens when it is not:
///
/// > *"`enqueue` deduplicates on `request`, so the button said "Bring all 2 over" and the queue took
/// > one: **a number a person consents to that is larger than the set**."*
///
/// `count` is what a surface may promise. Whether the queue then accepts that many is a separate
/// fact, measured separately — see `PocketSelectionFeatureTests`.
public struct PocketSelection: Sendable, Equatable {

    /// The recordings the owner may pick from. Supplied, never derived here.
    public let selectable: [PocketRecording]

    /// The picks, in the order they were made. First tapped is first brought over.
    public private(set) var picked: [PocketRecordingRequest]

    public init(selectable: [PocketRecording]) {
        self.selectable = selectable
        self.picked = []
    }

    /// Is this recording one the owner may pick at all?
    public func isSelectable(_ request: PocketRecordingRequest) -> Bool {
        selectable.contains { $0.request == request }
    }

    public func isPicked(_ request: PocketRecordingRequest) -> Bool {
        picked.contains(request)
    }

    /// How many the owner has chosen. **This is the number a surface may promise.**
    public var count: Int { picked.count }

    /// Pick one. Outside the selectable list is a no-op; picking twice is one selection and leaves
    /// the order untouched.
    public mutating func select(_ request: PocketRecordingRequest) {
        guard isSelectable(request), !picked.contains(request) else { return }
        picked.append(request)
    }

    /// Un-pick one. Everything else keeps its position.
    public mutating func deselect(_ request: PocketRecordingRequest) {
        picked.removeAll { $0 == request }
    }

    public mutating func toggle(_ request: PocketRecordingRequest) {
        if isPicked(request) { deselect(request) } else { select(request) }
    }

    /// The recordings, in the owner's order, ready for `PocketTransferJob.enqueue`.
    ///
    /// `enqueue` preserves the caller's array order, so this IS the drain order.
    public var orderedRecordings: [PocketRecording] {
        picked.compactMap { request in
            selectable.first { $0.request == request }
        }
    }
}
