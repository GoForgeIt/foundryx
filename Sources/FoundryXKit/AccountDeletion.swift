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

    /// The wire value the signup service expects. The app's scopes say WHAT to
    /// delete; the server's also encode WHEN billing stops, so the two vocabularies
    /// are deliberately mapped here rather than assumed identical.
    ///
    /// `.thisPhone` never reaches the server — it is a purely local erase — so it
    /// maps to the same full deletion as `.everywhere` only as a defensive default
    /// that is never sent.
    public var wireScope: String {
        switch self {
        case .thisPhone:   return "delete_now"
        case .hostedVault: return "vault_only"
        case .everywhere:  return "delete_now"
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
    /// The server has no deletion route (404/501) — the feature is not available yet.
    ///
    /// This is NOT a connection problem and NOT the user's fault. The gateway serves only
    /// `/account/signup`, `/account/waitlist` and `/account/waitlist-web`; everything else
    /// falls through to `404 Not Found`. Deletion is Apple-required and the button exists,
    /// so saying "check your connection" sent the owner to re-check a working connection,
    /// twice, for something no amount of retrying could fix.
    /// The sign-in could not be refreshed, or the server rejected it (401/403).
    ///
    /// Distinct from `.server` because the remedy is different and the UI used to
    /// conflate them: a missing token, an expired one, and a dropped connection all
    /// rendered as "Check your connection and try again." Nick hit this with a working
    /// connection and a healthy gateway — the request never left the phone, because the
    /// cached id_token snapshot was nil and the guard threw before any HTTP call.
    /// The server answered 404/501 for the deletion route. Before the route
    /// existed this meant "not built yet"; now it means the app is pointed
    /// somewhere wrong, or the service is not serving it. Either way retrying
    /// changes nothing and the connection is NOT the problem.
    case routeMissing
    case signInExpired
}

/// What should happen to the subscription when someone deletes their account.
///
/// A separate axis from `AccountDeletionScope`: that says WHAT is deleted, this
/// says what becomes of the money and when. Leaving, economising and pausing are
/// different intentions, and the app used to assume the first.
public enum DeletionOutcomeChoice: String, CaseIterable, Equatable, Sendable {
    /// Destroy the data and cancel the subscription today.
    case deleteNow
    /// Stop renewing; destroy the data when the paid period ends.
    case deleteAtPeriodEnd
    /// Cancel the subscription, keep the data and the account.
    case cancelOnly

    /// The wire value the signup service expects.
    public var wireScope: String {
        switch self {
        case .deleteNow:         return "delete_now"
        case .deleteAtPeriodEnd: return "delete_at_period_end"
        case .cancelOnly:        return "cancel_only"
        }
    }

    public var title: String {
        switch self {
        case .deleteNow:         return "Delete everything now"
        case .deleteAtPeriodEnd: return "Delete when my subscription ends"
        case .cancelOnly:        return "Cancel my subscription, keep my notes"
        }
    }

    public var detail: String {
        switch self {
        case .deleteNow:
            return "Your notes and your hosted Vault are destroyed today, and your subscription is cancelled today. You won't get the rest of the period you've paid for back. This can't be undone."
        case .deleteAtPeriodEnd:
            return "Your subscription stops renewing but runs to the end of the period you've paid for. On that date your notes and your hosted Vault are destroyed. This can't be undone once the date passes."
        case .cancelOnly:
            return "Your subscription is cancelled, and everything you've written stays exactly where it is. You keep your account and can start paying again later."
        }
    }

    /// Whether this choice destroys data at some point. Saying "this can't be
    /// undone" about `cancelOnly` would simply be false, and the old single
    /// confirmation said it about every path.
    public var isIrreversible: Bool { self != .cancelOnly }

    /// Whether choosing this forfeits time already paid for. Shown BEFORE the
    /// confirm — telling someone afterwards is just an apology.
    public var forfeitsPaidPeriod: Bool { self == .deleteNow }
}

/// What the server did, so the app can say something specific instead of a
/// generic "deleted".
public struct DeletionOutcome: Equatable, Sendable {
    public let status: String
    /// Set only for a scheduled deletion — the date to show the person.
    public let deleteAt: Date?
    public init(status: String, deleteAt: Date? = nil) {
        self.status = status
        self.deleteAt = deleteAt
    }
}

// MARK: - Seam (network + local)

/// The account-deletion seam. Live impl (LiveAccountDeletionService) wipes the on-device
/// store and calls the signup service / cell; the hermetic test stubs it.
public protocol AccountDeletionService: Sendable {
    /// Wipe the on-device library (captures, transcripts, prefs). Local only.
    func eraseThisPhone() async throws
    /// Delete the hosted Vault (isolated cell + data); keep the account. Bearer id_token.
    func deleteHostedVault(idToken: String?) async throws
    /// Act on the account + every Vault everywhere. `choice` decides what happens to the
    /// subscription and WHEN the data goes; only `deleteNow` erases this phone immediately.
    /// Returns what the server actually did, so the app says something specific.
    @discardableResult
    func deleteAccountEverywhere(choice: DeletionOutcomeChoice, idToken: String?) async throws -> DeletionOutcome
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
        /// The deletion is SCHEDULED, not done — nothing is destroyed until this date.
        case scheduled(Date)
        /// The subscription is cancelled and everything written is still there.
        case subscriptionCancelled
        case failed(AccountDeletionScope)
        /// The sign-in expired or was rejected — a DIFFERENT remedy from `.failed`, which
        /// tells the user to check a connection that is very likely fine.
        case routeMissing(AccountDeletionScope)
        case signInExpired(AccountDeletionScope)
        /// The server cannot do this yet. Distinct so the UI stops telling the user to
        /// retry something that can never succeed.
        case blocked(AccountDeletionScope)
    }

    @Published public private(set) var phase: Phase = .idle

    private let service: AccountDeletionService

    /// Where a deletion attempt is recorded. Deletion is rare, irreversible and
    /// remote, so "did this actually happen?" can only be answered from a record —
    /// and the local store is exactly what a deletion destroys, so the record must
    /// leave the device. Injected rather than reached for so the seams can assert
    /// it and the pure module stays transport-free.
    ///
    /// Carries the SCOPE and the OUTCOME only. Never the email, never a note.
    private let record: @Sendable (_ event: String, _ detail: String) -> Void

    public init(service: AccountDeletionService,
                record: @escaping @Sendable (_ event: String, _ detail: String) -> Void = { _, _ in }) {
        self.service = service
        self.record = record
    }

    /// Run a deletion of the whole account with an explicit subscription outcome.
    public func delete(scope: AccountDeletionScope,
                       choice: DeletionOutcomeChoice,
                       idToken: String?) async {
        phase = .deleting(scope)
        record("account.delete.requested", choice.wireScope)
        do {
            let outcome = try await service.deleteAccountEverywhere(choice: choice, idToken: idToken)
            switch choice {
            case .deleteNow:
                phase = .done(scope)
                record("account.delete.completed", choice.wireScope)
            case .deleteAtPeriodEnd:
                // A date the server did not give us is not a date to show. Falling
                // back to "deleted" would claim something that has not happened.
                phase = .scheduled(outcome.deleteAt ?? Date())
                record("account.delete.scheduled", choice.wireScope)
            case .cancelOnly:
                phase = .subscriptionCancelled
                record("account.delete.completed", choice.wireScope)
            }
        } catch AccountDeletionError.cleanupPending {
            phase = .blocked(scope); record("account.delete.blocked", choice.wireScope)
        } catch AccountDeletionError.routeMissing {
            phase = .routeMissing(scope); record("account.delete.failed", "\(choice.wireScope) route_missing")
        } catch AccountDeletionError.signInExpired {
            AuthExpiryRouter.shared.authRejected(
                generation: CaptureAccountScope.identityGeneration)
            phase = .signInExpired(scope); record("account.delete.failed", "\(choice.wireScope) sign_in_expired")
        } catch {
            phase = .failed(scope); record("account.delete.failed", "\(choice.wireScope) server")
        }
    }

    /// Execute a deletion for the chosen scope by routing to the matching seam. Idempotent
    /// per call; on failure the phase records which scope failed so the UI can retry.
    public func delete(scope: AccountDeletionScope, idToken: String?) async {
        phase = .deleting(scope)
        record("account.delete.requested", scope.wireScope)
        do {
            switch scope {
            case .thisPhone:
                try await service.eraseThisPhone()
            case .hostedVault:
                try await service.deleteHostedVault(idToken: idToken)
            case .everywhere:
                try await service.deleteAccountEverywhere(choice: .deleteNow, idToken: idToken)
            }
            phase = .done(scope)
            record("account.delete.completed", scope.wireScope)
        } catch AccountDeletionError.cleanupPending {
            phase = .blocked(scope)
            record("account.delete.blocked", scope.wireScope)
        } catch AccountDeletionError.routeMissing {
            phase = .routeMissing(scope)
            record("account.delete.failed", "\(scope.wireScope) route_missing")
        } catch AccountDeletionError.signInExpired {
            AuthExpiryRouter.shared.authRejected(
                generation: CaptureAccountScope.identityGeneration)
            // NOT `.failed`: nothing about the connection is wrong, and telling the user
            // to check it sends them to fix the one thing that is working.
            phase = .signInExpired(scope)
            record("account.delete.failed", "\(scope.wireScope) sign_in_expired")
        } catch {
            phase = .failed(scope)
            record("account.delete.failed", "\(scope.wireScope) server")
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
    private let deleteRemoteChoice: (@Sendable (_ choice: DeletionOutcomeChoice, _ idToken: String?) async throws -> DeletionOutcome)?

    public init(eraseLocal: @escaping @Sendable () async throws -> Void,
                deleteRemote: @escaping @Sendable (_ scope: AccountDeletionScope, _ idToken: String?) async throws -> Void,
                deleteRemoteChoice: (@Sendable (_ choice: DeletionOutcomeChoice, _ idToken: String?) async throws -> DeletionOutcome)? = nil) {
        self.deleteRemoteChoice = deleteRemoteChoice
        self.eraseLocal = eraseLocal
        self.deleteRemote = deleteRemote
    }

    public func eraseThisPhone() async throws {
        try await eraseLocal()
    }

    public func deleteHostedVault(idToken: String?) async throws {
        try await deleteRemote(.hostedVault, idToken)
    }

    @discardableResult
    public func deleteAccountEverywhere(choice: DeletionOutcomeChoice, idToken: String?) async throws -> DeletionOutcome {
        let outcome: DeletionOutcome
        if let choiceCall = deleteRemoteChoice {
            outcome = try await choiceCall(choice, idToken)
        } else {
            try await deleteRemote(.everywhere, idToken)
            outcome = DeletionOutcome(status: "deleted")
        }
        // ONLY an immediate deletion erases this phone. A scheduled deletion has
        // destroyed nothing yet, and a cancel keeps everything — wiping the device
        // for either would delete notes the person explicitly chose to keep.
        if choice == .deleteNow {
            try await eraseLocal()
        }
        return outcome
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
        // Recorded HERE, not after the container is resolved: this is the EARLIEST
        // and most likely refusal — no verified identity at all — and it returns
        // before any of the instrumentation below, so it used to leave no trace
        // whatsoever. A gate that refuses silently is indistinguishable from one
        // that was never reached.
        guard let identity = identityProvider(),
              let ownerScope = try? CaptureAccountScope.key(for: identity),
              AccountDeletionLifecycleStore.isValidOwnerScope(ownerScope)
        else {
            DeletionRecorder.shared.emit(
                "account.delete.local",
                identityProvider() == nil ? "owner_unproven no_identity"
                                          : "owner_unproven bad_scope")
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

        // Which PATH this took, recorded before it can be flattened. Several
        // distinct failures — a stale binding, an unproven owner, a cleanup group
        // that threw — all collapse into one `cleanupPending`, and the person is
        // shown a single "deletion is pending" with no way to tell which. On
        // 2026-08-02 that cost a round trip: the remote teardown had SUCCEEDED and
        // the local erase was blocked, and nothing on the device said why.
        do {
            switch lifecycle.record(ownerScope: ownerScope) {
            case .record(let record) where record.phase == .cleanupPending:
                DeletionRecorder.shared.emit("account.delete.local", "recover pending")
                _ = try await lifecycle.recover(ownerScope: ownerScope)
                DeletionRecorder.shared.emit("account.delete.local", "recover ok")
            case .missing, .record:
                guard let binding =
                        CaptureAccountScope.currentAccountBinding(),
                      binding.scope == ownerScope,
                      binding.root.deletingLastPathComponent()
                        .standardizedFileURL
                        == container.standardizedFileURL,
                      CaptureAccountScope.isCurrent(binding) else {
                    DeletionRecorder.shared.emit("account.delete.local", "owner_unproven")
                    throw AccountDeletionError.ownerUnproven
                }
                DeletionRecorder.shared.emit("account.delete.local", "begin")
                _ = try await lifecycle.begin(binding: binding)
                DeletionRecorder.shared.emit("account.delete.local", "begin ok")
            case .blocked(let reason):
                DeletionRecorder.shared.emit(
                    "account.delete.local", "store_blocked \(reason)")
                throw AccountDeletionError.cleanupPending
            }
        } catch AccountDeletionError.cleanupPending {
            throw AccountDeletionError.cleanupPending
        } catch {
            // The CAUSE, before it is flattened to `cleanupPending`.
            DeletionRecorder.shared.emit("account.delete.local", "failed \(error)")
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
