import Foundation

/// The terminal acknowledgement returned by account-bound live producers and
/// stale-work owners when an identity boundary asks them to quiesce.
public enum AccountExposureCloseResult: Sendable, Equatable {
    case closed
    case alreadyClosed
    case ownerMismatch
    case verificationFailed
    case unavailable
    case persistenceFailed
}

public extension AccountExposureCloseResult {
    /// The ONE classification the deletion exposure barrier is allowed to use.
    ///
    /// The barrier's question is not "did something go wrong?" — it is the much
    /// narrower "can anything belonging to the account being deleted still be
    /// rendered, or still complete into its data?". A result may only be accepted
    /// when it ANSWERS NO. Each case is decided on that question alone:
    ///
    /// - `.closed` — the participant closed its surface and said so. Proof.
    ///
    /// - `.alreadyClosed` — the participant looked and there was nothing open.
    ///   Proof.
    ///
    /// - `.unavailable` — there is no surface BELONGING TO THIS ACCOUNT to
    ///   close. Every site that produces it in this app means exactly that and
    ///   nothing else:
    ///     * `AccountExposureRegistration.closeHook` — the weak `owner` is gone,
    ///       so the object that could have rendered has been deallocated;
    ///     * `AccountExposureCoordinator.closeRegisteredExposures` and
    ///       `cancelRegisteredStaleWork` — `availableBinding` is nil, so the
    ///       participant was never bound to ANY account and therefore never held
    ///       this account's data;
    ///     * the same two functions again — the participant is bound to a
    ///       DIFFERENT account's scope, so whatever it can still render belongs
    ///       to someone else and none of it is this account's.
    ///   None of them mean "I could not verify". Treating this as a failure is
    ///   what shipped in TestFlight 771837: a Live Activity / widget participant
    ///   the person never configured registered, reported `.unavailable`, and
    ///   made "delete everything now" fail with `exposureBarrierFailed` FOREVER —
    ///   `recover()` re-ran the same barrier and failed identically, so there was
    ///   no way out on the device. Absence is the strongest possible proof that
    ///   nothing can leak, so it is terminal success.
    ///
    /// - `.ownerMismatch` — NOT accepted here. It says "you are not who I am
    ///   bound to", which is not the same claim as "I am closed", and it is
    ///   produced by comparing bindings rather than by inspecting what the
    ///   participant holds. The coordinator no longer manufactures it at all
    ///   (see `AccountExposureCoordinator.acknowledge`); it survives as the
    ///   answer a participant may give for itself, and as the widget's single
    ///   deliberate exception — see `isWidgetTerminalSuccess`.
    ///
    /// - `.verificationFailed` — NOT accepted. This is the literal statement "I
    ///   could not confirm it is closed". It must keep the account closed.
    ///
    /// - `.persistenceFailed` — NOT accepted. The withdrawal was not durable, so
    ///   the surface can come back after a relaunch.
    var provesAccountExposureClosed: Bool {
        switch self {
        case .closed, .alreadyClosed, .unavailable:
            return true
        case .ownerMismatch, .verificationFailed, .persistenceFailed:
            return false
        }
    }
}

public extension AccountExposureCloseResult {
    /// The acknowledgement a PARENT must report on behalf of its children.
    ///
    /// The order children answer in is not the order that decides this, and that
    /// distinction only became load-bearing when `.unavailable` started counting
    /// as proof. A parent that took "the first result that wasn't closed" would
    /// report `.unavailable` for a child that simply was not there and SWALLOW a
    /// `.verificationFailed` from the next child — turning "nothing to close
    /// here" into a licence to erase while a second surface could not confirm it
    /// had closed. That is precisely the ignore-all-errors failure this barrier
    /// exists to prevent.
    ///
    /// So: any child that cannot prove closure wins outright. Absence is claimed
    /// only when every child proved it, and only when no child actually closed
    /// anything.
    static func aggregate<Results: Sequence>(
        _ results: Results
    ) -> AccountExposureCloseResult
        where Results.Element == AccountExposureCloseResult
    {
        var sawClosed = false
        var sawAlreadyClosed = false
        var sawUnavailable = false
        for result in results {
            guard result.provesAccountExposureClosed else { return result }
            switch result {
            case .closed: sawClosed = true
            case .alreadyClosed: sawAlreadyClosed = true
            case .unavailable: sawUnavailable = true
            default: break
            }
        }
        if sawClosed { return .closed }
        if sawAlreadyClosed { return .alreadyClosed }
        // No children at all is the same statement as a child that was not
        // there: nothing of this account can still be rendering underneath.
        return sawUnavailable ? .unavailable : .closed
    }
}

