// CaptureAccountScope — the storage boundary for everything FoundryX keeps for a
// signed-in user. Account isolation is an invariant, not a caller convention:
// durable user-private stores resolve through this type, and asynchronous work
// carries an immutable AccountBinding rather than re-resolving a later identity.

import Foundation
import Security

public enum CaptureAccountScopeError: Error, LocalizedError {
    case missingStableIdentity
    case activationAlreadyPending
    case activationState(String)
    /// This identity has a deletion that never finished, so returning would hand
    /// back half-erased data. DISTINCT from `activationState` because it is the one
    /// refusal the person can resolve themselves — and because collapsing it into a
    /// generic activation error is what made it a silent, permanent lockout.
    case deletionCleanupPending(ownerScope: String)
    case durableContainer(String)
    case ownershipMarker(String)
    case legacyEnumeration(String)
    case legacyMove(String)
    case legacyDestinationCollision(source: String, destination: String, recovery: String)

    public var errorDescription: String? {
        switch self {
        case .missingStableIdentity:
            return "The provider did not return a stable account subject or email."
        case .deletionCleanupPending:
            return "Deleting this account never finished on this iPhone, so it can't "
                + "be signed back in until the cleanup completes."
        case .activationAlreadyPending:
            return "A different account still owns an unfinished local-data activation."
        case .activationState(let detail):
            return "The account's durable storage state could not be recorded: \(detail)"
        case .durableContainer(let detail):
            return "The durable FoundryX storage container is unavailable: \(detail)"
        case .ownershipMarker(let detail):
            return "Local-data ownership could not be recorded: \(detail)"
        case .legacyEnumeration(let detail):
            return "Existing local data could not be inspected: \(detail)"
        case .legacyMove(let detail):
            return "Existing local data could not be moved safely: \(detail)"
        case .legacyDestinationCollision(let source, let destination, let recovery):
            return "Existing local data collided with \(destination). Both versions were kept; "
                + "\(source) was moved to the owner-only recovery location \(recovery). "
                + "Retry sign-in to continue."
        }
    }
}

public enum CaptureAccountScope {

    static let scopePrefix = "acct-"
    static let signedOutScope = scopePrefix + "none"
    static let migrationMarker = ".migrated-to"

    /// Every durable user-private store outside the capture hierarchy gets a named
    /// location here. Adding a new case is an explicit isolation decision.
    public enum PrivateStore: Sendable {
        case chatConversations

        fileprivate var relativePath: String {
            switch self {
            case .chatConversations: return "chat-conversations.json"
            }
        }
    }

    /// Immutable durable-scope/root identity captured when asynchronous work starts.
    /// Signed-out on-device capture is a first-class `acct-none` scope. Generation,
    /// not just scope, makes A → B → A reject stale work from the first A.
    public struct AccountBinding: Sendable, Equatable {
        public let root: URL
        public let scope: String
        public let generation: UInt64
        let admissionEpoch: UInt64?
        let admissionCell: SharedAccountAdmissionCell?

        init(
            root: URL,
            scope: String,
            generation: UInt64,
            admissionEpoch: UInt64? = nil,
            admissionCell: SharedAccountAdmissionCell? = nil
        ) {
            self.root = root
            self.scope = scope
            self.generation = generation
            self.admissionEpoch = admissionEpoch
            self.admissionCell = admissionCell
        }

        public var isCurrent: Bool {
            CaptureAccountScope.isCurrent(self)
        }

        public static func == (
            lhs: AccountBinding,
            rhs: AccountBinding
        ) -> Bool {
            lhs.root == rhs.root
                && lhs.scope == rhs.scope
                && lhs.generation == rhs.generation
                && lhs.admissionEpoch == rhs.admissionEpoch
        }
    }

    /// One immutable account snapshot for a related preference record and its
    /// Keychain secret. Reads take only `stateLock`; they never enter
    /// `persistenceQueue`, including from identity-change observers.
    public struct ScopedPreferences: Sendable, Equatable {
        public let scope: String

        init(scope: String) {
            self.scope = scope
        }

        public func key(_ unscopedKey: String) -> String {
            "\(scope).\(unscopedKey)"
        }
    }

    /// The one completion-side mutation door for account-bound producers.
    ///
    /// Validation and the synchronous mutation are serialized with identity
    /// transitions, so work cannot pass a check for A and then mutate after B has
    /// become current. The closure receives only the captured binding; resolving a
    /// fresh root from inside completion work is unnecessary and structurally gated.
    @discardableResult
    public static func perform<Result>(
        as binding: AccountBinding,
        _ mutation: (AccountBinding) throws -> Result
    ) rethrows -> Result? {
        stateLock.lock()
        guard generation == binding.generation,
              resolvedScope(cachedResolution) == binding.scope,
              !deletionAdmissionBlockedLocked(binding.scope) else {
            stateLock.unlock()
            return nil
        }
        let admissionLease: SharedAccountAdmissionCell.Lease?
        if isAccountScope(binding.scope) {
            guard let epoch = binding.admissionEpoch,
                  let lease = binding.admissionCell?.acquire(epoch: epoch)
            else {
                stateLock.unlock()
                return nil
            }
            admissionLease = lease
        } else {
            admissionLease = nil
        }
        defer { stateLock.unlock() }
        defer { admissionLease?.release() }
        let threadDictionary = Thread.current.threadDictionary
        let priorDepth =
            threadDictionary[preferenceMutationDepthKey] as? Int ?? 0
        threadDictionary[preferenceMutationDepthKey] = priorDepth + 1
        defer {
            if priorDepth == 0 {
                threadDictionary.removeObject(
                    forKey: preferenceMutationDepthKey)
            } else {
                threadDictionary[preferenceMutationDepthKey] = priorDepth
            }
        }
        return try mutation(binding)
    }

    struct ActivationTransaction: Sendable {
        let scope: String
        let previousScope: String?
        let requiresActivation: Bool
        let aliases: [String: String]
        let aliasSources: [String]
        let suppressLegacyAdoption: Bool
        let identity: AuthIdentity

        init(
            scope: String,
            previousScope: String?,
            requiresActivation: Bool,
            aliases: [String: String],
            aliasSources: [String],
            suppressLegacyAdoption: Bool = false,
            identity: AuthIdentity
        ) {
            self.scope = scope
            self.previousScope = previousScope
            self.requiresActivation = requiresActivation
            self.aliases = aliases
            self.aliasSources = aliasSources
            self.suppressLegacyAdoption = suppressLegacyAdoption
            self.identity = identity
        }
    }

    private enum ActivationPhase: String, Codable {
        case signedOut
        case active
        case pendingActivation
        case pendingSignOut
    }

    private struct ActivationRecord: Codable {
        let phase: ActivationPhase
        let scope: String?
        let previousScope: String?
        let aliases: [String: String]

        static let signedOut = ActivationRecord(
            phase: .signedOut, scope: nil, previousScope: nil, aliases: [:])
        static func signedOut(aliases: [String: String]) -> ActivationRecord {
            ActivationRecord(
                phase: .signedOut, scope: nil, previousScope: nil, aliases: aliases)
        }
        static func active(
            _ scope: String, aliases: [String: String]
        ) -> ActivationRecord {
            ActivationRecord(
                phase: .active, scope: scope, previousScope: nil, aliases: aliases)
        }
        static func pending(
            _ scope: String, previous: String?, aliases: [String: String]
        ) -> ActivationRecord {
            ActivationRecord(
                phase: .pendingActivation, scope: scope, previousScope: previous,
                aliases: aliases)
        }
        static func pendingSignOut(
            previous: String, aliases: [String: String]
        ) -> ActivationRecord {
            ActivationRecord(
                phase: .pendingSignOut, scope: nil, previousScope: previous,
                aliases: aliases)
        }

        private enum CodingKeys: String, CodingKey {
            case phase, scope, previousScope, aliases
        }

        init(
            phase: ActivationPhase,
            scope: String?,
            previousScope: String?,
            aliases: [String: String]
        ) {
            self.phase = phase
            self.scope = scope
            self.previousScope = previousScope
            self.aliases = aliases
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            phase = try container.decode(ActivationPhase.self, forKey: .phase)
            scope = try container.decodeIfPresent(String.self, forKey: .scope)
            previousScope = try container.decodeIfPresent(
                String.self, forKey: .previousScope)
            aliases = try container.decodeIfPresent(
                [String: String].self, forKey: .aliases) ?? [:]
        }
    }

    private struct IdentityScopeResolution {
        let scope: String
        let aliases: [String: String]
        let aliasSources: [String]
    }

    private enum Resolution: Equatable {
        case signedOut
        case account(String)
        case blocked
    }

    private struct LegacyMove {
        let source: URL
        let destination: URL
        let recoveryDiscriminator: String
    }

    private struct AccountDeletionWorkAuthorization: Sendable {
        let binding: AccountBinding
        let deletionEpoch: UInt64
        var blockedGeneration: UInt64
    }

    private static let activationStateKey = "foundryx.capture-account-activation.v2"
    // `foundryx.capture-account-scope` is a device-global bootstrap slot.
    // Account activation and sign-out may supersede it, but never own or erase it.
    public static let identityDidChangeNotification =
        Notification.Name("foundryx.capture-account-identity-did-change")

    // RECURSIVE, and it has to be. `perform(as:)` is the one place this lock is held across
    // CALLER code, and account-scoped work routinely does account-scoped work: the chat
    // screen records a finished turn under the account that started it, and recording it
    // persists the conversation list, which is itself account-scoped. With a plain `NSLock`
    // that second acquire was the same thread taking a lock it already held — a hard
    // deadlock, on the MAIN thread, at the end of every chat turn. The app did not crash and
    // did not spin; it simply stopped answering, including the accessibility hierarchy, which
    // is how `ActionsProofUITests.testExtensionFlows` found it (2026-08-05: `sample` showed
    // ChatScreen.send → perform → setMessages → persist → perform → __psynch_mutexwait).
    //
    // Recursion changes NOTHING for a thread that takes this lock once — every existing
    // execution is unaffected. What it fixes is a whole class, not one site: `perform`
    // nested in `perform` (App/ChatScreen.swift's end-of-turn record and AmbientCardBroker's
    // `[Run]` path both do it), and every read that takes this lock — `currentAccountBinding`,
    // `currentRoot`, `privateURL(for:)`, `binding(forExplicitRoot:)`, the store `init`s that
    // call them — which would hang the same way the moment it appeared inside a closure.
    //
    // The safety property is intact. A nested acquire can only happen on the thread that
    // already holds the lock, and while that thread is inside `perform` NO other thread can
    // transition identity — so the nested call re-validates against exactly the state the
    // outer call admitted. "Work cannot pass a check for A and then mutate after B has become
    // current" is still true, because B cannot become current in between. Reentry that must
    // still be REFUSED is refused on its own terms rather than by hanging: the preference
    // lifecycle gate rejects it on `preferenceMutationDepthKey`
    // (`beginPreferenceStoreMutation`), which is the guard its doc comment always claimed and
    // which was unreachable while the hang happened one frame earlier.
    private static let stateLock = NSRecursiveLock()
    // Serializes the concrete preference store with identity-generation changes.
    // No caller-owned callback or protocol method runs while this lock is held.
    private static let preferenceMutationLock = NSLock()
    private static let preferenceBarrierProbeLock = NSLock()
    private static let resolutionProbeLock = NSLock()
    private static let exposurePublicationLock = NSLock()
    private static let persistenceQueue =
        DispatchQueue(label: "foundryx.capture-account-persistence")
    private static let migrationQueue =
        DispatchQueue(label: "foundryx.capture-account-migration")

