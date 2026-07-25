// CaptureAccountScope — the storage boundary for everything FoundryX keeps for a
// signed-in user. Account isolation is an invariant, not a caller convention:
// durable user-private stores resolve through this type, and asynchronous work
// carries an immutable AccountBinding rather than re-resolving a later identity.

import Foundation

public enum CaptureAccountScopeError: Error, LocalizedError {
    case missingStableIdentity
    case activationAlreadyPending
    case activationState(String)
    case durableContainer(String)
    case ownershipMarker(String)
    case legacyEnumeration(String)
    case legacyMove(String)
    case legacyDestinationCollision(source: String, destination: String, recovery: String)

    public var errorDescription: String? {
        switch self {
        case .missingStableIdentity:
            return "The provider did not return a stable account subject or email."
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

        public var isCurrent: Bool {
            CaptureAccountScope.isCurrent(self)
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
              resolvedScope(cachedResolution) == binding.scope else {
            stateLock.unlock()
            return nil
        }
        defer { stateLock.unlock() }
        return try mutation(binding)
    }

    struct ActivationTransaction: Sendable {
        let scope: String
        let previousScope: String?
        let requiresActivation: Bool
        let aliases: [String: String]
        let aliasSources: [String]
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

    private static let activationStateKey = "foundryx.capture-account-activation.v2"
    private static let oldPersistedScopeKey = "foundryx.capture-account-scope"
    public static let identityDidChangeNotification =
        Notification.Name("foundryx.capture-account-identity-did-change")

    private static let stateLock = NSLock()
    private static let persistenceQueue =
        DispatchQueue(label: "foundryx.capture-account-persistence")
    private static let migrationQueue =
        DispatchQueue(label: "foundryx.capture-account-migration")

    nonisolated(unsafe) private static var cachedResolution: Resolution?
    nonisolated(unsafe) private static var generation: UInt64 = 0
    nonisolated(unsafe) private static var containerOverride: URL?
    nonisolated(unsafe) private static var applicationSupportOverride: URL?
    nonisolated(unsafe) private static var defaultsOverride: UserDefaults?
    nonisolated(unsafe) private static var lastValidatedContainer: URL?
    nonisolated(unsafe) private static var markerSyncFailureForTests = false

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
    static func beginActivation(for identity: AuthIdentity) throws -> ActivationTransaction {
        return try persistenceQueue.sync {
            let current = try readActivationRecordForMutation()
            let resolved = try resolveIdentityScope(identity, against: current)
            let target = resolved.scope
            switch current.phase {
            case .active where current.scope == target:
                if current.aliases != resolved.aliases {
                    try persistActivationRecord(
                        .active(target, aliases: resolved.aliases))
                }
                return ActivationTransaction(
                    scope: target, previousScope: target, requiresActivation: false,
                    aliases: resolved.aliases,
                    aliasSources: resolved.aliasSources)
            case .pendingActivation where current.scope == target:
                return ActivationTransaction(
                    scope: target, previousScope: current.previousScope,
                    requiresActivation: true, aliases: resolved.aliases,
                    aliasSources: resolved.aliasSources)
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
                    aliasSources: resolved.aliasSources)
            }
        }
    }

    /// Complete the filesystem claim before publishing ACTIVE. Errors leave PENDING
    /// intact so this owner can retry and a different identity cannot steal the claim.
    static func completeActivation(_ transaction: ActivationTransaction) throws {
        guard transaction.requiresActivation else {
            persistenceQueue.sync {
                installResolution(
                    .account(transaction.scope), widgetOwner: nil,
                    identityTransition: false)
            }
            return
        }
        try mergeAliasedScopes(
            transaction.aliasSources, into: transaction.scope)
        try claimLegacyPrivateData(for: transaction.scope)
        try persistenceQueue.sync {
            let record = try readActivationRecordForMutation()
            guard record.phase == .pendingActivation,
                  record.scope == transaction.scope else {
                throw CaptureAccountScopeError.activationState(
                    "the pending owner changed before activation completed")
            }
            try persistActivationRecord(.active(
                transaction.scope, aliases: record.aliases))
            let defaults = currentDefaults()
            defaults.set(true, forKey: AuthStore.signedInMirrorKey)
            defaults.removeObject(forKey: oldPersistedScopeKey)
            installResolution(
                .account(transaction.scope), widgetOwner: transaction.scope,
                identityTransition: true)
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
    static func restorePersistedIdentity(_ identity: AuthIdentity) throws -> String {
        let action: ActivationTransaction = try persistenceQueue.sync {
            let record = try readActivationRecordForMutation()
            let resolved = try resolveIdentityScope(identity, against: record)
            let target = resolved.scope
            switch record.phase {
            case .active where record.scope == target:
                if record.aliases != resolved.aliases {
                    try persistActivationRecord(
                        .active(target, aliases: resolved.aliases))
                }
                installResolution(.account(target), widgetOwner: nil,
                                  identityTransition: false)
                return ActivationTransaction(
                    scope: target, previousScope: target, requiresActivation: false,
                    aliases: resolved.aliases,
                    aliasSources: resolved.aliasSources)
            case .pendingActivation where record.scope == target:
                return ActivationTransaction(
                    scope: target, previousScope: record.previousScope,
                    requiresActivation: true, aliases: resolved.aliases,
                    aliasSources: resolved.aliasSources)
            case .pendingActivation where record.previousScope == target:
                try persistActivationRecord(
                    .active(target, aliases: resolved.aliases))
                currentDefaults().set(true, forKey: AuthStore.signedInMirrorKey)
                installResolution(.account(target), widgetOwner: target,
                                  identityTransition: true)
                return ActivationTransaction(
                    scope: target, previousScope: target, requiresActivation: false,
                    aliases: resolved.aliases,
                    aliasSources: resolved.aliasSources)
            case .pendingSignOut where record.previousScope == target:
                try persistActivationRecord(
                    .active(target, aliases: resolved.aliases))
                currentDefaults().set(true, forKey: AuthStore.signedInMirrorKey)
                installResolution(.account(target), widgetOwner: target,
                                  identityTransition: true)
                return ActivationTransaction(
                    scope: target, previousScope: target, requiresActivation: false,
                    aliases: resolved.aliases,
                    aliasSources: resolved.aliasSources)
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
                    aliasSources: resolved.aliasSources)
            }
        }
        try completeActivation(action)
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
            case .pendingActivation, .pendingSignOut:
                throw CaptureAccountScopeError.activationAlreadyPending
            }
        }
    }

    static func completeSignOut() throws {
        try persistenceQueue.sync {
            let record = try readActivationRecordForMutation()
            try persistActivationRecord(.signedOut(aliases: record.aliases))
            let defaults = currentDefaults()
            defaults.set(false, forKey: AuthStore.signedInMirrorKey)
            defaults.removeObject(forKey: oldPersistedScopeKey)
            installResolution(
                .signedOut,
                widgetOwner: signedOutScope,
                identityTransition: true)
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
              case .account = currentResolution(),
              (try? durableContainer()) != nil else { return false }
        return true
    }

    // MARK: - Account binding and store access

    public static func currentAccountBinding() -> AccountBinding? {
        guard resolvedScope(currentResolution()) != nil else { return nil }
        guard let base = try? durableContainer() else { return nil }
        stateLock.lock()
        guard let scope = resolvedScope(cachedResolution) else {
            stateLock.unlock()
            return nil
        }
        let revision = generation
        stateLock.unlock()
        // Published OUTSIDE `stateLock`: this takes the widget store's own lock and
        // performs a cross-process `synchronize()`. Nesting the two locks would make
        // the ordering load-bearing forever.
        CaptureWidgetSnapshotStore.publishActiveOwner(scope)
        return AccountBinding(
            root: base.appendingPathComponent(scope, isDirectory: true),
            scope: scope,
            generation: revision)
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
        stateLock.lock()
        let revision = generation
        stateLock.unlock()
        CaptureWidgetSnapshotStore.publishActiveOwner(scope)
        return AccountBinding(root: root, scope: scope, generation: revision)
    }

    public static func isCurrent(_ binding: AccountBinding) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return generation == binding.generation
            && resolvedScope(cachedResolution) == binding.scope
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

    private static func claimLegacyPrivateData(for scope: String) throws {
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
            guard owner == scope else { return }

            let entries: [String]
            do {
                entries = try fileManager.contentsOfDirectory(atPath: base.path)
            } catch {
                throw CaptureAccountScopeError.legacyEnumeration(
                    "\(base.path): \(error.localizedDescription)")
            }

            var moves = entries
                .filter { !$0.hasPrefix(scopePrefix) && $0 != migrationMarker }
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
        }
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

        let resolved: Resolution = persistenceQueue.sync {
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
                        return .blocked
                    }
                    switch AuthStore.identityPresence() {
                    case .absent:
                        // Genuinely never signed in — the free on-device tier.
                        return .signedOut
                    case .present:
                        // An identity exists but was never activated (a pre-scope
                        // install): claim ownership first, do not expose a root.
                        return .blocked
                    case .unreadableLocked:
                        // Locked device: an identity may exist. Fail closed rather
                        // than strand authenticated audio in `acct-none`.
                        return .blocked
                    case .unreadable:
                        // The keychain cannot answer for a non-lock reason, e.g.
                        // errSecMissingEntitlement in a test host. The mirror has
                        // already said nobody is signed in, and blocking here made the
                        // free tier fail closed on the whole iOS runtime.
                        return .signedOut
                    }
                }
                switch record.phase {
                case .signedOut: return .signedOut
                case .active:
                    guard let scope = record.scope, isAccountScope(scope) else {
                        return .blocked
                    }
                    return .account(scope)
                case .pendingActivation, .pendingSignOut:
                    return .blocked
                }
            } catch {
                return .blocked
            }
        }

        stateLock.lock()
        if cachedResolution == nil { cachedResolution = resolved }
        let answer = cachedResolution ?? resolved
        stateLock.unlock()
        return answer
    }

    private static func installResolution(
        _ resolution: Resolution,
        widgetOwner: String?,
        identityTransition: Bool
    ) {
        stateLock.lock()
        cachedResolution = resolution
        if identityTransition { generation &+= 1 }
        let revision = generation
        stateLock.unlock()

        guard identityTransition else { return }
        CaptureWidgetSnapshotStore.transition(toOwner: widgetOwner)
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

    private static func isAccountScope(_ scope: String) -> Bool {
        guard scope.hasPrefix(scopePrefix), scope != signedOutScope else { return false }
        let digest = scope.dropFirst(scopePrefix.count)
        return !digest.isEmpty && digest.count <= 16
            && digest.allSatisfy(\.isHexDigit)
    }

    // MARK: - Hermetic test support

    public static func setContainerForTests(_ url: URL?) {
        stateLock.lock()
        containerOverride = url
        lastValidatedContainer = nil
        cachedResolution = nil
        generation &+= 1
        stateLock.unlock()
    }

    static func setApplicationSupportRootForTests(_ url: URL?) {
        stateLock.lock()
        applicationSupportOverride = url
        stateLock.unlock()
    }

    static func setDefaultsForTests(_ defaults: UserDefaults?) {
        stateLock.lock()
        defaultsOverride = defaults
        cachedResolution = nil
        generation &+= 1
        stateLock.unlock()
    }

    static func setMarkerSyncFailureForTests(_ enabled: Bool) {
        stateLock.lock()
        markerSyncFailureForTests = enabled
        stateLock.unlock()
    }

    static func activateForTests(_ identity: AuthIdentity) throws {
        let transaction = try beginActivation(for: identity)
        try completeActivation(transaction)
    }

    static func signOutForTests() throws {
        _ = try beginSignOut()
        try completeSignOut()
    }

    static func resetProcessCacheForTests() {
        stateLock.lock()
        cachedResolution = nil
        generation &+= 1
        stateLock.unlock()
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
        stateLock.lock()
        containerOverride = nil
        applicationSupportOverride = nil
        defaultsOverride = nil
        lastValidatedContainer = nil
        cachedResolution = nil
        markerSyncFailureForTests = false
        generation &+= 1
        stateLock.unlock()
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