/// The deletion exposure barrier's verdict, in one place.
///
/// It is asked TWICE per deletion — once as each participant answers
/// (`liveExposureClosure` / `staleWorkCancellation`) and once over the collected
/// answers (`barrierVerification`). Both asks must agree; when they were written
/// out by hand in two files they drifted, and a result accepted by the first was
/// still refused by the second under a different stage name.
public enum AccountExposureBarrier {
    public static func isSatisfied(
        live: [AccountExposureAcknowledgement],
        stale: [AccountExposureAcknowledgement]
    ) -> Bool {
        (live + stale).allSatisfy(\.result.provesAccountExposureClosed)
    }
}

public enum AccountExposureKind: Sendable, Equatable {
    case live
    case staleWork
}

/// One attributable acknowledgement from the process-level exposure coordinator.
public struct AccountExposureAcknowledgement: Sendable, Equatable {
    public let participantID: String
    public let kind: AccountExposureKind
    public let result: AccountExposureCloseResult

    public init(
        participantID: String,
        kind: AccountExposureKind,
        result: AccountExposureCloseResult
    ) {
        self.participantID = participantID
        self.kind = kind
        self.result = result
    }
}

/// A live account-bound producer that must acknowledge terminal privacy closure.
public protocol AccountLiveExposure: AnyObject, Sendable {
    var participantID: String { get }
    var accountExposureBinding: CaptureAccountScope.AccountBinding { get }

    func closeAccountExposure(
        expected: CaptureAccountScope.AccountBinding
    ) async -> AccountExposureCloseResult
}

/// Account-bound asynchronous work that can otherwise complete into an old root.
public protocol AccountStaleWork: AnyObject, Sendable {
    var participantID: String { get }
    var accountExposureBinding: CaptureAccountScope.AccountBinding { get }

    func cancelAccountWork(
        expected: CaptureAccountScope.AccountBinding
    ) async -> AccountExposureCloseResult
}

/// Optional terminal-close capability for an audio source. Sources that do not
/// conform retain the legacy start/stop contract.
public protocol AccountAudioSourceExposure: AudioFrameSource, Sendable {
    func closeAudioExposure() async -> AccountExposureCloseResult
}

private final class WeakExposure: @unchecked Sendable {
    weak var value: (any AccountLiveExposure)?
    init(_ value: any AccountLiveExposure) { self.value = value }
}

private final class WeakStaleWork: @unchecked Sendable {
    weak var value: (any AccountStaleWork)?
    init(_ value: any AccountStaleWork) { self.value = value }
}

/// A retained-by-owner, weak-owner registration for actor-isolated participants.
/// The process coordinator holds this token weakly; constructing it is inert.
public final class AccountExposureRegistration: @unchecked Sendable {
    public enum Kind: Sendable, Equatable {
        case live
        case staleWork
    }

    public let participantID: String
    public let kind: Kind
    private let lock = NSLock()
    private var binding: CaptureAccountScope.AccountBinding?
    private let closeHook: @Sendable (
        CaptureAccountScope.AccountBinding
    ) async -> AccountExposureCloseResult

