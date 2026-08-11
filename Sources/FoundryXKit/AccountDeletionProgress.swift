import Foundation
import Combine

// AccountDeletionProgress — what the person watches while their account is erased.
//
// Deleting an account walks thirteen named steps, most of which touch the
// filesystem or the keychain, and any of which can refuse. Until now the app
// showed a bare `ProgressView()` spinner over the whole screen and, on failure,
// one sentence built from whatever stage name happened to survive: Nick got
// "deletion is incomplete at preparing: exposureBarrierFailed" — a step name that
// does not exist ("preparing" is the fallback) and an error string aimed at a
// programmer. There was nothing to do with it and no way to tell what had run.
//
// The lifecycle ALREADY emits every step by name through `progressObserver`. This
// turns that stream into something a person can read, and turns a failure into
// the failing STEP plus an action.

public extension RemoteSession.DeletionCleanupStage {
    /// The step name, in the person's words. One definition — the front door and
    /// the progress screen used to carry separate copies of this list.
    var title: String {
        switch self {
        case .preparing: return "Preparing"
        case .signedInMirror: return "Signing out on this device"
        case .widgetWithdrawal: return "Clearing the widget"
        case .liveExposureClosure: return "Closing open account activity"
        case .staleWorkCancellation: return "Stopping background work"
        case .barrierVerification: return "Checking nothing is still open"
        case .barrierSync: return "Recording the safety barrier"
        case .trackBPreferences: return "Erasing account preferences"
        case .pairingPreferences: return "Erasing pairing settings"
        case .pairingSecrets: return "Erasing pairing secrets"
        case .localRoot: return "Erasing recordings and transcripts"
        case .legacyInputs: return "Erasing older account data"
        case .accountSurfaces: return "Erasing every remaining account surface"
        case .completedSync: return "Finishing"
        }
    }

    /// The same step told as something happening right now.
    var progressPhrase: String {
        switch self {
        case .preparing: return "getting ready"
        default: return title.prefix(1).lowercased() + title.dropFirst()
        }
    }
}

/// One step of the erase, and where it got to.
public struct AccountDeletionProgressStep: Identifiable, Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case waiting
        case running
        case finished
        case failed
    }

    public let stage: RemoteSession.DeletionCleanupStage
    public let state: State

    public var id: String { stage.rawValue }
    public var title: String { stage.title }
}

/// A failure the person can act on: which step, what happened in plain words,
/// and whether trying again can possibly help.
public struct AccountDeletionProgressFailure: Equatable, Sendable {
    public let stage: RemoteSession.DeletionCleanupStage
    public let title: String
    public let message: String
    public let isRetryable: Bool

    /// Built from the step that was in flight and the raw reason. The raw reason
    /// is deliberately still shown at the end of the message — the person may be
    /// reporting this to us, and sanding it off is how "exposureBarrierFailed"
    /// became untraceable.
    public static func make(
        stage: RemoteSession.DeletionCleanupStage,
        reason: String
    ) -> AccountDeletionProgressFailure {
        let lowered = reason.lowercased()
        let ownerUnproven = lowered.contains("ownerunproven")
            || lowered.contains("owner_unproven")
            || lowered.contains("stalebinding")
        // The deletion route answered 404/501. The identical request cannot
        // start working, so a "Try again" here is a button that provably fails.
        let routeMissing = lowered.contains("route_missing")
            || lowered.contains("routemissing")
        let message: String
        if routeMissing {
            message = "The server isn't offering account deletion at the "
                + "address this app is using, so trying again can't help and "
                + "your connection is fine. Nothing was deleted. Use “Erase "
                + "this account's local data” in Settings to clear everything "
                + "on this iPhone. (\(reason))"
        } else if ownerUnproven {
            // Retrying cannot help: nothing on this device can currently prove
            // who owns the data, so the app must not offer a button that fails.
            message = "This iPhone can't confirm which account owns this data "
                + "right now. Sign in again, then delete from Settings. "
                + "Nothing else was erased. (\(reason))"
        } else if lowered.contains("durab")
                    || lowered.contains("not durable")
                    || lowered.contains("persistencefailed") {
            message = "The result of this step couldn't be saved, so it isn't "
                + "safe to continue. Make sure this iPhone has free space and "
                + "isn't low on storage, then try again. (\(reason))"
        } else if lowered.contains("exposurebarrier") {
            message = "Part of the app is still showing or still using this "
                + "account, so erasing it now could leave it on screen. Close "
                + "any Live Activity or widget for this account and try again. "
                + "(\(reason))"
        } else {
            message = "This step didn't finish, so the rest of the erase was "
                + "not started. Your account stays closed until it does. "
                + "(\(reason))"
        }
        return .init(
            stage: stage,
            title: "\(stage.title) didn't finish",
            message: message,
            isRetryable: !ownerUnproven && !routeMissing)
    }
}

/// Everything the screen renders, as one value. Pure, so the whole progress
/// behaviour is testable without a view or a main actor.
public struct AccountDeletionProgressPresentation: Equatable, Sendable {
    public let steps: [AccountDeletionProgressStep]
    public let currentStage: RemoteSession.DeletionCleanupStage?
    public let failure: AccountDeletionProgressFailure?
    public let isFinished: Bool

