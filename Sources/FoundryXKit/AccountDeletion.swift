// AccountDeletion — the in-app account-deletion spine (track T-STOREFRONT). Apple Guideline
// 5.1.1(v) REQUIRES an app that supports account creation to also let the user initiate
// account deletion from within the app. FoundryX offers it three ways, matching the
// funnel-and-auth-spine design's data-ownership model:
//
//   • erase this phone       — wipe the on-device library (captures / transcripts / prefs).
//                              Local only; a hosted Vault (if any) is untouched.
//   • delete the hosted Vault — tear down the isolated cell + its data, keep the account
//                              (the user can re-provision later). Calls the signup/cell seam.
//   • delete everywhere       — erase this phone AND delete the account + every Vault. The
//                              full Apple-required "delete my account" path.
//
// This file is the PURE core: the scope enum + its copy, the deletion SEAM (protocol), and
// the @MainActor model that routes each scope to the right seam call. The live network/local
// implementation (LiveAccountDeletionService) is injected at the app edge; the hermetic test
// stubs the seam and never touches a live service or the real on-device store.

import Foundation

// MARK: - Scopes (pure)

/// The three account-deletion scopes offered in Settings. `CaseIterable` order is the display
/// order (least → most destructive).
public enum AccountDeletionScope: String, CaseIterable, Equatable, Sendable {
    /// Wipe the on-device library only (local; a hosted Vault is untouched).
    case thisPhone
    /// Delete the hosted Vault (the isolated cell + its data); keep the account.
    case hostedVault
    /// Delete the account and every Vault, everywhere — the Apple-required full deletion.
    case everywhere

    public var title: String {
        switch self {
        case .thisPhone:   return "Erase this account's local data"
        case .hostedVault: return "Delete your hosted Vault"
        case .everywhere:  return "Delete your account everywhere"
        }
    }

    public var subtitle: String {
        switch self {
        case .thisPhone:
            return "Erase only the current account's choices, voice notes, and computer connections from this iPhone. Other accounts and this phone's device setup are preserved. A hosted Vault, if you have one, stays untouched."
        case .hostedVault:
            return "Tear down your private hosted Vault and everything in it. Your account stays, so you can turn a Vault back on later."
        case .everywhere:
            return "Delete the current account and every Vault on our servers, then erase only this account's local data. Other accounts and this phone's device setup are preserved. This can't be undone."
        }
    }

    /// The destructive-confirmation verb shown on the final button.
    public var confirmLabel: String {
        switch self {
        case .thisPhone:   return "Erase current account"
        case .hostedVault: return "Delete hosted Vault"
        case .everywhere:  return "Delete everything"
        }
    }
}

/// A deletion failure surfaced to the model (e.g. the relay returned a non-2xx).
public enum AccountDeletionError: Error, Equatable, Sendable {
    case server
    case ownerUnproven
    case cleanupPending
}

// MARK: - Seam (network + local)

/// The account-deletion seam. Live impl (LiveAccountDeletionService) wipes the on-device
/// store and calls the signup service / cell; the hermetic test stubs it.
public protocol AccountDeletionService: Sendable {
    /// Wipe the on-device library (captures, transcripts, prefs). Local only.
    func eraseThisPhone() async throws
    /// Delete the hosted Vault (isolated cell + data); keep the account. Bearer id_token.
    func deleteHostedVault(idToken: String?) async throws
    /// Delete the account + every Vault everywhere (implies erasing this phone). Bearer id_token.
    func deleteAccountEverywhere(idToken: String?) async throws
}

// MARK: - The deletion model

/// Drives the account-deletion affordance: pick a scope, confirm, invoke the right seam, and
/// surface progress/outcome. `@MainActor ObservableObject` so the Settings screen observes it;
/// driven identically from the hermetic Brine steps.
@MainActor
public final class AccountDeletionModel: ObservableObject {
    /// Where the affordance is in its lifecycle.
    public enum Phase: Equatable, Sendable {
        case idle
        case deleting(AccountDeletionScope)
        case done(AccountDeletionScope)
        case failed(AccountDeletionScope)
        case blocked(AccountDeletionScope)
    }

    @Published public private(set) var phase: Phase = .idle

    private let service: AccountDeletionService
    public init(service: AccountDeletionService) { self.service = service }

    /// Execute a deletion for the chosen scope by routing to the matching seam. Idempotent
    /// per call; on failure the phase records which scope failed so the UI can retry.
    public func delete(scope: AccountDeletionScope, idToken: String?) async {
        phase = .deleting(scope)
        do {
            switch scope {
            case .thisPhone:
                try await service.eraseThisPhone()
            case .hostedVault:
                try await service.deleteHostedVault(idToken: idToken)
            case .everywhere:
                try await service.deleteAccountEverywhere(idToken: idToken)
            }
            phase = .done(scope)
        } catch AccountDeletionError.cleanupPending {
            phase = .blocked(scope)
        } catch {
            phase = .failed(scope)
        }
    }
}