    nonisolated(unsafe) private static var cachedResolution: Resolution?
    nonisolated(unsafe) private static var cachedAccountPreferenceSnapshot:
        AccountPreferenceSnapshot?
    nonisolated(unsafe) private static var activePreferenceWriteBarrier:
        AccountPreferenceWriteBarrier?
    nonisolated(unsafe) private static var activePreferenceAdmissionLease:
        AccountDeletionLifecycleStore.OwnerAdmissionLease?
    nonisolated(unsafe) private static var generation: UInt64 = 0
    nonisolated(unsafe) private static var deletionWorkAuthorizations:
        [String: AccountDeletionWorkAuthorization] = [:]
    nonisolated(unsafe) private static var pendingDeletionAdmissions:
        Set<String> = []
    nonisolated(unsafe) private static var blockedDeletionAdmissions:
        Set<String> = []
    nonisolated(unsafe) private static var cachedSharedAdmissionScope: String?
    nonisolated(unsafe) private static var cachedSharedAdmissionCell:
        SharedAccountAdmissionCell?
    nonisolated(unsafe) private static var cachedSharedAdmissionEpoch: UInt64?
    nonisolated(unsafe) private static var containerOverride: URL?
    nonisolated(unsafe) private static var applicationSupportOverride: URL?
    nonisolated(unsafe) private static var defaultsOverride: UserDefaults?
    nonisolated(unsafe) private static var pairingKeychainServicesOverride:
        (cell: String, door: String)?
    nonisolated(unsafe) private static var interruptedDeletionRecoveryForTests:
        (@Sendable (AuthIdentity) async throws -> Void)?
    private static let preferenceMutationDepthKey =
        "foundryx.capture-account.preference-mutation-depth"
    nonisolated(unsafe) private static var lastValidatedContainer: URL?
    nonisolated(unsafe) private static var markerSyncFailureForTests = false
    nonisolated(unsafe) private static var resolutionPersistenceEntriesForTests = 0
    nonisolated(unsafe) private static var beforeAccountBindingPublicationHook:
        (() -> Void)?
    #if DEBUG || PERF_HARNESS
    nonisolated(unsafe) private static var afterAccountBindingGuardHookForTests:
        (() -> Void)?
    #endif
    nonisolated(unsafe) private static var activationMigrationPauseHookForTests:
        (() -> Void)?
    nonisolated(unsafe) private static var identityPresenceOverrideForTests:
        AuthStore.IdentityPresence?

    // MARK: - Stable provider-qualified key

    /// Stable across launches. Swift Hasher is deliberately forbidden here because
    /// its process seed would orphan a library on every relaunch.
    public static func key(for identity: AuthIdentity) throws -> String {
        guard let key = try identityCandidateKeys(identity).first else {
            throw CaptureAccountScopeError.missingStableIdentity
        }
        return key
    }

    static func key(forAccountKeyMaterial material: String) -> String {
        let canonical = material
            .precomposedStringWithCanonicalMapping
            .folding(options: [.caseInsensitive],
                     locale: Locale(identifier: "en_US_POSIX"))
        return key(forExactAccountKeyMaterial: canonical)
    }