    public var isRunning: Bool { !isFinished && failure == nil }

    /// The one line under the title. NEVER an empty spinner: even before the
    /// first step reports, it says what is happening.
    public var headline: String {
        if let failure { return failure.title }
        if isFinished { return "Everything on this iPhone was erased" }
        guard let currentStage else { return "Starting the erase…" }
        return "\(currentStage.progressPhrase.prefix(1).uppercased())"
            + "\(currentStage.progressPhrase.dropFirst())…"
    }

    public var completedCount: Int {
        steps.filter { $0.state == .finished }.count
    }

    public var totalCount: Int { steps.count }
}

/// The pure state machine behind the screen.
struct AccountDeletionProgressState {
    private(set) var reached: [RemoteSession.DeletionCleanupStage] = []
    private(set) var current: RemoteSession.DeletionCleanupStage?
    private(set) var failure: AccountDeletionProgressFailure?
    private(set) var isFinished = false
    private(set) var hasStarted = false

    static let order = RemoteSession.DeletionCleanupStage.allCasesForDeletion

    mutating func begin() {
        reached = []
        current = nil
        failure = nil
        isFinished = false
        hasStarted = true
    }

    mutating func apply(_ event: DeletionSignInRecoveryEvent) {
        switch event {
        case .required:
            begin()
        case .stage(let stage):
            hasStarted = true
            // A step that reports means every earlier step got past. The
            // lifecycle skips nothing, but it does not re-announce a group it
            // had already completed on an earlier attempt, so recovery would
            // otherwise leave earlier steps stuck on "waiting" forever.
            if let index = Self.order.firstIndex(of: stage) {
                reached = Array(Self.order.prefix(index))
            }
            current = stage
            failure = nil
        case .failed(let stage, let reason):
            hasStarted = true
            // The lifecycle's own stage wins when it names one; otherwise the
            // step that was in flight is the truthful answer, and it is always
            // more specific than the "preparing" fallback.
            let attributed = stage == .preparing ? (current ?? stage) : stage
            current = attributed
            failure = .make(stage: attributed, reason: reason)
        case .succeeded:
            hasStarted = true
            reached = Self.order
            current = nil
            failure = nil
            isFinished = true
        }
    }

    var presentation: AccountDeletionProgressPresentation {
        let steps = Self.order.map { stage -> AccountDeletionProgressStep in
            if failure?.stage == stage {
                return .init(stage: stage, state: .failed)
            }
            if isFinished || reached.contains(stage) {
                return .init(stage: stage, state: .finished)
            }
            if current == stage {
                return .init(stage: stage, state: failure == nil ? .running : .waiting)
            }
            return .init(stage: stage, state: .waiting)
        }
        return .init(
            steps: steps,
            currentStage: current,
            failure: failure,
            isFinished: isFinished)
    }
}

/// The screen's model. Deliberately NOT `@MainActor`: the lifecycle reports its
/// steps from whatever thread is doing the erase, and an ordering-free
/// `Task { @MainActor in … }` hop per step is exactly how a progress list ends up
/// showing steps out of order. State advances under a lock in call order, and
/// only the published snapshot is handed to the main thread.
public final class AccountDeletionProgressModel: ObservableObject, @unchecked Sendable {
    private let lock = NSLock()
    private var state = AccountDeletionProgressState()
    private var snapshot: AccountDeletionProgressPresentation

    /// Readable from ANY thread and always the latest reported truth.
    ///
    /// This was a `@Published` stored property assigned on the main queue, and
    /// that made it EVENTUALLY consistent: the erase reports a step from a
    /// background thread, and any reader that is not the main run loop — a test,
    /// a log line, a second reporter deciding what to say next — saw the previous
    /// step until the main queue happened to drain. A progress readout that lags
    /// the thing it describes is the same class of lie as the spinner it replaces.
    /// The state advances under the lock in call order; SwiftUI is told to
    /// re-read on the main thread, and re-reads THIS.
    public var presentation: AccountDeletionProgressPresentation {
        lock.withLock { snapshot }
    }

    /// Set by the screen; invoked when the person taps Retry.
    public var onRetry: (() -> Void)?

    public init() {
        snapshot = AccountDeletionProgressState().presentation
    }

    public func begin() { mutate { $0.begin() } }

    /// The sink for `CurrentOwnerSelectiveDeletionRunner`'s progress closure.
    public func report(_ event: DeletionSignInRecoveryEvent) {
        mutate { $0.apply(event) }
    }

    public func fail(
        stage: RemoteSession.DeletionCleanupStage,
        reason: String
    ) {
        report(.failed(stage, reason))
    }

    public func complete() { report(.succeeded) }

    private func mutate(
        _ change: (inout AccountDeletionProgressState) -> Void
    ) {
        lock.lock()
        change(&state)
        snapshot = state.presentation
        lock.unlock()
        // The value is already visible to every reader; this only asks SwiftUI to
        // come back and read it, which it must be told to do on the main thread.
        if Thread.isMainThread {
            objectWillChange.send()
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.objectWillChange.send()
            }
        }
    }
}
