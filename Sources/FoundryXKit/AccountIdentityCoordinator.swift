import Foundation

/// An id token bound to the account generation that requested it.
public struct AccountBoundToken: Equatable, Sendable {
    public let value: String
    public let generation: UInt64

    public init(value: String, generation: UInt64) {
        self.value = value
        self.generation = generation
    }
}

/// Owns the process-level identity notification and fans the boundary out to the
/// account-derived stores held by the app root.
@MainActor
public final class AccountIdentityCoordinator: ObservableObject {
    public typealias TransitionHandler = @MainActor (UInt64) -> Void
    public typealias TokenHandler = @MainActor (AccountBoundToken?) -> Void

    @Published public private(set) var currentToken: AccountBoundToken?

    private let notificationCenter: NotificationCenter
    private var observer: NSObjectProtocol?
    private var activeGeneration: UInt64
    private var onIdentityTransition: TransitionHandler = { _ in }
    private var onRestoreCompleted: TransitionHandler = { _ in }
    private var onTokenAvailable: TokenHandler = { _ in }

    public init(
        notificationCenter: NotificationCenter = .default,
        activeGeneration: UInt64 = CaptureAccountScope.identityGeneration
    ) {
        self.notificationCenter = notificationCenter
        self.activeGeneration = activeGeneration
    }

    public func bind(
        onIdentityTransition: @escaping TransitionHandler,
        onRestoreCompleted: @escaping TransitionHandler,
        onTokenAvailable: @escaping TokenHandler
    ) {
        self.onIdentityTransition = onIdentityTransition
        self.onRestoreCompleted = onRestoreCompleted
        self.onTokenAvailable = onTokenAvailable
    }

    public func start() {
        guard observer == nil else { return }
        observer = notificationCenter.addObserver(
            forName: CaptureAccountScope.identityDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let generation = Self.generation(from: notification)
            MainActor.assumeIsolated {
                if let generation {
                    self?.receiveIdentityChange(generation: generation)
                }
            }
        }
    }

    public func stop() {
        if let observer {
            notificationCenter.removeObserver(observer)
            self.observer = nil
        }
    }

    public func restoreCompleted(generation: UInt64) {
        if activeGeneration != generation {
            currentToken = nil
            onTokenAvailable(nil)
        }
        activeGeneration = generation
        onRestoreCompleted(generation)
    }

    public func tokenDidChange(
        _ token: AccountBoundToken?,
        generation: UInt64
    ) {
        guard generation == activeGeneration,
              token?.generation == nil || token?.generation == generation else {
            return
        }
        currentToken = token
        onTokenAvailable(token)
    }

    private func receiveIdentityChange(generation: UInt64) {
        activeGeneration = generation
        currentToken = nil
        onTokenAvailable(nil)
        onIdentityTransition(generation)
    }

    nonisolated static func generation(from notification: Notification) -> UInt64? {
        if let generation = notification.userInfo?["generation"] as? UInt64 {
            return generation
        }
        if let number = notification.userInfo?["generation"] as? NSNumber {
            return number.uint64Value
        }
        if let integer = notification.userInfo?["generation"] as? Int,
           integer >= 0 {
            return UInt64(integer)
        }
        return nil
    }
}