    public init<Owner: AnyObject & Sendable>(
        participantID: String,
        kind: Kind,
        binding: CaptureAccountScope.AccountBinding?,
        owner: Owner,
        close: @escaping @Sendable (
            Owner,
            CaptureAccountScope.AccountBinding
        ) async -> AccountExposureCloseResult
    ) {
        self.participantID = participantID
        self.kind = kind
        self.binding = binding
        self.closeHook = { [weak owner] expected in
            guard let owner else { return .unavailable }
            return await close(owner, expected)
        }
    }

    public func installBinding(
        _ binding: CaptureAccountScope.AccountBinding?
    ) {
        lock.lock()
        self.binding = binding
        lock.unlock()
    }

    fileprivate var availableBinding:
        CaptureAccountScope.AccountBinding?
    {
        lock.lock()
        defer { lock.unlock() }
        return binding
    }

    fileprivate func close(
        expected: CaptureAccountScope.AccountBinding
    ) async -> AccountExposureCloseResult {
        await closeHook(expected)
    }
}

private final class WeakRegistration: @unchecked Sendable {
    weak var value: AccountExposureRegistration?
    init(_ value: AccountExposureRegistration) { self.value = value }
}

/// Weak, deterministic registry for account-bound live exposure and stale work.
///
/// Participants are snapshotted before any awaited callback. A participant may
/// therefore register more work from inside its close hook without deadlocking;
/// that work is visible to the subsequent stale-work cancellation pass.
public final class AccountExposureCoordinator: @unchecked Sendable {
    public static let process = AccountExposureCoordinator()

    private let lock = NSLock()
    private var exposures: [WeakExposure] = []
    private var staleWork: [WeakStaleWork] = []
    private var registrations: [WeakRegistration] = []

    public init() {}

    @discardableResult
    public func register(
        _ registration: AccountExposureRegistration
    ) -> String {
        lock.lock()
        defer { lock.unlock() }
        pruneReleased()
        if registrations.contains(where: { $0.value === registration }) {
            return registration.participantID
        }
        registrations.append(WeakRegistration(registration))
        return registration.participantID
    }

    @discardableResult
    public func registerExposure(_ exposure: any AccountLiveExposure) -> String {
        let participantID = exposure.participantID
        lock.lock()
        defer { lock.unlock() }
        pruneReleased()
        if exposures.contains(where: { $0.value === exposure }) {
            return participantID
        }
        exposures.append(WeakExposure(exposure))
        return participantID
    }

    @discardableResult
    public func registerStaleWork(_ work: any AccountStaleWork) -> String {
        let participantID = work.participantID
        lock.lock()
        defer { lock.unlock() }
        pruneReleased()
        if staleWork.contains(where: { $0.value === work }) {
            return participantID
        }
        staleWork.append(WeakStaleWork(work))
        return participantID
    }

    public func closeRegisteredExposures(
        expected: CaptureAccountScope.AccountBinding
    ) async -> [AccountExposureAcknowledgement] {
        let participants: [any AccountLiveExposure] = {
            lock.lock()
            defer { lock.unlock() }
            let snapshot = exposures.compactMap(\.value)
            exposures.removeAll { $0.value == nil }
            return snapshot
        }().sorted { $0.participantID < $1.participantID }
        let allRegistered: [AccountExposureRegistration] = {
            lock.lock()
            defer { lock.unlock() }
            let snapshot = registrations.compactMap(\.value)
            registrations.removeAll { $0.value == nil }
            return snapshot
        }()
        let registered = allRegistered.filter { $0.kind == .live }

        var acknowledgements: [AccountExposureAcknowledgement] = []
        acknowledgements.reserveCapacity(
            participants.count + registered.count)
        for participant in participants {
            acknowledgements.append(.init(
                participantID: participant.participantID,
                kind: .live,
                result: await Self.acknowledge(
                    binding: participant.accountExposureBinding,
                    expected: expected,
                    close: { await participant.closeAccountExposure(
                        expected: $0) })))
        }
        for participant in registered {
            acknowledgements.append(.init(
                participantID: participant.participantID,
                kind: .live,
                result: await Self.acknowledge(
                    binding: participant.availableBinding,
                    expected: expected,
                    close: { await participant.close(expected: $0) })))
        }
        acknowledgements.sort { $0.participantID < $1.participantID }
        return acknowledgements
    }