// MARK: - Live seam (closure-injected so the pure module stays UIKit-free)

/// The production deletion seam. The two destructive edges are injected as closures so this
/// stays in the pure Kit module: `eraseLocal` wipes the on-device library (app edge), and
/// `deleteRemote` calls the signup service / cell for a given scope. "Delete everywhere"
/// erases locally too — the account no longer exists, so nothing local should remain.
public struct LiveAccountDeletionService: AccountDeletionService {
    private let eraseLocal: @Sendable () async throws -> Void
    private let deleteRemote: @Sendable (_ scope: AccountDeletionScope, _ idToken: String?) async throws -> Void

    public init(eraseLocal: @escaping @Sendable () async throws -> Void,
                deleteRemote: @escaping @Sendable (_ scope: AccountDeletionScope, _ idToken: String?) async throws -> Void) {
        self.eraseLocal = eraseLocal
        self.deleteRemote = deleteRemote
    }

    public func eraseThisPhone() async throws {
        try await eraseLocal()
    }

    public func deleteHostedVault(idToken: String?) async throws {
        try await deleteRemote(.hostedVault, idToken)
    }

    public func deleteAccountEverywhere(idToken: String?) async throws {
        try await deleteRemote(.everywhere, idToken)
        try await eraseLocal()
    }
}

/// Owner-proving adapter between the UI service and the durable selective
/// lifecycle. A new deletion requires an exact current binding for the verified
/// Keychain identity. Recovery requires that same identity plus a pending record
/// and the persisted activation owner; no free-form or inferred scope can erase.
final class CurrentOwnerSelectiveDeletionRunner: @unchecked Sendable {
    private let containerProvider: @Sendable () -> URL
    private let defaults: UserDefaults
    private let secretStore: any PairingSecretStore
    private let pairingServices: (cell: String, door: String)
    private let exposureCoordinator: AccountExposureCoordinator
    private let identityProvider: @Sendable () -> AuthIdentity?

    init(
        container: URL,
        defaults: UserDefaults,
        secretStore: any PairingSecretStore,
        pairingServices: (cell: String, door: String),
        exposureCoordinator: AccountExposureCoordinator,
        identityProvider: @escaping @Sendable () -> AuthIdentity?
    ) {
        self.containerProvider = { container }
        self.defaults = defaults
        self.secretStore = secretStore
        self.pairingServices = pairingServices
        self.exposureCoordinator = exposureCoordinator
        self.identityProvider = identityProvider
    }

    init(
        containerProvider: @escaping @Sendable () -> URL,
        defaults: UserDefaults,
        secretStore: any PairingSecretStore,
        pairingServices: (cell: String, door: String),
        exposureCoordinator: AccountExposureCoordinator,
        identityProvider: @escaping @Sendable () -> AuthIdentity?
    ) {
        self.containerProvider = containerProvider
        self.defaults = defaults
        self.secretStore = secretStore
        self.pairingServices = pairingServices
        self.exposureCoordinator = exposureCoordinator
        self.identityProvider = identityProvider
    }

    func eraseVerifiedCurrentOwner() async throws {
        guard let identity = identityProvider(),
              let ownerScope = try? CaptureAccountScope.key(for: identity),
              AccountDeletionLifecycleStore.isValidOwnerScope(ownerScope)
        else {
            throw AccountDeletionError.ownerUnproven
        }
        let container = containerProvider()

        let lifecycle = AccountDeletionLifecycle.live(
            container: container,
            defaults: defaults,
            secretStore: secretStore,
            pairingServices: pairingServices,
            exposureCoordinator: exposureCoordinator,
            verifiedIdentityForScope: { requestedScope in
                requestedScope == ownerScope ? identity : nil
            },
            legacyEnumerationObserver: { _ in })

        do {
            switch lifecycle.record(ownerScope: ownerScope) {
            case .record(let record) where record.phase == .cleanupPending:
                _ = try await lifecycle.recover(ownerScope: ownerScope)
            case .missing, .record:
                guard let binding =
                        CaptureAccountScope.currentAccountBinding(),
                      binding.scope == ownerScope,
                      binding.root.deletingLastPathComponent()
                        .standardizedFileURL
                        == container.standardizedFileURL,
                      CaptureAccountScope.isCurrent(binding) else {
                    throw AccountDeletionError.ownerUnproven
                }
                _ = try await lifecycle.begin(binding: binding)
            case .blocked:
                throw AccountDeletionError.cleanupPending
            }
        } catch AccountDeletionError.cleanupPending {
            throw AccountDeletionError.cleanupPending
        } catch {
            switch lifecycle.record(ownerScope: ownerScope) {
            case .record(let record) where record.phase == .cleanupPending:
                throw AccountDeletionError.cleanupPending
            case .blocked:
                throw AccountDeletionError.cleanupPending
            default:
                throw error
            }
        }
    }
}