    private static func key(forExactAccountKeyMaterial material: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in material.utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x100000001b3
        }
        return scopePrefix + String(hash, radix: 16)
    }

    private static func identityCandidateKeys(
        _ identity: AuthIdentity
    ) throws -> [String] {
        guard let provider = AuthProvider(rawValue: identity.provider) else {
            throw CaptureAccountScopeError.missingStableIdentity
        }
        var candidates: [String] = []
        if let subject = identity.stableSubject {
            candidates.append(key(forExactAccountKeyMaterial:
                "\(provider.rawValue)|sub|\(subject)"))
        }
        if let rawEmail = identity.email {
            let email = rawEmail.trimmingCharacters(in: .whitespacesAndNewlines)
            if !email.isEmpty {
            candidates.append(key(forAccountKeyMaterial:
                "\(provider.rawValue)|email|\(email)"))
            }
        }
        guard !candidates.isEmpty else {
            throw CaptureAccountScopeError.missingStableIdentity
        }
        return candidates
    }

    private static func resolveIdentityScope(
        _ identity: AuthIdentity,
        against record: ActivationRecord
    ) throws -> IdentityScopeResolution {
        let candidates = try identityCandidateKeys(identity)
        let recorded = candidates.compactMap { record.aliases[$0] }
        let target: String
        if let active = record.scope, candidates.contains(active) {
            // Upgrade a pre-alias ACTIVE record without forking its existing library.
            target = active
        } else if let active = record.scope, recorded.contains(active) {
            target = active
        } else {
            target = recorded.sorted().first ?? candidates[0]
        }
        var aliases = record.aliases
        for candidate in candidates {
            aliases[candidate] = target
        }
        return IdentityScopeResolution(
            scope: target,
            aliases: aliases,
            aliasSources: Array(Set(recorded).subtracting([target])).sorted())
    }

    /// Compatibility seam for older tests. Production identity resolution always uses
    /// `key(for:)`, which includes the provider and prefers the token subject.
    public static func key(forEmail email: String) -> String {
        key(forAccountKeyMaterial: "google|email|\(email)")
    }

    // MARK: - Crash-safe activation transaction

    /// Persist a PENDING boundary before AuthStore changes the keychain. While pending,
    /// background restoration is unauthorized and currentRoot fails closed.
    static func beginActivation(
        for identity: AuthIdentity,
        recoveryProgress: @escaping @Sendable (DeletionSignInRecoveryEvent) -> Void = { _ in }
    ) async throws -> ActivationTransaction {
        let target = try persistenceQueue.sync {
            let current = try readActivationRecordForMutation()
            return try resolveIdentityScope(identity, against: current).scope
        }
        let completedDeletion = try await completedDeletionAllowsReturn(
            ownerScope: target, identity: identity,
            recoveryProgress: recoveryProgress)
        return try beginActivationAfterDeletionCheck(
            identity, completedDeletion: completedDeletion)
    }

    private static func beginActivationAfterDeletionCheck(
        _ identity: AuthIdentity,
        completedDeletion: Bool
    ) throws -> ActivationTransaction {
        return try persistenceQueue.sync {
            let current = try readActivationRecordForMutation()
            let resolved = try resolveIdentityScope(identity, against: current)
            let target = resolved.scope
            switch current.phase {
            case .active where current.scope == target:
                try persistActivationRecord(.pending(
                    target, previous: target, aliases: resolved.aliases))
                currentDefaults().set(
                    false, forKey: AuthStore.signedInMirrorKey)
                installResolution(
                    .blocked, widgetOwner: nil, identityTransition: true)
                return ActivationTransaction(
                    scope: target, previousScope: target, requiresActivation: true,
                    aliases: resolved.aliases,
                    aliasSources: resolved.aliasSources,
                    suppressLegacyAdoption: completedDeletion,
                    identity: identity)
            case .pendingActivation where current.scope == target:
                return ActivationTransaction(
                    scope: target, previousScope: current.previousScope,
                    requiresActivation: true, aliases: resolved.aliases,
                    aliasSources: resolved.aliasSources,
                    suppressLegacyAdoption: completedDeletion,
                    identity: identity)
            case .pendingActivation, .pendingSignOut:
                throw CaptureAccountScopeError.activationAlreadyPending
            case .active, .signedOut:
                let previous = current.phase == .active ? current.scope : nil
                try persistActivationRecord(.pending(
                    target, previous: previous, aliases: resolved.aliases))
                currentDefaults().set(false, forKey: AuthStore.signedInMirrorKey)
                installResolution(.blocked, widgetOwner: nil, identityTransition: true)
                return ActivationTransaction(
                    scope: target, previousScope: previous, requiresActivation: true,
                    aliases: resolved.aliases,
                    aliasSources: resolved.aliasSources,
                    suppressLegacyAdoption: completedDeletion,
                    identity: identity)
            }
        }
    }

    /// Complete the filesystem claim before publishing ACTIVE. Errors leave PENDING
    /// intact so this owner can retry and a different identity cannot steal the claim.
    static func completeActivation(
        _ transaction: ActivationTransaction,
        activatePreferences: Bool = true
    ) async throws {
        let deletionCompleted = try await completedDeletionAllowsReturn(
            ownerScope: transaction.scope,
            identity: transaction.identity)
        try completeActivationAfterDeletionCheck(
            transaction,
            activatePreferences: activatePreferences,
            deletionCompleted: deletionCompleted)
    }

    private static func completeActivationAfterDeletionCheck(
        _ transaction: ActivationTransaction,
        activatePreferences: Bool,
        deletionCompleted: Bool
    ) throws {
        guard transaction.requiresActivation else {
            try persistenceQueue.sync {
                let defaults = currentDefaults()
                let preferenceValues: [String: AccountPreferenceValue]?
                if activatePreferences {
                    // This branch restores the previous owner after an interrupted
                    // transition. Its scoped bytes are already established and must
                    // not be normalized as though the owner were signing in fresh.
                    preferenceValues = AccountPreferenceActivationStore.restoreExisting(
                        scope: transaction.scope,
                        defaults: defaults
                    )
                } else {
                    preferenceValues = nil
                }
                defaults.set(true, forKey: AuthStore.signedInMirrorKey)
                guard defaults.synchronize(),
                      defaults.bool(forKey: AuthStore.signedInMirrorKey) else {
                    throw CaptureAccountScopeError.activationState(
                        "the signed-in mirror could not be durably restored")
                }
                installResolution(
                    .account(transaction.scope),
                    widgetOwner: transaction.scope,
                    identityTransition: true,
                    preferenceValues: preferenceValues)
            }
            return
        }
        try persistenceQueue.sync {
            let container = try durableContainer()
            let admitted: Void? = try AccountDeletionLifecycleStore(
                container: container
            ).withOwnerAdmission(ownerScope: transaction.scope) {
                let record = try readActivationRecordForMutation()
                guard record.phase == .pendingActivation,
                      record.scope == transaction.scope else {
                    throw CaptureAccountScopeError.activationState(
                        "the pending owner changed before activation completed")
                }
                let pause = stateLock.withLock {
                    activationMigrationPauseHookForTests
                }
                pause?()
                // Capture this before claimLegacyPrivateData can create the target
                // root. Existing scoped preferences or private files prove that this
                // owner is a restore, so activation must be byte-preserving. Absence
                // leaves the fresh-owner path available for an account returning
                // after completed deletion.
                let restoreExistingPreferences =
                    scopedOwnerHasExistingState(
                        scope: transaction.scope,
                        container: container,
                        defaults: currentDefaults())
                let suppressLegacyAdoption =
                    transaction.suppressLegacyAdoption
                    || deletionCompleted
                let ownsLegacyPrivateData: Bool
                if suppressLegacyAdoption {
                    let root = container.appendingPathComponent(
                        transaction.scope, isDirectory: true)
                    try FileManager.default.createDirectory(
                        at: root, withIntermediateDirectories: true)
                    ownsLegacyPrivateData = false
                } else {
                    try mergeAliasedScopes(
                        transaction.aliasSources, into: transaction.scope)
                    ownsLegacyPrivateData = try claimLegacyPrivateData(
                        for: transaction.scope)
                }
                if ownsLegacyPrivateData && !restoreExistingPreferences {
                    try adoptLegacyPairingRecord(
                        for: transaction.scope,
                        defaults: currentDefaults())
                }
                let defaults = currentDefaults()
                let preferenceValues: [String: AccountPreferenceValue]?
                if activatePreferences {
                    if restoreExistingPreferences {
                        preferenceValues =
                            AccountPreferenceActivationStore.restoreExisting(
                                scope: transaction.scope,
                                defaults: defaults)
                    } else {
                        preferenceValues =
                            try AccountPreferenceActivationStore.prepare(
                                scope: transaction.scope,
                                generation: identityGeneration,
                                identity: transaction.identity,
                                establishedLegacyOwner: ownsLegacyPrivateData,
                                defaults: defaults
                            ).adoptedValues
                    }
                } else {
                    preferenceValues = nil
                }
                try persistActivationRecord(.active(
                    transaction.scope, aliases: record.aliases))
                defaults.set(true, forKey: AuthStore.signedInMirrorKey)
                guard defaults.synchronize(),
                      defaults.bool(
                        forKey: AuthStore.signedInMirrorKey) else {
                    throw CaptureAccountScopeError.activationState(
                        "the signed-in mirror could not be durably recorded")
                }
                installResolution(
                    .account(transaction.scope),
                    widgetOwner: transaction.scope,
                    identityTransition: true,
                    preferenceValues: preferenceValues)
            }
            guard admitted != nil else {
                throw CaptureAccountScopeError.activationState(
                    "account deletion admission denied activation")
            }
        }
    }

    /// A read-only preservation test for activation. Every recognized scoped
    /// preference is matched by its exact owner-qualified key, and private storage
    /// counts only when that exact owner's root contains data. Unresolved state takes
    /// the preserving branch; this helper never authorizes removal or adoption.
    private static func scopedOwnerHasExistingState(
        scope: String,
        container: URL,
        defaults: UserDefaults
    ) -> Bool {
        let scoped = ScopedPreferences(scope: scope)
        let scopedKeys =
            AccountPreferenceCatalog.entries.map(\.canonicalKey)
            + [
                "foundryx.cell.url",
                "foundryx.cell.authMode",
                "foundryx.door.url",
            ]
        if scopedKeys.contains(where: {
            defaults.object(forKey: scoped.key($0)) != nil
        }) {
            return true
        }

        let root = container.appendingPathComponent(
            scope, isDirectory: true)
        guard FileManager.default.fileExists(atPath: root.path) else {
            return false
        }
        do {
            return try !FileManager.default.contentsOfDirectory(
                atPath: root.path).isEmpty
        } catch {
            // Failure to prove emptiness must preserve the owner's bytes.
            return true
        }
    }

    /// A keychain write that definitively failed can restore the previous safe state.
    static func rollbackActivation(_ transaction: ActivationTransaction) {
        guard transaction.requiresActivation else { return }
        persistenceQueue.sync {
            let restore = transaction.previousScope.map {
                ActivationRecord.active($0, aliases: transaction.aliases)
            } ?? .signedOut(aliases: transaction.aliases)
            guard (try? persistActivationRecord(restore)) != nil else { return }
            currentDefaults().set(
                transaction.previousScope != nil, forKey: AuthStore.signedInMirrorKey)
            installResolution(
                transaction.previousScope.map(Resolution.account) ?? .signedOut,
                widgetOwner: transaction.previousScope ?? signedOutScope,
                identityTransition: true)
        }
    }

    /// Resume or roll back an interrupted activation after the keychain becomes readable.
    @discardableResult
    static func restorePersistedIdentity(_ identity: AuthIdentity) async throws -> String {
        let target = try persistenceQueue.sync {
            let record = try readActivationRecordForMutation()
            return try resolveIdentityScope(identity, against: record).scope
        }
        let completedDeletion = try await completedDeletionAllowsReturn(
            ownerScope: target, identity: identity)
        let action: ActivationTransaction = try persistenceQueue.sync {
            let record = try readActivationRecordForMutation()
            let resolved = try resolveIdentityScope(identity, against: record)
            let target = resolved.scope
            switch record.phase {
            case .active where record.scope == target:
                try persistActivationRecord(.pending(
                    target, previous: target, aliases: resolved.aliases))
                currentDefaults().set(
                    false, forKey: AuthStore.signedInMirrorKey)
                installResolution(
                    .blocked, widgetOwner: nil, identityTransition: true)
                return ActivationTransaction(
                    scope: target, previousScope: target, requiresActivation: true,
                    aliases: resolved.aliases,
                    aliasSources: resolved.aliasSources,
                    suppressLegacyAdoption: completedDeletion,
                    identity: identity)
            case .pendingActivation where record.scope == target:
                return ActivationTransaction(
                    scope: target, previousScope: record.previousScope,
                    requiresActivation: true, aliases: resolved.aliases,
                    aliasSources: resolved.aliasSources,
                    suppressLegacyAdoption: completedDeletion,
                    identity: identity)
            case .pendingActivation where record.previousScope == target:
                try persistActivationRecord(
                    .active(target, aliases: resolved.aliases))
                return ActivationTransaction(
                    scope: target, previousScope: target, requiresActivation: false,
                    aliases: resolved.aliases,
                    aliasSources: resolved.aliasSources,
                    suppressLegacyAdoption: completedDeletion,
                    identity: identity)
            case .pendingSignOut where record.previousScope == target:
                try persistActivationRecord(
                    .active(target, aliases: resolved.aliases))
                return ActivationTransaction(
                    scope: target, previousScope: target, requiresActivation: false,
                    aliases: resolved.aliases,
                    aliasSources: resolved.aliasSources,
                    suppressLegacyAdoption: completedDeletion,
                    identity: identity)
            case .pendingActivation, .pendingSignOut:
                throw CaptureAccountScopeError.activationAlreadyPending
            case .active:
                throw CaptureAccountScopeError.activationState(
                    "the persisted identity does not match the active local-data owner")
            case .signedOut:
                try persistActivationRecord(.pending(
                    target, previous: nil, aliases: resolved.aliases))
                currentDefaults().set(false, forKey: AuthStore.signedInMirrorKey)
                installResolution(.blocked, widgetOwner: nil, identityTransition: true)
                return ActivationTransaction(
                    scope: target, previousScope: nil, requiresActivation: true,
                    aliases: resolved.aliases,
                    aliasSources: resolved.aliasSources,
                    suppressLegacyAdoption: completedDeletion,
                    identity: identity)
            }
        }
        try await completeActivation(action)
        return action.scope
    }

    static func beginSignOut() throws -> String? {
        try persistenceQueue.sync {
            let record = try readActivationRecordForMutation()
            switch record.phase {
            case .signedOut:
                return nil
            case .active:
                guard let scope = record.scope else {
                    throw CaptureAccountScopeError.activationState(
                        "active state is missing its owner")
                }
                try persistActivationRecord(.pendingSignOut(
                    previous: scope, aliases: record.aliases))
                currentDefaults().set(false, forKey: AuthStore.signedInMirrorKey)
                installResolution(.blocked, widgetOwner: nil, identityTransition: true)
                return scope
            case .pendingSignOut:
                // Idempotent retry: the first attempt may have been interrupted after
                // the durable transition but before the keychain delete.
                return record.previousScope
            case .pendingActivation:
                // User intent to sign out wins over an unfinished sign-in. Re-phasing
                // the durable transaction makes the activation finisher reject its
                // stale transaction instead of re-publishing after sign-out.
                let rollbackOwner = record.previousScope
                try persistActivationRecord(.pendingSignOut(
                    previous: record.scope ?? rollbackOwner ?? signedOutScope,
                    aliases: record.aliases))
                currentDefaults().set(false, forKey: AuthStore.signedInMirrorKey)
                installResolution(.blocked, widgetOwner: nil, identityTransition: true)
                return rollbackOwner
            }
        }
    }

    static func completeSignOut() throws {
        try persistenceQueue.sync {
            let record = try readActivationRecordForMutation()
            try persistActivationRecord(.signedOut(aliases: record.aliases))
            let defaults = currentDefaults()
            defaults.set(false, forKey: AuthStore.signedInMirrorKey)
            let preferences = try AccountPreferenceActivationStore.prepare(
                scope: signedOutScope,
                generation: identityGeneration,
                identity: nil,
                establishedLegacyOwner: false,
                defaults: defaults)
            installResolution(
                .signedOut,
                widgetOwner: signedOutScope,
                identityTransition: true,
                preferenceValues: preferences.adoptedValues)
        }
    }

    static func rollbackSignOut(previousScope: String?) {
        persistenceQueue.sync {
            let aliases = (try? readActivationRecordForMutation().aliases) ?? [:]
            let restored = previousScope.map {
                ActivationRecord.active($0, aliases: aliases)
            } ?? .signedOut(aliases: aliases)
            guard (try? persistActivationRecord(restored)) != nil else { return }
            currentDefaults().set(
                previousScope != nil, forKey: AuthStore.signedInMirrorKey)
            installResolution(
                previousScope.map(Resolution.account) ?? .signedOut,
                widgetOwner: previousScope ?? signedOutScope,
                identityTransition: true)
        }
    }

    /// Finish a sign-out interrupted after the keychain deletion.
    static func confirmSignedOutAfterReadableKeychain() throws {
        try persistenceQueue.sync {
            let record = try decodeActivationRecord()
            if record?.phase == .signedOut {
                installResolution(.signedOut, widgetOwner: signedOutScope,
                                  identityTransition: false)
                return
            }
            // A readable `errSecItemNotFound` is the only evidence that makes the
            // shared signed-out root usable. Missing/corrupt activation state alone
            // is ambiguous on a locked relaunch and therefore remains fail-closed.
            let aliases = record?.aliases ?? [:]
            try persistActivationRecord(.signedOut(aliases: aliases))
            currentDefaults().set(false, forKey: AuthStore.signedInMirrorKey)
            installResolution(
                .signedOut,
                widgetOwner: signedOutScope,
                identityTransition: true)
        }
    }

    /// Lock-screen authorization is true only for a fully claimed ACTIVE scope.
    static var hasPersistedActiveScope: Bool {
        guard currentDefaults().bool(forKey: AuthStore.signedInMirrorKey),
              case .account(let scope) = currentResolution() else {
            return false
        }
        stateLock.lock()
        let admissionBlocked = deletionAdmissionBlockedLocked(scope)
        stateLock.unlock()
        return !admissionBlocked
    }

    // MARK: - Account binding and store access

    /// The current cached preference owner and identity generation. Like
    /// `currentScopedPreferences`, this never resolves identity through persistence.
    public static func currentScopedPreferenceBinding() -> ScopedPreferenceBinding? {
        stateLock.lock()
        guard let scope = resolvedScope(cachedResolution),
              !deletionAdmissionBlockedLocked(scope) else {
            stateLock.unlock()
            return nil
        }
        let binding = ScopedPreferenceBinding(
            scope: scope, generation: generation)
        stateLock.unlock()
        return binding
    }

    /// Installs a dormant immutable snapshot only for the exact current owner
    /// generation. Task 1 exposes this seam to direct tests; no production owner calls
    /// it or selects scoped behavior.
    @discardableResult
    public static func installAccountPreferenceSnapshot(
        _ snapshot: AccountPreferenceSnapshot,
        as binding: ScopedPreferenceBinding
    ) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard snapshot.scope == binding.scope,
              snapshot.generation == binding.generation,
              generation == binding.generation,
              resolvedScope(cachedResolution) == binding.scope,
              !deletionAdmissionBlockedLocked(binding.scope) else {
            return false
        }
        cachedAccountPreferenceSnapshot = snapshot
        return true
    }

    /// A cache-only read. Defaults and identity persistence are deliberately absent
    /// from this path.
    public static func currentAccountPreferenceSnapshot()
        -> AccountPreferenceSnapshot?
    {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard let snapshot = cachedAccountPreferenceSnapshot,
              snapshot.generation == generation,
              resolvedScope(cachedResolution) == snapshot.scope,
              !pendingDeletionAdmissions.contains(snapshot.scope) else {
            return nil
        }
        return snapshot
    }

    static func writeAccountPreference<Value>(
        _ value: Value,
        for key: AccountPreferenceKey<Value>,
        expectedGeneration: UInt64?
    ) -> AccountPreferenceWriteResult {
        guard let encoded = AccountPreferenceValue.encode(value),
              let binding = currentScopedPreferenceBinding() else {
            return .unresolved
        }
        if let expectedGeneration,
           expectedGeneration != binding.generation {
            return .stale
        }
        switch beginPreferenceStoreMutation(as: binding, barrier: nil) {
        case .unresolved: return .unresolved
        case .stale: return .stale
        case .rejected: return .rejected
        case .acquired(let scoped):
            defer { endPreferenceStoreMutation() }
            let defaults = currentDefaults()
            let storageKey = scoped.key(key.canonicalKey)
            let prior = defaults.object(forKey: storageKey)
            defaults.set(encoded.defaultsValue, forKey: storageKey)
            guard defaults.synchronize(),
                  storedPreferenceValue(
                    forKey: storageKey,
                    matching: encoded,
                    defaults: defaults) == encoded else {
                restorePreferenceValue(
                    prior, forKey: storageKey, defaults: defaults)
                return .failed
            }
            cachePreferenceValue(
                encoded,
                forCanonicalKey: key.canonicalKey,
                binding: binding)
            return .saved
        }
    }

    static func removeAccountPreference<Value>(
        _ key: AccountPreferenceKey<Value>,
        expectedGeneration: UInt64?
    ) -> AccountPreferenceWriteResult {
        guard let binding = currentScopedPreferenceBinding() else {
            return .unresolved
        }
        if let expectedGeneration,
           expectedGeneration != binding.generation {
            return .stale
        }
        switch beginPreferenceStoreMutation(as: binding, barrier: nil) {
        case .unresolved: return .unresolved
        case .stale: return .stale
        case .rejected: return .rejected
        case .acquired(let scoped):
            defer { endPreferenceStoreMutation() }
            let defaults = currentDefaults()
            let storageKey = scoped.key(key.canonicalKey)
            let prior = defaults.object(forKey: storageKey)
            defaults.removeObject(forKey: storageKey)
            guard defaults.synchronize(),
                  defaults.object(forKey: storageKey) == nil else {
                restorePreferenceValue(
                    prior, forKey: storageKey, defaults: defaults)
                return .failed
            }
            cachePreferenceValue(
                nil,
                forCanonicalKey: key.canonicalKey,
                binding: binding)
            return .saved
        }
    }

    static func writeCheckoutPreferencePair(
        id: String,
        plan: String,
        expectedGeneration: UInt64?
    ) -> AccountPreferenceWriteResult {
        guard !id.isEmpty,
              ["starter", "pro", "power"].contains(plan) else {
            return .rejected
        }
        return mutateCheckoutPreferencePair(
            id: id,
            plan: plan,
            expectedGeneration: expectedGeneration)
    }

    static func clearCheckoutPreferencePair(
        expectedGeneration: UInt64?
    ) -> AccountPreferenceWriteResult {
        mutateCheckoutPreferencePair(
            id: nil,
            plan: nil,
            expectedGeneration: expectedGeneration)
    }

    private static func mutateCheckoutPreferencePair(
        id: String?,
        plan: String?,
        expectedGeneration: UInt64?
    ) -> AccountPreferenceWriteResult {
        guard let binding = currentScopedPreferenceBinding() else {
            return .unresolved
        }
        if let expectedGeneration,
           expectedGeneration != binding.generation {
            return .stale
        }
        switch beginPreferenceStoreMutation(as: binding, barrier: nil) {
        case .unresolved: return .unresolved
        case .stale: return .stale
        case .rejected: return .rejected
        case .acquired(let scoped):
            defer { endPreferenceStoreMutation() }
            let defaults = currentDefaults()
            let idCanonical =
                AccountPreferenceCatalog.vaultCheckoutAttemptID.canonicalKey
            let planCanonical =
                AccountPreferenceCatalog.vaultCheckoutAttemptPlan.canonicalKey
            let idKey = scoped.key(idCanonical)
            let planKey = scoped.key(planCanonical)
            let priorID = defaults.object(forKey: idKey)
            let priorPlan = defaults.object(forKey: planKey)
            if let id, let plan {
                defaults.set(id, forKey: idKey)
                defaults.set(plan, forKey: planKey)
            } else {
                defaults.removeObject(forKey: idKey)
                defaults.removeObject(forKey: planKey)
            }
            let readbackMatches: Bool
            if let id, let plan {
                readbackMatches =
                    defaults.string(forKey: idKey) == id
                    && defaults.string(forKey: planKey) == plan
            } else {
                readbackMatches =
                    defaults.object(forKey: idKey) == nil
                    && defaults.object(forKey: planKey) == nil
            }
            guard defaults.synchronize(), readbackMatches else {
                restorePreferenceValue(
                    priorID,
                    forKey: idKey,
                    defaults: defaults,
                    synchronize: false)
                restorePreferenceValue(
                    priorPlan,
                    forKey: planKey,
                    defaults: defaults)
                return .failed
            }
            cachePreferenceValues(
                [
                    idCanonical: id.map(AccountPreferenceValue.string),
                    planCanonical: plan.map(AccountPreferenceValue.string),
                ],
                binding: binding)
            return .saved
        }
    }

    private static func storedPreferenceValue(
        forKey key: String,
        matching expected: AccountPreferenceValue,
        defaults: UserDefaults
    ) -> AccountPreferenceValue? {
        switch expected {
        case .bool:
            return (defaults.object(forKey: key) as? Bool).map(
                AccountPreferenceValue.bool)
        case .string:
            return defaults.string(forKey: key).map(
                AccountPreferenceValue.string)
        case .double:
            return (defaults.object(forKey: key) as? NSNumber).map {
                .double($0.doubleValue)
            }
        case .boolDictionary:
            return (defaults.dictionary(forKey: key) as? [String: Bool]).map(
                AccountPreferenceValue.boolDictionary)
        case .data:
            return defaults.data(forKey: key).map(
                AccountPreferenceValue.data)
        }
    }

    private static func restorePreferenceValue(
        _ value: Any?,
        forKey key: String,
        defaults: UserDefaults,
        synchronize: Bool = true
    ) {
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
        if synchronize {
            _ = defaults.synchronize()
        }
    }

    static func cachePreferenceValue(
        _ value: AccountPreferenceValue?,
        forCanonicalKey key: String,
        binding: ScopedPreferenceBinding
    ) {
        cachePreferenceValues([key: value], binding: binding)
    }

    private static func cachePreferenceValues(
        _ changes: [String: AccountPreferenceValue?],
        binding: ScopedPreferenceBinding
    ) {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard generation == binding.generation,
              resolvedScope(cachedResolution) == binding.scope,
              !deletionAdmissionBlockedLocked(binding.scope) else {
            return
        }
        var values = cachedAccountPreferenceSnapshot?.values ?? [:]
        for (key, value) in changes {
            if let value {
                values[key] = value
            } else {
                values.removeValue(forKey: key)
            }
        }
        cachedAccountPreferenceSnapshot = AccountPreferenceSnapshot(
            scope: binding.scope,
            generation: binding.generation,
            values: values)
    }

    enum PreferenceStoreMutationAdmission {
        case acquired(ScopedPreferences)
        case stale
        case unresolved
        case rejected
    }

    /// Acquires the one dormant preference lifecycle gate without running caller
    /// code. Reentry from `perform(as:)` and concurrent gate use fail promptly.
    static func beginPreferenceStoreMutation(
        as binding: ScopedPreferenceBinding,
        barrier: AccountPreferenceWriteBarrier?
    ) -> PreferenceStoreMutationAdmission {
        let depth = Thread.current.threadDictionary[
            preferenceMutationDepthKey] as? Int ?? 0
        guard depth == 0 else { return .rejected }
        preferenceBarrierProbeLock.lock()
        guard preferenceMutationLock.try() else {
            preferenceBarrierProbeLock.unlock()
            return .rejected
        }
        activePreferenceWriteBarrier = barrier
        preferenceBarrierProbeLock.unlock()

        barrier?.pauseWriterIfArmed()
        guard stateLock.try() else {
            unlockPreferenceMutationGate()
            return .rejected
        }
        guard let currentScope = resolvedScope(cachedResolution),
              !deletionAdmissionBlockedLocked(currentScope) else {
            stateLock.unlock()
            unlockPreferenceMutationGate()
            return .unresolved
        }
        guard generation == binding.generation,
              currentScope == binding.scope else {
            stateLock.unlock()
            unlockPreferenceMutationGate()
            return .stale
        }
        let scoped = ScopedPreferences(scope: currentScope)
        stateLock.unlock()

        guard isAccountScope(binding.scope) else {
            return .acquired(scoped)
        }

        // Durable admission follows the bounded in-process probes and must itself
        // be nonblocking: activation may hold the lifecycle store while waiting
        // for this preference gate.
        guard let container = try? durableContainer(),
              let admission = AccountDeletionLifecycleStore(
                container: container
              ).acquireOwnerAdmission(ownerScope: binding.scope) else {
            unlockPreferenceMutationGate()
            return .unresolved
        }
        preferenceBarrierProbeLock.withLock {
            activePreferenceAdmissionLease = admission
        }
        return .acquired(scoped)
    }

    static func endPreferenceStoreMutation() {
        unlockPreferenceMutationGate()
    }

    static func currentPreferenceStoreKey(
        _ canonicalKey: String,
        as binding: ScopedPreferenceBinding
    ) -> String? {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard generation == binding.generation,
              let currentScope = resolvedScope(cachedResolution),
              currentScope == binding.scope,
              !deletionAdmissionBlockedLocked(currentScope) else {
            return nil
        }
        return ScopedPreferences(scope: currentScope).key(canonicalKey)
    }

    /// The current account's preference namespace, resolved only from the
    /// state-lock-protected process cache. A nil cache or blocked transition is
    /// unresolved and fails closed; this accessor never initializes resolution by
    /// hopping onto `persistenceQueue`.
    public static func currentScopedPreferences() -> ScopedPreferences? {
        stateLock.lock()
        guard let scope = resolvedScope(cachedResolution),
              !deletionAdmissionBlockedLocked(scope) else {
            stateLock.unlock()
            return nil
        }
        stateLock.unlock()
        return ScopedPreferences(scope: scope)
    }

    public static func currentAccountBinding() -> AccountBinding? {
        guard resolvedScope(currentResolution()) != nil else { return nil }
        guard let base = try? durableContainer() else { return nil }
        stateLock.lock()
        guard let scope = resolvedScope(cachedResolution),
              !deletionAdmissionBlockedLocked(scope) else {
            stateLock.unlock()
            return nil
        }
        let revision = generation
        let expectedAdmissionEpoch =
            cachedSharedAdmissionScope == scope
                ? cachedSharedAdmissionEpoch
                : nil
        let hook = beforeAccountBindingPublicationHook
        beforeAccountBindingPublicationHook = nil
        stateLock.unlock()
        let admissionCell: SharedAccountAdmissionCell?
        let admissionEpoch: UInt64?
        if isAccountScope(scope) {
            guard let cell = try? SharedAccountAdmissionRegistry.cell(
                container: base,
                ownerScope: scope),
                  let epoch = cell.openEpoch,
                  expectedAdmissionEpoch.map({ $0 == epoch }) ?? true else {
                return nil
            }
            admissionCell = cell
            admissionEpoch = epoch
        } else {
            admissionCell = nil
            admissionEpoch = nil
        }
        hook?()
        exposurePublicationLock.lock()
        defer { exposurePublicationLock.unlock() }
        stateLock.lock()
        guard generation == revision,
              resolvedScope(cachedResolution) == scope,
              !deletionAdmissionBlockedLocked(scope),
              admissionCell?.isCurrent(epoch: admissionEpoch ?? 0)
                ?? !isAccountScope(scope) else {
            stateLock.unlock()
            return nil
        }
        cachedSharedAdmissionScope = scope
        cachedSharedAdmissionCell = admissionCell
        cachedSharedAdmissionEpoch = admissionEpoch
        stateLock.unlock()
        #if DEBUG || PERF_HARNESS
        afterAccountBindingGuardHookForTests?()
        #endif
        let binding = AccountBinding(
            root: base.appendingPathComponent(scope, isDirectory: true),
            scope: scope,
            generation: revision,
            admissionEpoch: admissionEpoch,
            admissionCell: admissionCell)
        // Published OUTSIDE `stateLock`, while `exposurePublicationLock` still closes
        // the generation-to-cross-process-publication window. Surface stores may take
        // their own locks and synchronize; none is ever nested under `stateLock`.
        _ = AccountSurfaceRegistry.attachAll(binding)
        return binding
    }

    /// A binding for a producer that was handed an EXPLICIT root rather than the
    /// account root (an injected container, or a test harness).
    ///
    /// The root says where bytes land; it does not change WHO the work belongs to, so
    /// the identity carried here is still the device's current scope and the binding is
    /// rejected on an identity change exactly like an account-root binding. Resolving
    /// the shared durable container is deliberately skipped — a caller that named its
    /// own container must not be made to touch, or create, the account container.
    public static func binding(forExplicitRoot root: URL) -> AccountBinding? {
        guard let scope = resolvedScope(currentResolution()) else { return nil }
        // An explicit root may name its OWN container, but never another scope's root.
        // Without this, `binding(forExplicitRoot: <B's root>)` while A is active would
        // be stamped with A's identity and accepted by `perform(as:)`, which is a door
        // for writing A's bytes under B (terra round-3, P0-1). Scoped roots are always
        // `<container>/<scope>`, so a differing scope-shaped last component is the
        // signal — and checking the NAME resolves no container, so a caller that named
        // its own container is still never made to create the account one.
        let name = root.standardizedFileURL.lastPathComponent
        guard !(name.hasPrefix(scopePrefix) && name != scope) else { return nil }
        exposurePublicationLock.lock()
        defer { exposurePublicationLock.unlock() }
        stateLock.lock()
        guard resolvedScope(cachedResolution) == scope,
              !deletionAdmissionBlockedLocked(scope) else {
            stateLock.unlock()
            return nil
        }
        let revision = generation
        let admissionCell =
            cachedSharedAdmissionScope == scope
                ? cachedSharedAdmissionCell
                : nil
        let admissionEpoch =
            cachedSharedAdmissionScope == scope
                ? cachedSharedAdmissionEpoch
                : nil
        guard !isAccountScope(scope)
                || (
                    admissionEpoch.map {
                        admissionCell?.isCurrent(epoch: $0) == true
                    } ?? false
                ) else {
            stateLock.unlock()
            return nil
        }
        stateLock.unlock()
        let binding = AccountBinding(
            root: root,
            scope: scope,
            generation: revision,
            admissionEpoch: admissionEpoch,
            admissionCell: admissionCell)
        _ = AccountSurfaceRegistry.attachAll(binding)
        return binding
    }

    public static func isCurrent(_ binding: AccountBinding) -> Bool {
        stateLock.lock()
        let current = generation == binding.generation
            && resolvedScope(cachedResolution) == binding.scope
            && !deletionAdmissionBlockedLocked(binding.scope)
            && (
                !isAccountScope(binding.scope)
                    || (
                        binding.admissionEpoch.map {
                            binding.admissionCell?.isCurrent(epoch: $0)
                                == true
                        } ?? false
                    )
            )
        stateLock.unlock()
        return current
    }

    public static var identityGeneration: UInt64 {
        stateLock.lock()
        defer { stateLock.unlock() }
        return generation
    }

    public static func currentRoot() -> URL {
        let resolution = currentResolution()
        guard let base = try? durableContainer() else { return failClosedRoot }
        switch resolution {
        case .account(let scope):
            stateLock.lock()
            let admissionBlocked =
                deletionAdmissionBlockedLocked(scope)
            let sharedAdmission =
                cachedSharedAdmissionScope == scope
                    ? cachedSharedAdmissionCell
                    : nil
            let sharedEpoch =
                cachedSharedAdmissionScope == scope
                    ? cachedSharedAdmissionEpoch
                    : nil
            stateLock.unlock()
            guard !admissionBlocked else {
                return failClosedRoot
            }
            // A process that already published this account cached the mapped cell
            // and its admitted epoch. A deletion in another process revokes that
            // exact epoch atomically; root access must observe the same barrier as
            // `perform(as:)` without opening a file, taking a durable lock, or
            // entering `persistenceQueue`. A missing cache is not evidence of a
            // deletion and therefore retains the existing fail-open behavior.
            if let sharedAdmission, let sharedEpoch,
               !sharedAdmission.isCurrent(epoch: sharedEpoch) {
                return failClosedRoot
            }
            return base.appendingPathComponent(scope, isDirectory: true)
        case .signedOut:
            return base.appendingPathComponent(signedOutScope, isDirectory: true)
        case .blocked:
            return failClosedRoot
        }
    }

    public static func privateURL(for store: PrivateStore) -> URL {
        currentRoot().appendingPathComponent(store.relativePath)
    }

    /// The shared parent for account capture roots. If Documents cannot be validated,
    /// this returns a deliberately unwritable path rather than temporary storage.
    public static func container() -> URL {
        (try? durableContainer()) ?? failClosedContainer
    }

    // MARK: - Eager account pairing adoption

    /// Carry the already-shipped device-global pairing records into the durable
    /// owner selected by the existing private-data claim. Legacy defaults remain in
    /// place, and legacy Keychain items are retagged in place; no migration delete is
    /// permitted. This runs only from `completeActivation` on `persistenceQueue`.
    private static func adoptLegacyPairingRecord(
        for scope: String,
        defaults: UserDefaults
    ) throws {
        let scoped = ScopedPreferences(scope: scope)
        stateLock.lock()
        let services = pairingKeychainServicesOverride
            ?? (
                cell: "com.goforgeit.foundryx.cell",
                door: "com.goforgeit.foundryx.door"
            )
        stateLock.unlock()

        try adoptLegacyCellPairing(
            defaults: defaults,
            scoped: scoped,
            service: services.cell)
        try adoptLegacyDoorPairing(
            defaults: defaults,
            scoped: scoped,
            service: services.door)
    }

    private static func adoptLegacyCellPairing(
        defaults: UserDefaults,
        scoped: ScopedPreferences,
        service: String
    ) throws {
        let urlKey = "foundryx.cell.url"
        let modeKey = "foundryx.cell.authMode"
        guard let legacyURL = defaults.string(forKey: urlKey),
              let legacyMode = defaults.string(forKey: modeKey),
              legacyMode == "idToken" || legacyMode == "bearer" else {
            return
        }

        if legacyMode == "bearer" {
            guard try adoptLegacyKeychainSecretIfNeeded(
                service: service,
                scope: scoped.scope
            ) else {
                // Keep the three-part record atomic. A missing legacy bearer is an
                // incomplete pairing, so neither scoped preference is published.
                return
            }
        }

        defaults.set(legacyURL, forKey: scoped.key(urlKey))
        defaults.set(legacyMode, forKey: scoped.key(modeKey))
    }

    private static func adoptLegacyDoorPairing(
        defaults: UserDefaults,
        scoped: ScopedPreferences,
        service: String
    ) throws {
        let urlKey = "foundryx.door.url"
        guard let legacyURL = defaults.string(forKey: urlKey),
              try adoptLegacyKeychainSecretIfNeeded(
                service: service,
                scope: scoped.scope) else {
            return
        }
        defaults.set(legacyURL, forKey: scoped.key(urlKey))
    }

    private static func adoptLegacyKeychainSecretIfNeeded(
        service: String,
        scope: String
    ) throws -> Bool {
        let scopedQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: scope,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]
        var scopedItem: CFTypeRef?
        let scopedStatus = SecItemCopyMatching(
            scopedQuery as CFDictionary,
            &scopedItem)
        switch scopedStatus {
        case errSecSuccess:
            return true
        case errSecItemNotFound:
            break
        default:
            throw CaptureAccountScopeError.activationState(
                "Keychain could not inspect the scoped \(service) pairing "
                    + "(\(scopedStatus))")
        }

        // Items written by the shipped unscoped code have the generic-password
        // account attribute's empty legacy value. Qualifying the selector with that
        // value prevents this UPDATE from ever matching another account's item.
        // The update dictionary carries the new owner scope as required.
        let legacyQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "",
        ]
        let attributes: [String: Any] = [
            kSecAttrAccount as String: scope,
        ]
        let updateStatus = SecItemUpdate(
            legacyQuery as CFDictionary,
            attributes as CFDictionary)
        switch updateStatus {
        case errSecSuccess:
            return true
        case errSecItemNotFound:
            return false
        default:
            throw CaptureAccountScopeError.activationState(
                "Keychain could not adopt the legacy \(service) pairing "
                    + "(\(updateStatus))")
        }
    }

    // MARK: - Fallible one-time migration (MOVE only)

    private static func mergeAliasedScopes(
        _ sources: [String], into targetScope: String
    ) throws {
        guard !sources.isEmpty else { return }
        try migrationQueue.sync {
            let fileManager = FileManager.default
            let base = try durableContainer()
            let target = base.appendingPathComponent(
                targetScope, isDirectory: true)
            for sourceScope in sources
                where sourceScope != targetScope && isAccountScope(sourceScope) {
                let source = base.appendingPathComponent(
                    sourceScope, isDirectory: true)
                guard fileManager.fileExists(atPath: source.path) else { continue }
                if !fileManager.fileExists(atPath: target.path) {
                    do {
                        try fileManager.moveItem(at: source, to: target)
                    } catch {
                        throw CaptureAccountScopeError.legacyMove(
                            "\(source.path) → \(target.path): "
                                + error.localizedDescription)
                    }
                    continue
                }

                let names: [String]
                do {
                    names = try fileManager.contentsOfDirectory(atPath: source.path)
                } catch {
                    throw CaptureAccountScopeError.legacyEnumeration(
                        "\(source.path): \(error.localizedDescription)")
                }
                for name in names.sorted() {
                    let item = source.appendingPathComponent(name)
                    var destination = target.appendingPathComponent(name)
                    if fileManager.fileExists(atPath: destination.path) {
                        destination = deterministicRecoveryURL(
                            in: target,
                            discriminator: "alias|\(sourceScope)|\(name)",
                            originalName: name)
                        guard !fileManager.fileExists(atPath: destination.path) else {
                            throw CaptureAccountScopeError.legacyDestinationCollision(
                                source: item.path,
                                destination: target.appendingPathComponent(name).path,
                                recovery: destination.path)
                        }
                    }
                    do {
                        try fileManager.moveItem(at: item, to: destination)
                    } catch {
                        throw CaptureAccountScopeError.legacyMove(
                            "\(item.path) → \(destination.path): "
                                + error.localizedDescription)
                    }
                }

                // Preserve even the emptied source directory by moving it beneath
                // the retained owner. No account-library path is deleted.
                let archivedSource = target.appendingPathComponent(
                    ".aliased-\(sourceScope)", isDirectory: true)
                guard !fileManager.fileExists(atPath: archivedSource.path) else {
                    throw CaptureAccountScopeError.legacyDestinationCollision(
                        source: source.path,
                        destination: archivedSource.path,
                        recovery: archivedSource.path)
                }
                do {
                    try fileManager.moveItem(at: source, to: archivedSource)
                } catch {
                    throw CaptureAccountScopeError.legacyMove(
                        "\(source.path) → \(archivedSource.path): "
                            + error.localizedDescription)
                }
            }
        }
    }

    private static func claimLegacyPrivateData(for scope: String) throws -> Bool {
        try migrationQueue.sync {
            let fileManager = FileManager.default
            let base = try durableContainer()
            let root = base.appendingPathComponent(scope, isDirectory: true)
            do {
                try fileManager.createDirectory(
                    at: root, withIntermediateDirectories: true)
            } catch {
                throw CaptureAccountScopeError.durableContainer(error.localizedDescription)
            }

            let marker = base.appendingPathComponent(migrationMarker)
            let owner = try claimMarker(marker, scope: scope)
            guard owner == scope else { return false }

            let entries: [String]
            do {
                entries = try fileManager.contentsOfDirectory(atPath: base.path)
            } catch {
                throw CaptureAccountScopeError.legacyEnumeration(
                    "\(base.path): \(error.localizedDescription)")
            }

            var moves = entries
                .filter {
                    !$0.hasPrefix(scopePrefix)
                        && $0 != migrationMarker
                        && $0 != AccountDeletionLifecycleStore
                            .metadataDirectoryName
                }
                .sorted()
                .map {
                    LegacyMove(
                        source: base.appendingPathComponent($0),
                        destination: root.appendingPathComponent($0),
                        recoveryDiscriminator: "capture|\($0)")
                }

            let legacyChat = try legacyChatStorageURL()
            if fileManager.fileExists(atPath: legacyChat.path) {
                moves.append(LegacyMove(
                    source: legacyChat,
                    destination: root.appendingPathComponent(
                        PrivateStore.chatConversations.relativePath),
                    recoveryDiscriminator: "chat|chat-conversations.json"))
            }

            // A collision is recovered into the recorded owner's root, never left at
            // the shared parent and never allowed to clobber either version.
            for move in moves where fileManager.fileExists(atPath: move.destination.path) {
                let recovery = deterministicRecoveryURL(
                    in: root, discriminator: move.recoveryDiscriminator,
                    originalName: move.source.lastPathComponent)
                guard !fileManager.fileExists(atPath: recovery.path) else {
                    throw CaptureAccountScopeError.legacyDestinationCollision(
                        source: move.source.path,
                        destination: move.destination.path,
                        recovery: recovery.path)
                }
                do {
                    try fileManager.moveItem(at: move.source, to: recovery)
                } catch {
                    throw CaptureAccountScopeError.legacyMove(
                        "\(move.source.path) → \(recovery.path): "
                            + error.localizedDescription)
                }
                throw CaptureAccountScopeError.legacyDestinationCollision(
                    source: move.source.path,
                    destination: move.destination.path,
                    recovery: recovery.path)
            }

            for move in moves {
                do {
                    try fileManager.moveItem(
                        at: move.source, to: move.destination)
                } catch {
                    throw CaptureAccountScopeError.legacyMove(
                        "\(move.source.path) → \(move.destination.path): "
                            + error.localizedDescription)
                }
            }
            return true
        }
    }

    private static func legacyPrivateDataBelongs(to scope: String) throws -> Bool {
        let marker = try durableContainer().appendingPathComponent(migrationMarker)
        guard FileManager.default.fileExists(atPath: marker.path) else { return false }
        return try readMarker(marker) == scope
    }

    private static func claimMarker(_ marker: URL, scope: String) throws -> String {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: marker.path) {
            // An EXISTING marker is not evidence of a durable claim: a previous attempt
            // may have created it and then failed its fsync, leaving it in page cache
            // only. Trusting mere existence let that attempt succeed on retry and
            // publish ACTIVE over an unpersisted claim (terra round-3, P0-3), so the
            // ownership is re-confirmed here before it is honoured.
            return try confirmDurableMarker(marker)
        }
        do {
            try Data(scope.utf8).write(to: marker, options: .withoutOverwriting)
        } catch {
            // Only the create race may adopt another process's fully durable marker.
            if fileManager.fileExists(atPath: marker.path) {
                return try readMarker(marker)
            }
            throw CaptureAccountScopeError.ownershipMarker(
                "\(marker.path): \(error.localizedDescription)")
        }

        var handle: FileHandle?
        do {
            handle = try FileHandle(forWritingTo: marker)
            stateLock.lock()
            let injectFailure = markerSyncFailureForTests
            stateLock.unlock()
            if injectFailure {
                throw CaptureAccountScopeError.ownershipMarker(
                    "\(marker.path): injected post-create synchronization failure")
            }
            try handle?.synchronize()
            try handle?.close()
            handle = nil
            let verified = try readMarker(marker)
            guard verified == scope else {
                throw CaptureAccountScopeError.ownershipMarker(
                    "\(marker.path) failed owner read-back verification")
            }
            return scope
        } catch let error as CaptureAccountScopeError {
            try? handle?.close()
            throw error
        } catch {
            try? handle?.close()
            throw CaptureAccountScopeError.ownershipMarker(
                "\(marker.path): \(error.localizedDescription)")
        }
    }

    private static func readMarker(_ marker: URL) throws -> String {
        do {
            let value = try String(contentsOf: marker, encoding: .utf8)
            guard isAccountScope(value) else {
                throw CaptureAccountScopeError.ownershipMarker(
                    "\(marker.path) contains an invalid owner")
            }
            return value
        } catch let error as CaptureAccountScopeError {
            throw error
        } catch {
            throw CaptureAccountScopeError.ownershipMarker(
                "\(marker.path): \(error.localizedDescription)")
        }
    }

    /// Re-confirm that an already-present ownership marker is genuinely on stable
    /// storage before honouring it, and return its owner. A marker that cannot be
    /// fsynced is treated as an unclaimed container, not as a valid claim, so a
    /// previously-failed attempt cannot become ACTIVE simply by retrying.
    private static func confirmDurableMarker(_ marker: URL) throws -> String {
        stateLock.lock()
        let injectFailure = markerSyncFailureForTests
        stateLock.unlock()
        if injectFailure {
            throw CaptureAccountScopeError.ownershipMarker(
                "\(marker.path): injected marker re-confirmation failure")
        }
        var handle: FileHandle?
        do {
            handle = try FileHandle(forWritingTo: marker)
            try handle?.synchronize()
            try handle?.close()
            handle = nil
        } catch let error as CaptureAccountScopeError {
            try? handle?.close()
            throw error
        } catch {
            try? handle?.close()
            throw CaptureAccountScopeError.ownershipMarker(
                "\(marker.path) could not be re-confirmed durable: "
                    + error.localizedDescription)
        }
        return try readMarker(marker)
    }

    private static func deterministicRecoveryURL(
        in root: URL, discriminator: String, originalName: String
    ) -> URL {
        let digest = key(forAccountKeyMaterial: discriminator)
            .dropFirst(scopePrefix.count)
        return root.appendingPathComponent(
            "recovered-\(digest)-\(originalName)",
            isDirectory: false)
    }

    // MARK: - Durable path accessors

    private static var failClosedContainer: URL {
        URL(fileURLWithPath: "/dev/null", isDirectory: false)
            .appendingPathComponent("foundryx-captures", isDirectory: true)
    }

    private static var failClosedRoot: URL {
        failClosedContainer.appendingPathComponent(
            "account-scope-unavailable", isDirectory: true)
    }

    private static func durableContainer() throws -> URL {
        stateLock.lock()
        let overridden = containerOverride
        let cached = lastValidatedContainer
        stateLock.unlock()

        let candidate: URL
        if let overridden {
            candidate = overridden
        } else if let cached {
            return cached
        } else {
            do {
                let documents = try FileManager.default.url(
                    for: .documentDirectory, in: .userDomainMask,
                    appropriateFor: nil, create: true)
                candidate = documents.appendingPathComponent(
                    "foundryx-captures", isDirectory: true)
            } catch {
                if let cached { return cached }
                throw CaptureAccountScopeError.durableContainer(
                    error.localizedDescription)
            }
        }

        do {
            try FileManager.default.createDirectory(
                at: candidate, withIntermediateDirectories: true)
            let values = try candidate.resourceValues(forKeys: [.isDirectoryKey])
            guard values.isDirectory == true else {
                throw CaptureAccountScopeError.durableContainer(
                    "\(candidate.path) is not a directory")
            }
        } catch let error as CaptureAccountScopeError {
            throw error
        } catch {
            if overridden == nil, let cached { return cached }
            throw CaptureAccountScopeError.durableContainer(
                "\(candidate.path): \(error.localizedDescription)")
        }

        stateLock.lock()
        lastValidatedContainer = candidate
        stateLock.unlock()
        return candidate
    }

    private static func legacyChatStorageURL() throws -> URL {
        stateLock.lock()
        let overridden = applicationSupportOverride
        stateLock.unlock()
        let base: URL
        if let overridden {
            base = overridden
        } else {
            do {
                base = try FileManager.default.url(
                    for: .applicationSupportDirectory, in: .userDomainMask,
                    appropriateFor: nil, create: true)
            } catch {
                throw CaptureAccountScopeError.durableContainer(
                    "Application Support: \(error.localizedDescription)")
            }
        }
        return base
            .appendingPathComponent("FoundryX", isDirectory: true)
            .appendingPathComponent("chat-conversations.json")
    }

    // MARK: - Persisted state and cache

    private static func currentResolution() -> Resolution {
        stateLock.lock()
        if let cachedResolution {
            stateLock.unlock()
            return cachedResolution
        }
        stateLock.unlock()

        resolutionProbeLock.withLock {
            resolutionPersistenceEntriesForTests += 1
        }
        let restored: (
            resolution: Resolution,
            preferenceValues: [String: AccountPreferenceValue]?
        ) = persistenceQueue.sync {
            do {
                guard let record = try decodeActivationRecord() else {
                    // This may be a genuinely signed-out fresh install, or a
                    // pre-scope signed-in install whose keychain is locked. Only a
                    // readable keychain miss may turn it into explicit signed-out.
                    //
                    // Resolving this to `.blocked` unconditionally broke the FREE
                    // on-device tier: a fresh install has no activation record, so
                    // every capture root became the fail-closed path and no producer
                    // could bind (Nick 2026-07-25). The mirror is readable while the
                    // device is locked; the keychain is not.
                    // The mirror is the authority on "someone is signed in" — it is a
                    // UserDefaults boolean, so it is readable even while the device is
                    // locked, and it is stamped on every successful save/load.
                    if currentDefaults().bool(forKey: AuthStore.signedInMirrorKey) {
                        return (.blocked, nil)
                    }
                    let identityPresence = stateLock.withLock {
                        identityPresenceOverrideForTests
                    } ?? AuthStore.identityPresence()
                    switch identityPresence {
                    case .absent:
                        // Genuinely never signed in — the free on-device tier.
                        return (
                            .signedOut,
                            AccountPreferenceActivationStore.restoreExisting(
                                scope: signedOutScope,
                                defaults: currentDefaults()))
                    case .present:
                        // An identity exists but was never activated (a pre-scope
                        // install): claim ownership first, do not expose a root.
                        return (.blocked, nil)
                    case .unreadableLocked:
                        // Locked device: an identity may exist. Fail closed rather
                        // than strand authenticated audio in `acct-none`.
                        return (.blocked, nil)
                    case .unreadable:
                        // The keychain cannot answer for a non-lock reason, e.g.
                        // errSecMissingEntitlement in a test host. The mirror has
                        // already said nobody is signed in, and blocking here made the
                        // free tier fail closed on the whole iOS runtime.
                        return (
                            .signedOut,
                            AccountPreferenceActivationStore.restoreExisting(
                                scope: signedOutScope,
                                defaults: currentDefaults()))
                    }
                }
                switch record.phase {
                case .signedOut:
                    return (
                        .signedOut,
                        AccountPreferenceActivationStore.restoreExisting(
                            scope: signedOutScope,
                            defaults: currentDefaults()))
                case .active:
                    guard let scope = record.scope, isAccountScope(scope) else {
                        return (.blocked, nil)
                    }
                    switch AccountDeletionLifecycleStore(
                        container: try durableContainer()
                    ).read(ownerScope: scope) {
                    case .missing:
                        break
                    case .record(let deletion)
                        where deletion.phase == .completed:
                        guard currentDefaults().object(
                            forKey: AuthStore.signedInMirrorKey) != nil,
                              currentDefaults().bool(
                                forKey: AuthStore.signedInMirrorKey)
                        else { return (.blocked, nil) }
                    case .record, .blocked:
                        return (.blocked, nil)
                    }
                    // The activation record and the App-Group handoff are two
                    // independent durable witnesses. A stale/missing owner tag
                    // cannot be repaired by currentAccountBinding() before this
                    // check and therefore never authorizes locked recording.
                    guard currentDefaults().bool(
                            forKey: AuthStore.signedInMirrorKey),
                          CaptureWidgetSnapshotStore.persistedActiveOwner
                            == scope else {
                        return (.blocked, nil)
                    }
                    return (
                        .account(scope),
                        AccountPreferenceActivationStore.restoreExisting(
                            scope: scope,
                            defaults: currentDefaults()))
                case .pendingActivation, .pendingSignOut:
                    return (.blocked, nil)
                }
            } catch {
                return (.blocked, nil)
            }
        }

        stateLock.lock()
        if cachedResolution == nil {
            cachedResolution = restored.resolution
            if let preferenceValues = restored.preferenceValues,
               let scope = resolvedScope(restored.resolution) {
                cachedAccountPreferenceSnapshot = AccountPreferenceSnapshot(
                    scope: scope,
                    generation: generation,
                    values: preferenceValues)
            } else {
                cachedAccountPreferenceSnapshot = nil
            }
        }
        let answer = cachedResolution ?? restored.resolution
        stateLock.unlock()
        return answer
    }

    private static func completedDeletionAllowsReturn(
        ownerScope: String,
        identity: AuthIdentity,
        recoveryProgress: @escaping @Sendable (DeletionSignInRecoveryEvent) -> Void = { _ in }
    ) async throws -> Bool {
        let store = AccountDeletionLifecycleStore(
            container: try durableContainer())
        switch store.read(ownerScope: ownerScope) {
        case .missing:
            return false
        case .record(let record) where record.phase == .completed:
            return true
        case .record:
            recoveryProgress(.required)
            installResolution(
                .blocked, widgetOwner: nil, identityTransition: true)
            do {
                let recovery = stateLock.withLock {
                    interruptedDeletionRecoveryForTests
                }
                if let recovery {
                    try await recovery(identity)
                } else {
                    let services = stateLock.withLock {
                        pairingKeychainServicesOverride
                            ?? (
                                cell: "com.goforgeit.foundryx.cell",
                                door: DoorConfigStore.service)
                    }
                    let runner = CurrentOwnerSelectiveDeletionRunner(
                        containerProvider: { CaptureAccountScope.container() },
                        defaults: currentDefaults(),
                        secretStore: SystemPairingSecretStore(),
                        pairingServices: services,
                        exposureCoordinator: .process,
                        identityProvider: { identity },
                        progress: recoveryProgress)
                    try await runner.eraseVerifiedCurrentOwner()
                }
                recoveryProgress(.succeeded)
                DeletionRecorder.shared.emit(
                    "account.signin.cleanup_completed", "ok")
                return true
            } catch {
                let detail = AccountDeletionRecoveryFailure.describe(error)
                recoveryProgress(.failed(detail.stage, detail.reason))
                DeletionRecorder.shared.emit(
                    "account.signin.refused", "cleanup_failed \(error)")
                throw CaptureAccountScopeError.deletionCleanupPending(
                    ownerScope: ownerScope)
            }
        case .blocked(let reason):
            installResolution(
                .blocked, widgetOwner: nil, identityTransition: true)
            throw CaptureAccountScopeError.activationState(
                "account deletion state is unreadable: \(reason)")
        }
    }

    static func blockForAccountDeletion(
        expected binding: AccountBinding
    ) throws -> UInt64 {
        try persistenceQueue.sync {
            try blockForAccountDeletionInsidePersistence(
                expected: binding)
        }
    }

    static func persistPendingAccountDeletion(
        expected binding: AccountBinding,
        persistPending:
            @Sendable () throws -> AccountDeletionLifecycleRecord
    ) throws -> AccountDeletionLifecycleRecord {
        try persistenceQueue.sync {
            exposurePublicationLock.lock()
            defer { exposurePublicationLock.unlock() }
            lockPreferenceMutationGateForTransition()
            defer { unlockPreferenceMutationGate() }

            stateLock.lock()
            let isCurrentOwner = generation == binding.generation
                && resolvedScope(cachedResolution) == binding.scope
            if isCurrentOwner {
                pendingDeletionAdmissions.insert(binding.scope)
            }
            stateLock.unlock()
            guard isCurrentOwner else {
                throw AccountDeletionLifecycleError.staleBinding
            }

            // The durable write intentionally runs without stateLock. Cache readers
            // observe the process admission set while publication and preference
            // mutation remain closed around the write.
            let pending: AccountDeletionLifecycleRecord
            do {
                pending = try persistPending()
            } catch {
                let container = binding.root.deletingLastPathComponent()
                let durable = AccountDeletionLifecycleStore(
                    container: container
                ).readWithOwnerAdmission(ownerScope: binding.scope)
                if durable == .missing {
                    _ = stateLock.withLock {
                        pendingDeletionAdmissions.remove(binding.scope)
                    }
                }
                throw error
            }
            stateLock.lock()
            guard generation == binding.generation,
                  resolvedScope(cachedResolution) == binding.scope else {
                pendingDeletionAdmissions.remove(binding.scope)
                stateLock.unlock()
                throw AccountDeletionLifecycleError.staleBinding
            }
            deletionWorkAuthorizations[binding.scope] =
                AccountDeletionWorkAuthorization(
                    binding: binding,
                    deletionEpoch: pending.deletionEpoch,
                    blockedGeneration: generation)
            stateLock.unlock()
            return pending
        }
    }

    private static func blockForAccountDeletionInsidePersistence(
        expected binding: AccountBinding
    ) throws -> UInt64 {
        exposurePublicationLock.lock()
        defer { exposurePublicationLock.unlock() }
        lockPreferenceMutationGateForTransition()
        stateLock.lock()
        guard generation == binding.generation,
              resolvedScope(cachedResolution) == binding.scope else {
            stateLock.unlock()
            unlockPreferenceMutationGate()
            throw AccountDeletionLifecycleError.staleBinding
        }
        cachedResolution = .blocked
        cachedAccountPreferenceSnapshot = nil
        cachedSharedAdmissionScope = nil
        cachedSharedAdmissionCell = nil
        cachedSharedAdmissionEpoch = nil
        blockedDeletionAdmissions.insert(binding.scope)
        pendingDeletionAdmissions.remove(binding.scope)
        generation &+= 1
        let revision = generation
        if let authorization = deletionWorkAuthorizations[binding.scope] {
            deletionWorkAuthorizations[binding.scope] =
                AccountDeletionWorkAuthorization(
                    binding: authorization.binding,
                    deletionEpoch: authorization.deletionEpoch,
                    blockedGeneration: revision)
        }
        stateLock.unlock()
        unlockPreferenceMutationGate()
        return revision
    }

    static func reassertAccountDeletionBarrier(
        ownerScope: String,
        verifiedSignedOutOwner: Bool = false
    ) throws -> (AccountBinding, UInt64)? {
        try persistenceQueue.sync {
            let base = try durableContainer()
            guard case .record(let deletion) =
                    AccountDeletionLifecycleStore(container: base)
                        .read(ownerScope: ownerScope),
                  deletion.phase == .cleanupPending else {
                return nil
            }
            let activation = try readActivationRecordForMutation()
            let activationOwnsScope =
                (activation.scope == ownerScope
                    && (activation.phase == .active
                        || activation.phase == .pendingActivation))
                || (activation.previousScope == ownerScope
                    && activation.phase == .pendingSignOut)
                || (activation.phase == .signedOut && verifiedSignedOutOwner)
            guard activationOwnsScope else {
                throw AccountDeletionLifecycleError.staleBinding
            }
            exposurePublicationLock.lock()
            defer { exposurePublicationLock.unlock() }
            lockPreferenceMutationGateForTransition()
            stateLock.lock()
            if case .account(let current) = cachedResolution,
               current != ownerScope {
                stateLock.unlock()
                unlockPreferenceMutationGate()
                throw AccountDeletionLifecycleError.staleBinding
            }
            let capturedGeneration = generation
            let canonicalRoot = base.appendingPathComponent(
                ownerScope, isDirectory: true)
            let authorization: AccountDeletionWorkAuthorization
            if let existing = deletionWorkAuthorizations[ownerScope],
               existing.deletionEpoch == deletion.deletionEpoch,
               existing.binding.root.standardizedFileURL
                    == canonicalRoot.standardizedFileURL {
                authorization = existing
            } else {
                authorization = AccountDeletionWorkAuthorization(
                    binding: AccountBinding(
                        root: canonicalRoot,
                        scope: ownerScope,
                        generation: capturedGeneration),
                    deletionEpoch: deletion.deletionEpoch,
                    blockedGeneration: capturedGeneration)
            }
            cachedResolution = .blocked
            cachedAccountPreferenceSnapshot = nil
            cachedSharedAdmissionScope = nil
            cachedSharedAdmissionCell = nil
            cachedSharedAdmissionEpoch = nil
            blockedDeletionAdmissions.insert(ownerScope)
            generation &+= 1
            let blockedGeneration = generation
            deletionWorkAuthorizations[ownerScope] =
                AccountDeletionWorkAuthorization(
                    binding: authorization.binding,
                    deletionEpoch: authorization.deletionEpoch,
                    blockedGeneration: blockedGeneration)
            stateLock.unlock()
            unlockPreferenceMutationGate()
            return (
                authorization.binding,
                blockedGeneration
            )
        }
    }

    static func setSignedInMirrorFalseForAccountDeletion() throws {
        let defaults = currentDefaults()
        defaults.set(false, forKey: AuthStore.signedInMirrorKey)
        guard defaults.synchronize(),
              defaults.object(forKey: AuthStore.signedInMirrorKey) != nil,
              defaults.bool(forKey: AuthStore.signedInMirrorKey) == false else {
            throw AccountDeletionLifecycleError.durability
        }
    }

    static func deliverAccountDeletionBoundary(generation: UInt64) {
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: identityDidChangeNotification,
                object: nil,
                userInfo: ["generation": generation])
        }
    }

    private static func installResolution(
        _ requestedResolution: Resolution,
        widgetOwner: String?,
        identityTransition: Bool,
        preferenceValues: [String: AccountPreferenceValue]? = nil
    ) {
        let publication: (resolution: Resolution, widgetOwner: String?)
        if case .account(let scope) = requestedResolution,
           !accountPublicationAllowed(ownerScope: scope) {
            publication = (.blocked, nil)
        } else {
            publication = (requestedResolution, widgetOwner)
        }
        lockPreferenceMutationGateForTransition()
        stateLock.lock()
        cachedResolution = publication.resolution
        if identityTransition {
            generation &+= 1
            cachedSharedAdmissionScope = nil
            cachedSharedAdmissionCell = nil
            cachedSharedAdmissionEpoch = nil
        }
        let revision = generation
        if let preferenceValues,
           let scope = resolvedScope(publication.resolution) {
            cachedAccountPreferenceSnapshot = AccountPreferenceSnapshot(
                scope: scope,
                generation: revision,
                values: preferenceValues)
        } else if identityTransition {
            cachedAccountPreferenceSnapshot = nil
        }
        stateLock.unlock()
        unlockPreferenceMutationGate()

        guard identityTransition else { return }
        // Lock order is exposurePublicationLock -> surface-store locks. `stateLock`
        // and the preference gate are already released, matching binding publication
        // and preventing a stale reader from becoming the final widget owner.
        exposurePublicationLock.lock()
        if let owner = publication.widgetOwner {
            let base = (try? durableContainer()) ?? failClosedRoot
            let binding = AccountBinding(
                root: base.appendingPathComponent(owner, isDirectory: true),
                scope: owner,
                generation: revision)
            AccountSurfaceRegistry.publishIdentity(
                binding, replacingIdentity: true)
        } else {
            AccountSurfaceRegistry.withdrawPublishedIdentity()
        }
        exposurePublicationLock.unlock()
        if Thread.isMainThread {
            NotificationCenter.default.post(
                name: identityDidChangeNotification,
                object: nil,
                userInfo: ["generation": revision])
        } else {
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: identityDidChangeNotification,
                    object: nil,
                    userInfo: ["generation": revision])
            }
        }
    }

    private static func accountPublicationAllowed(
        ownerScope: String
    ) -> Bool {
        guard let container = try? durableContainer() else { return false }
        guard let admission = try? SharedAccountAdmissionRegistry.cell(
            container: container,
            ownerScope: ownerScope) else {
            return false
        }
        let allowed: Bool
        let admittedEpoch: UInt64?
        switch AccountDeletionLifecycleStore(container: container)
            .read(ownerScope: ownerScope) {
        case .missing:
            admittedEpoch = admission.openEpoch
            allowed = admittedEpoch != nil
        case .record(let record) where record.phase == .completed:
            let signedIn = currentDefaults().object(
                forKey: AuthStore.signedInMirrorKey) != nil
                && currentDefaults().bool(
                    forKey: AuthStore.signedInMirrorKey)
            if signedIn {
                admission.reopenAfterCompletedDeletion()
            }
            admittedEpoch = admission.openEpoch
            allowed = signedIn && admittedEpoch != nil
        case .record, .blocked:
            admission.revoke()
            admittedEpoch = nil
            allowed = false
        }
        stateLock.withLock {
            if allowed {
                blockedDeletionAdmissions.remove(ownerScope)
                cachedSharedAdmissionScope = ownerScope
                cachedSharedAdmissionCell = admission
                cachedSharedAdmissionEpoch = admittedEpoch
            } else {
                blockedDeletionAdmissions.insert(ownerScope)
                if cachedSharedAdmissionScope == ownerScope {
                    cachedSharedAdmissionScope = nil
                    cachedSharedAdmissionCell = nil
                    cachedSharedAdmissionEpoch = nil
                }
            }
        }
        return allowed
    }

    /// Called after the durable rename and parent-directory fsync, before typed
    /// readback. The blocked epoch becomes visible to every already-mapped process
    /// synchronously, and readback does not complete until previously admitted
    /// mutations have left their atomic reader leases.
    static func publishSharedDeletionTransitionBeforeReadback(
        _ record: AccountDeletionLifecycleRecord,
        container: URL
    ) throws {
        guard record.phase == .cleanupPending else { return }
        let admission = try SharedAccountAdmissionRegistry.cell(
            container: container,
            ownerScope: record.ownerScope)
        admission.revoke()
        admission.waitForReadersToDrain()
    }

    /// Mirrors a durable transition into this process's richer local state. The
    /// synchronous cross-process barrier is already published through the mapped
    /// atomic cell before typed readback; normal producers never reopen either file.
    static func cacheDurableDeletionTransition(
        _ record: AccountDeletionLifecycleRecord,
        container: URL
    ) {
        if record.phase == .cleanupPending,
           let admission = try? SharedAccountAdmissionRegistry.cell(
                container: container,
                ownerScope: record.ownerScope) {
            admission.revoke()
        }
        stateLock.lock()
        guard let knownContainer = containerOverride ?? lastValidatedContainer,
              knownContainer.standardizedFileURL
                == container.standardizedFileURL else {
            stateLock.unlock()
            return
        }
        var withdrawWidget = false
        switch record.phase {
        case .cleanupPending:
            blockedDeletionAdmissions.insert(record.ownerScope)
            withdrawWidget =
                resolvedScope(cachedResolution) == record.ownerScope
        case .completed:
            // A proper deletion transaction has already moved the process resolution
            // to `.blocked`. If an out-of-band writer completes without doing that,
            // retain the cached block until activation re-resolves the owner so the
            // old generation can never reopen.
            if resolvedScope(cachedResolution) != record.ownerScope {
                blockedDeletionAdmissions.remove(record.ownerScope)
            }
        }
        stateLock.unlock()
        if withdrawWidget {
            _ = CaptureWidgetSnapshotStore.withdraw(
                expectedOwner: record.ownerScope)
        }
    }

    /// Caller holds `stateLock`.
    private static func deletionAdmissionBlockedLocked(
        _ ownerScope: String
    ) -> Bool {
        pendingDeletionAdmissions.contains(ownerScope)
            || blockedDeletionAdmissions.contains(ownerScope)
    }

    private static func lockPreferenceMutationGateForTransition() {
        preferenceBarrierProbeLock.lock()
        if preferenceMutationLock.try() {
            preferenceBarrierProbeLock.unlock()
            return
        }
        let barrier = activePreferenceWriteBarrier
        preferenceBarrierProbeLock.unlock()
        barrier?.identityTransitionWillWaitAtGate()
        preferenceMutationLock.lock()
    }

    private static func unlockPreferenceMutationGate() {
        preferenceBarrierProbeLock.lock()
        activePreferenceWriteBarrier = nil
        let admission = activePreferenceAdmissionLease
        activePreferenceAdmissionLease = nil
        preferenceMutationLock.unlock()
        preferenceBarrierProbeLock.unlock()
        admission?.release()
    }

    private static func resolvedScope(_ resolution: Resolution?) -> String? {
        switch resolution {
        case .account(let scope): return scope
        case .signedOut: return signedOutScope
        case .blocked, nil: return nil
        }
    }

    private static func readActivationRecordForMutation() throws -> ActivationRecord {
        try decodeActivationRecord() ?? .signedOut
    }

    private static func decodeActivationRecord() throws -> ActivationRecord? {
        guard let data = currentDefaults().data(forKey: activationStateKey) else {
            return nil
        }
        do {
            return try JSONDecoder().decode(ActivationRecord.self, from: data)
        } catch {
            throw CaptureAccountScopeError.activationState(
                "stored state is unreadable: \(error.localizedDescription)")
        }
    }

    private static func persistActivationRecord(_ record: ActivationRecord) throws {
        let defaults = currentDefaults()
        do {
            let data = try JSONEncoder().encode(record)
            defaults.set(data, forKey: activationStateKey)
            guard defaults.synchronize(),
                  defaults.data(forKey: activationStateKey) == data else {
                throw CaptureAccountScopeError.activationState(
                    "UserDefaults did not durably retain the activation record")
            }
        } catch let error as CaptureAccountScopeError {
            throw error
        } catch {
            throw CaptureAccountScopeError.activationState(
                error.localizedDescription)
        }
    }

    private static func currentDefaults() -> UserDefaults {
        stateLock.lock()
        let overridden = defaultsOverride
        stateLock.unlock()
        return overridden ?? .standard
    }

    static var accountSurfaceDefaults: UserDefaults { currentDefaults() }

    private static func isAccountScope(_ scope: String) -> Bool {
        guard scope.hasPrefix(scopePrefix), scope != signedOutScope else { return false }
        let digest = scope.dropFirst(scopePrefix.count)
        return !digest.isEmpty && digest.count <= 16
            && digest.allSatisfy(\.isHexDigit)
    }

    // MARK: - Hermetic test support

    public static func setContainerForTests(_ url: URL?) {
        SharedAccountAdmissionRegistry.resetForTests()
        preferenceMutationLock.lock()
        stateLock.lock()
        containerOverride = url
        lastValidatedContainer = nil
        cachedResolution = nil
        cachedAccountPreferenceSnapshot = nil
        deletionWorkAuthorizations.removeAll()
        pendingDeletionAdmissions.removeAll()
        blockedDeletionAdmissions.removeAll()
        cachedSharedAdmissionScope = nil
        cachedSharedAdmissionCell = nil
        cachedSharedAdmissionEpoch = nil
        generation &+= 1
        stateLock.unlock()
        preferenceMutationLock.unlock()
    }

    static func setApplicationSupportRootForTests(_ url: URL?) {
        stateLock.lock()
        applicationSupportOverride = url
        stateLock.unlock()
    }

    static func setDefaultsForTests(_ defaults: UserDefaults?) {
        preferenceMutationLock.lock()
        stateLock.lock()
        defaultsOverride = defaults
        cachedResolution = nil
        cachedAccountPreferenceSnapshot = nil
        deletionWorkAuthorizations.removeAll()
        pendingDeletionAdmissions.removeAll()
        blockedDeletionAdmissions.removeAll()
        cachedSharedAdmissionScope = nil
        cachedSharedAdmissionCell = nil
        cachedSharedAdmissionEpoch = nil
        generation &+= 1
        stateLock.unlock()
        preferenceMutationLock.unlock()
    }

    static func setIdentityPresenceForTests(
        _ presence: AuthStore.IdentityPresence?
    ) {
        stateLock.withLock {
            identityPresenceOverrideForTests = presence
            cachedResolution = nil
            cachedAccountPreferenceSnapshot = nil
            generation &+= 1
        }
    }

    static func setPairingKeychainServicesForTests(
        cell: String,
        door: String
    ) {
        stateLock.lock()
        pairingKeychainServicesOverride = (cell: cell, door: door)
        stateLock.unlock()
    }

    static func setMarkerSyncFailureForTests(_ enabled: Bool) {
        stateLock.lock()
        markerSyncFailureForTests = enabled
        stateLock.unlock()
    }

    static func setInterruptedDeletionRecoveryForTests(
        _ recovery: (@Sendable (AuthIdentity) async throws -> Void)?
    ) {
        stateLock.withLock {
            interruptedDeletionRecoveryForTests = recovery
        }
    }

    /// Publishes an account identity for fixtures. Preference activation is opt-in
    /// so the accepted Task-1 snapshot/writer oracles retain their identity-only
    /// setup; Task-6 feature worlds request the production activation path.
    static func activateForTests(
        _ identity: AuthIdentity,
        activatePreferences: Bool = false
    ) throws {
        let ownerScope = try key(for: identity)
        let completedDeletion: Bool
        switch AccountDeletionLifecycleStore(
            container: try durableContainer()).read(ownerScope: ownerScope) {
        case .missing:
            completedDeletion = false
        case .record(let record) where record.phase == .completed:
            completedDeletion = true
        case .record:
            installResolution(
                .blocked, widgetOwner: nil, identityTransition: true)
            throw CaptureAccountScopeError.deletionCleanupPending(
                ownerScope: ownerScope)
        case .blocked(let reason):
            installResolution(
                .blocked, widgetOwner: nil, identityTransition: true)
            throw CaptureAccountScopeError.activationState(
                "account deletion state is unreadable: \(reason)")
        }
        let transaction = try beginActivationAfterDeletionCheck(
            identity, completedDeletion: completedDeletion)
        try completeActivationAfterDeletionCheck(
            transaction,
            activatePreferences: activatePreferences,
            deletionCompleted: completedDeletion)
    }

    static func beginActivationForTestsOnly(
        for identity: AuthIdentity
    ) throws -> ActivationTransaction {
        let ownerScope = try key(for: identity)
        let completedDeletion: Bool
        switch AccountDeletionLifecycleStore(
            container: try durableContainer()).read(ownerScope: ownerScope) {
        case .missing:
            completedDeletion = false
        case .record(let record) where record.phase == .completed:
            completedDeletion = true
        case .record:
            installResolution(
                .blocked, widgetOwner: nil, identityTransition: true)
            throw CaptureAccountScopeError.deletionCleanupPending(
                ownerScope: ownerScope)
        case .blocked(let reason):
            installResolution(
                .blocked, widgetOwner: nil, identityTransition: true)
            throw CaptureAccountScopeError.activationState(
                "account deletion state is unreadable: \(reason)")
        }
        return try beginActivationAfterDeletionCheck(
            identity, completedDeletion: completedDeletion)
    }

    static func completeActivationForTestsOnly(
        _ transaction: ActivationTransaction,
        activatePreferences: Bool = true
    ) throws {
        let deletionCompleted: Bool
        switch AccountDeletionLifecycleStore(
            container: try durableContainer()).read(ownerScope: transaction.scope) {
        case .missing:
            deletionCompleted = false
        case .record(let record) where record.phase == .completed:
            deletionCompleted = true
        case .record:
            installResolution(
                .blocked, widgetOwner: nil, identityTransition: true)
            throw CaptureAccountScopeError.deletionCleanupPending(
                ownerScope: transaction.scope)
        case .blocked(let reason):
            installResolution(
                .blocked, widgetOwner: nil, identityTransition: true)
            throw CaptureAccountScopeError.activationState(
                "account deletion state is unreadable: \(reason)")
        }
        try completeActivationAfterDeletionCheck(
            transaction,
            activatePreferences: activatePreferences,
            deletionCompleted: deletionCompleted)
    }

    /// Fixture-only account publication that bypasses UserDefaults durability. It
    /// keeps process-boundary admission tests runnable on sandboxed hosts where
    /// `UserDefaults.synchronize()` is deliberately denied.
    static func installAccountResolutionForTests(scope: String) throws {
        guard AccountDeletionLifecycleStore.isValidOwnerScope(scope) else {
            throw CaptureAccountScopeError.missingStableIdentity
        }
        installResolution(
            .account(scope),
            widgetOwner: scope,
            identityTransition: true)
        guard currentAccountBinding()?.scope == scope else {
            throw CaptureAccountScopeError.activationState(
                "test account resolution was not published")
        }
    }

    static var isInsidePreferenceMutation: Bool {
        (Thread.current.threadDictionary[
            preferenceMutationDepthKey] as? Int ?? 0) > 0
    }

    static func setBeforeAccountBindingPublicationHookForTests(
        _ hook: (() -> Void)?
    ) {
        stateLock.withLock {
            beforeAccountBindingPublicationHook = hook
        }
    }

    #if DEBUG || PERF_HARNESS
    static func setAfterAccountBindingGuardHookForTests(
        _ hook: (() -> Void)?
    ) {
        stateLock.withLock {
            afterAccountBindingGuardHookForTests = hook
        }
    }
    #endif

    static func setActivationMigrationPauseHookForTests(
        _ hook: (() -> Void)?
    ) {
        stateLock.withLock {
            activationMigrationPauseHookForTests = hook
        }
    }

    static func signOutForTests() throws {
        _ = try beginSignOut()
        try completeSignOut()
    }

    static func resetProcessCacheForTests() {
        preferenceMutationLock.lock()
        stateLock.lock()
        cachedResolution = nil
        cachedAccountPreferenceSnapshot = nil
        pendingDeletionAdmissions.removeAll()
        blockedDeletionAdmissions.removeAll()
        generation &+= 1
        stateLock.unlock()
        preferenceMutationLock.unlock()
    }

    static func resetResolutionPersistenceEntriesForTests() {
        resolutionProbeLock.withLock {
            resolutionPersistenceEntriesForTests = 0
        }
    }

    static var resolutionPersistenceEntryCountForTests: Int {
        resolutionProbeLock.withLock {
            resolutionPersistenceEntriesForTests
        }
    }

    /// Compatibility with the round-one driver while it is being migrated.
    public static func setAccountForTests(email: String?) {
        if let email {
            let identity = AuthIdentity(
                provider: AuthProvider.google.rawValue,
                idToken: "",
                refreshToken: nil,
                expiresAt: .distantFuture,
                email: email)
            try? activateForTests(identity)
        } else {
            try? signOutForTests()
        }
    }

    public static func clearOverrideForTests() {
        resetProcessCacheForTests()
    }

    public static func invalidate() {
        resetProcessCacheForTests()
    }

    static func resetTestEnvironment() {
        SharedAccountAdmissionRegistry.resetForTests()
        preferenceMutationLock.lock()
        stateLock.lock()
        containerOverride = nil
        applicationSupportOverride = nil
        defaultsOverride = nil
        pairingKeychainServicesOverride = nil
        interruptedDeletionRecoveryForTests = nil
        beforeAccountBindingPublicationHook = nil
        #if DEBUG || PERF_HARNESS
        afterAccountBindingGuardHookForTests = nil
        #endif
        activationMigrationPauseHookForTests = nil
        identityPresenceOverrideForTests = nil
        lastValidatedContainer = nil
        cachedResolution = nil
        cachedAccountPreferenceSnapshot = nil
        cachedSharedAdmissionScope = nil
        cachedSharedAdmissionCell = nil
        cachedSharedAdmissionEpoch = nil
        markerSyncFailureForTests = false
        generation &+= 1
        stateLock.unlock()
        preferenceMutationLock.unlock()
        resetResolutionPersistenceEntriesForTests()
    }
}

// MARK: - Account-bound widget snapshot writes
//
// This lives HERE, not in CaptureWidgetSnapshot.swift, on purpose: the FoundryXWidget
// extension target compiles that file but not this one, so anything referencing
// `CaptureAccountScope` from there breaks the extension build while SwiftPM tests stay
// green. The widget only READS snapshots; the account-bound write is app-side.
extension CaptureWidgetSnapshotStore {
    /// Persist the latest snapshot for the widget to read. Signed-out on-device capture
    /// uses its isolated `acct-none` owner just like a signed-in account uses its scope.
    /// The write is rejected when the originating identity is no longer current.
    @discardableResult
    public static func write(
        _ snapshot: CaptureWidgetSnapshot,
        as binding: CaptureAccountScope.AccountBinding
    ) -> Bool {
        CaptureAccountScope.perform(as: binding) { captured in
            stateLock.lock()
            defer { stateLock.unlock() }
            guard let defaults,
                  defaults.string(forKey: activeOwnerKey) == captured.scope,
                  let data = try? JSONEncoder().encode(
                    Envelope(owner: captured.scope, snapshot: snapshot))
            else { return }
            defaults.set(data, forKey: key)
        } != nil
    }
}