    public func cancelRegisteredStaleWork(
        expected: CaptureAccountScope.AccountBinding
    ) async -> [AccountExposureAcknowledgement] {
        let participants: [any AccountStaleWork] = {
            lock.lock()
            defer { lock.unlock() }
            let snapshot = staleWork.compactMap(\.value)
            staleWork.removeAll { $0.value == nil }
            return snapshot
        }().sorted { $0.participantID < $1.participantID }
        let allRegistered: [AccountExposureRegistration] = {
            lock.lock()
            defer { lock.unlock() }
            let snapshot = registrations.compactMap(\.value)
            registrations.removeAll { $0.value == nil }
            return snapshot
        }()
        let registered = allRegistered.filter { $0.kind == .staleWork }

        var acknowledgements: [AccountExposureAcknowledgement] = []
        acknowledgements.reserveCapacity(
            participants.count + registered.count)
        for participant in participants {
            acknowledgements.append(.init(
                participantID: participant.participantID,
                kind: .staleWork,
                result: await Self.acknowledge(
                    binding: participant.accountExposureBinding,
                    expected: expected,
                    close: { await participant.cancelAccountWork(
                        expected: $0) })))
        }
        for participant in registered {
            acknowledgements.append(.init(
                participantID: participant.participantID,
                kind: .staleWork,
                result: await Self.acknowledge(
                    binding: participant.availableBinding,
                    expected: expected,
                    close: { await participant.close(expected: $0) })))
        }
        acknowledgements.sort { $0.participantID < $1.participantID }
        return acknowledgements
    }

    private func pruneReleased() {
        exposures.removeAll { $0.value == nil }
        staleWork.removeAll { $0.value == nil }
        registrations.removeAll { $0.value == nil }
    }

    /// Ask ONE participant, and decide what a binding difference means.
    ///
    /// This used to compare scope AND generation and answer `.ownerMismatch` on
    /// any difference, WITHOUT asking the participant to close. That is the same
    /// permanent lockout as the `.unavailable` one, one enum case over, and it is
    /// reachable on an ordinary sign-in: registration bindings are frozen at
    /// construction (`CaptureManager.accountBinding` is a `let`, and both
    /// `registerAccountExposures` and `registerAccountExposure` are one-shot),
    /// while the deletion machinery itself bumps the generation. A remounted
    /// `MainTabs` therefore leaves a second live registration with the SAME
    /// participant ID on an older generation — the coordinator dedupes by object
    /// identity, not by ID — and that older copy refused the barrier forever.
    /// Only force-quitting the app cleared it.
    ///
    /// The rule now follows the barrier's actual question, "can anything of THIS
    /// account still be rendered?":
    ///
    /// - Same scope, ANY generation — this participant may still be holding this
    ///   account's data, which is precisely the reason to ASK IT TO CLOSE rather
    ///   than to refuse. Its own answer stands, so a stale copy that cannot
    ///   confirm closure still blocks the erase.
    /// - A different scope, or no binding at all — nothing of this account is
    ///   here. That is `.unavailable`, the same statement a deallocated owner
    ///   makes, and it is proof.
    private static func acknowledge(
        binding: CaptureAccountScope.AccountBinding?,
        expected: CaptureAccountScope.AccountBinding,
        close: (CaptureAccountScope.AccountBinding) async
            -> AccountExposureCloseResult
    ) async -> AccountExposureCloseResult {
        guard let binding, binding.scope == expected.scope else {
            return .unavailable
        }
        return await close(binding)
    }
}
