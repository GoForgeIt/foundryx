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
            let result: AccountExposureCloseResult
            let binding = participant.accountExposureBinding
            if !Self.sameOwner(binding, expected) {
                result = .ownerMismatch
            } else {
                result = await participant.closeAccountExposure(
                    expected: binding)
            }
            acknowledgements.append(.init(
                participantID: participant.participantID,
                kind: .live,
                result: result))
        }
        for participant in registered {
            let result: AccountExposureCloseResult
            guard let binding = participant.availableBinding else {
                acknowledgements.append(.init(
                    participantID: participant.participantID,
                    kind: .live,
                    result: .unavailable))
                continue
            }
            if !Self.sameOwner(binding, expected) {
                result = .ownerMismatch
            } else {
                result = await participant.close(expected: binding)
            }
            acknowledgements.append(.init(
                participantID: participant.participantID,
                kind: .live,
                result: result))
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
            let result: AccountExposureCloseResult
            let binding = participant.accountExposureBinding
            if !Self.sameOwner(binding, expected) {
                result = .ownerMismatch
            } else {
                result = await participant.cancelAccountWork(
                    expected: binding)
            }
            acknowledgements.append(.init(
                participantID: participant.participantID,
                kind: .staleWork,
                result: result))
        }
        for participant in registered {
            let result: AccountExposureCloseResult
            guard let binding = participant.availableBinding else {
                acknowledgements.append(.init(
                    participantID: participant.participantID,
                    kind: .staleWork,
                    result: .unavailable))
                continue
            }
            if !Self.sameOwner(binding, expected) {
                result = .ownerMismatch
            } else {
                result = await participant.close(expected: binding)
            }
            acknowledgements.append(.init(
                participantID: participant.participantID,
                kind: .staleWork,
                result: result))
        }
        acknowledgements.sort { $0.participantID < $1.participantID }
        return acknowledgements
    }

    private func pruneReleased() {
        exposures.removeAll { $0.value == nil }
        staleWork.removeAll { $0.value == nil }
        registrations.removeAll { $0.value == nil }
    }

    private static func sameOwner(
        _ lhs: CaptureAccountScope.AccountBinding,
        _ rhs: CaptureAccountScope.AccountBinding
    ) -> Bool {
        lhs.scope == rhs.scope && lhs.generation == rhs.generation
    }
}
