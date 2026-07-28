import Foundation
import CoreFoundation

public enum AccountPreferencePresence<Value: Sendable & Equatable>:
    Sendable, Equatable
{
    case absent
    case value(Value)
}

public enum AccountPreferenceValue: Sendable, Equatable {
    case bool(Bool)
    case string(String)
    case double(Double)
    case boolDictionary([String: Bool])
    case data(Data)

    fileprivate func decoded<Value>(
        as _: Value.Type
    ) -> Value? {
        switch self {
        case .bool(let value):
            return value as? Value
        case .string(let value):
            return value as? Value
        case .double(let value):
            return value as? Value
        case .boolDictionary(let value):
            return value as? Value
        case .data(let value):
            return value as? Value
        }
    }

    static func encode<Value>(_ value: Value) -> Self? {
        switch value {
        case let value as Bool:
            return .bool(value)
        case let value as String:
            return .string(value)
        case let value as Double:
            return .double(value)
        case let value as [String: Bool]:
            return .boolDictionary(value)
        case let value as Data:
            return .data(value)
        default:
            return nil
        }
    }

    var defaultsValue: Any {
        switch self {
        case .bool(let value): return value
        case .string(let value): return value
        case .double(let value): return value
        case .boolDictionary(let value): return value
        case .data(let value): return value
        }
    }
}

public enum AccountPreferenceValueKind: Sendable, Equatable {
    case bool
    case string
    case double
    case boolDictionary
    case data
}

public enum AccountPreferenceFreshDefault: Sendable, Equatable {
    case absent
    case value(AccountPreferenceValue)
    case explicit(AccountPreferenceValue)
    case coldEmpty
}

public enum AccountPreferenceAdoptionPolicy: Sendable, Equatable {
    case copyExplicit
    case copyValid
    case copyExplicitOrMaterializeFalse
    case copyCompleteAtomicGroup
    case copyEstablishedExplicit
    case neverCopy
    case sealedLegacySnapshot
}

public enum AccountPreferenceAtomicGroup:
    CaseIterable, Sendable, Hashable
{
    case firstRun
    case ambientConsent
    case ambientProfile
    case vaultCheckout
    case brain
    case waitlist
    case captureRuntime
    case modelsCache
    case signup

    public var isIndivisible: Bool {
        self == .vaultCheckout
    }
}

public enum AccountPreferenceRefreshOwner: Sendable, Equatable {
    case onboardingRoot
    case personaRoot
    case welcomeRoot
    case ambientRoot
    case ambientDoor
    case actionPolicyUI
    case checkoutFunnel
    case brainRoot
    case waitlistIdentity
    case captureSession
    case sourceRegistry
    case modelChatSession
    case signupRemoteGeneration
}

public enum AccountPreferenceClassification: Sendable, Equatable {
    case account
}

public enum AccountPreferenceActivationState: Sendable, Equatable {
    case inactiveCompatibility
    case active
}

public struct AccountPreferenceCatalogEntry: Sendable, Equatable {
    public let canonicalKey: String
    public let classification: AccountPreferenceClassification
    public let valueKind: AccountPreferenceValueKind
    public let freshDefault: AccountPreferenceFreshDefault
    public let adoptionPolicy: AccountPreferenceAdoptionPolicy
    public let atomicGroup: AccountPreferenceAtomicGroup
    public let refreshOwner: AccountPreferenceRefreshOwner
    public let activationState: AccountPreferenceActivationState
}

public struct AccountPreferenceKey<Value>: Sendable {
    public let canonicalKey: String

    fileprivate init(_ canonicalKey: String) {
        self.canonicalKey = canonicalKey
    }
}

public enum AccountPreferenceCatalog {
    public static let onboardingCompleted =
        AccountPreferenceKey<Bool>("foundryx.onboarding.completed")
    public static let onboardingPersona =
        AccountPreferenceKey<String>("foundryx.onboarding.persona")
    public static let welcomeSeen =
        AccountPreferenceKey<Bool>("foundryx.welcome.seen")
    public static let welcomeLetStraightIn =
        AccountPreferenceKey<Bool>("foundryx.welcome.letStraightIn")
    public static let ambientEnabled =
        AccountPreferenceKey<Bool>("foundryx.ambient.enabled")
    public static let ambientAgentName =
        AccountPreferenceKey<String>("foundryx.ambient.agentName")
    public static let ambientGrading =
        AccountPreferenceKey<Bool>("foundryx.ambient.grading")
    public static let ambientOthersInline =
        AccountPreferenceKey<Bool>("foundryx.ambient.othersInline")
    public static let vaultCheckoutAttemptID =
        AccountPreferenceKey<String>("foundryx.vault.checkoutAttempt.id")
    public static let vaultCheckoutAttemptPlan =
        AccountPreferenceKey<String>("foundryx.vault.checkoutAttempt.plan")
    public static let brainChoice =
        AccountPreferenceKey<String>("foundryx.brain.choice")
    public static let waitlistJoined =
        AccountPreferenceKey<Bool>("foundryx.waitlist.joined")
    public static let captureSilenceGapSeconds =
        AccountPreferenceKey<Double>("foundryx.capture.silence-gap-seconds")
    public static let captureOMIDesiredState =
        AccountPreferenceKey<String>("foundryx.capture.omi-desired-state")
    public static let captureSourceEnabledOverrides =
        AccountPreferenceKey<[String: Bool]>(
            "foundryx.capture.sources.enabled-overrides")
    public static let modelsCache =
        AccountPreferenceKey<Data>("foundryx.models.cache.v1")
    public static let signupPosted =
        AccountPreferenceKey<Bool>("foundryx.account.signup-posted")

    public static let entries: [AccountPreferenceCatalogEntry] = [
        entry(
            onboardingCompleted, .bool, .value(.bool(false)),
            .copyExplicit, .firstRun, .onboardingRoot),
        entry(
            onboardingPersona, .string, .value(.string("individual")),
            .copyValid, .firstRun, .personaRoot),
        entry(
            welcomeSeen, .bool, .value(.bool(false)),
            .copyExplicit, .firstRun, .welcomeRoot),
        entry(
            welcomeLetStraightIn, .bool, .value(.bool(false)),
            .copyExplicit, .firstRun, .welcomeRoot),
        entry(
            ambientEnabled, .bool, .value(.bool(false)),
            .copyExplicit, .ambientConsent, .ambientRoot),
        entry(
            ambientAgentName, .string, .value(.string("Foundry")),
            .copyValid, .ambientProfile, .ambientRoot),
        entry(
            ambientGrading, .bool, .explicit(.bool(false)),
            .copyExplicitOrMaterializeFalse, .ambientConsent, .ambientDoor),
        entry(
            ambientOthersInline, .bool, .value(.bool(false)),
            .copyExplicit, .ambientProfile, .actionPolicyUI),
        entry(
            vaultCheckoutAttemptID, .string, .absent,
            .copyCompleteAtomicGroup, .vaultCheckout, .checkoutFunnel),
        entry(
            vaultCheckoutAttemptPlan, .string, .absent,
            .copyCompleteAtomicGroup, .vaultCheckout, .checkoutFunnel),
        entry(
            brainChoice, .string, .value(.string("phone")),
            .copyValid, .brain, .brainRoot),
        entry(
            waitlistJoined, .bool, .value(.bool(false)),
            .copyExplicit, .waitlist, .waitlistIdentity),
        entry(
            captureSilenceGapSeconds, .double, .value(.double(120)),
            .copyValid, .captureRuntime, .captureSession),
        entry(
            captureOMIDesiredState, .string, .explicit(.string("paused")),
            .copyEstablishedExplicit, .captureRuntime, .captureSession),
        entry(
            captureSourceEnabledOverrides, .boolDictionary,
            .value(.boolDictionary([:])),
            .copyEstablishedExplicit, .captureRuntime, .sourceRegistry),
        entry(
            modelsCache, .data, .coldEmpty,
            .neverCopy, .modelsCache, .modelChatSession),
        entry(
            signupPosted, .bool, .value(.bool(false)),
            .sealedLegacySnapshot, .signup, .signupRemoteGeneration),
    ]

    public static func entries(
        in group: AccountPreferenceAtomicGroup
    ) -> [AccountPreferenceCatalogEntry] {
        entries.filter { $0.atomicGroup == group }
    }

    private static func entry<Value>(
        _ key: AccountPreferenceKey<Value>,
        _ kind: AccountPreferenceValueKind,
        _ freshDefault: AccountPreferenceFreshDefault,
        _ adoptionPolicy: AccountPreferenceAdoptionPolicy,
        _ atomicGroup: AccountPreferenceAtomicGroup,
        _ refreshOwner: AccountPreferenceRefreshOwner
    ) -> AccountPreferenceCatalogEntry {
        AccountPreferenceCatalogEntry(
            canonicalKey: key.canonicalKey,
            classification: .account,
            valueKind: kind,
            freshDefault: freshDefault,
            adoptionPolicy: adoptionPolicy,
            atomicGroup: atomicGroup,
            refreshOwner: refreshOwner,
            activationState: .active)
    }
}

public struct ScopedPreferenceBinding: Sendable, Equatable {
    public let scope: String
    public let generation: UInt64

    public init(scope: String, generation: UInt64) {
        self.scope = scope
        self.generation = generation
    }
}

public struct AccountPreferenceSnapshot: Sendable, Equatable {
    public let scope: String
    public let generation: UInt64
    public let values: [String: AccountPreferenceValue]

    public init(
        scope: String,
        generation: UInt64,
        values: [String: AccountPreferenceValue]
    ) {
        self.scope = scope
        self.generation = generation
        self.values = values
    }

    public func presence<Value: Sendable & Equatable>(
        for key: AccountPreferenceKey<Value>
    ) -> AccountPreferencePresence<Value> {
        guard let value = values[key.canonicalKey],
              let decoded = value.decoded(as: Value.self) else {
            return .absent
        }
        return .value(decoded)
    }
}

public struct AccountPreferenceAdoptionSnapshot: Sendable, Equatable {
    public let scope: String
    public let generation: UInt64
    public let legacyValues: [String: AccountPreferenceValue]
    public let legacySignupPosted: AccountPreferencePresence<Bool>

    public init(
        scope: String,
        generation: UInt64,
        legacyValues: [String: AccountPreferenceValue],
        legacySignupPosted: AccountPreferencePresence<Bool>
    ) {
        self.scope = scope
        self.generation = generation
        self.legacyValues = legacyValues
        self.legacySignupPosted = legacySignupPosted
    }
}

public struct AccountPreferenceAdoptionResult: Sendable, Equatable {
    public let scope: String
    public let generation: UInt64
    public let adoptedValues: [String: AccountPreferenceValue]
    public let adoptedGroups: Set<AccountPreferenceAtomicGroup>
    public let skippedKeys: Set<String>

    public init(
        scope: String,
        generation: UInt64,
        adoptedValues: [String: AccountPreferenceValue],
        adoptedGroups: Set<AccountPreferenceAtomicGroup>,
        skippedKeys: Set<String>
    ) {
        self.scope = scope
        self.generation = generation
        self.adoptedValues = adoptedValues
        self.adoptedGroups = adoptedGroups
        self.skippedKeys = skippedKeys
    }
}

/// Pure Task-6 activation planner. It resolves one complete immutable snapshot
/// before the owner can be published active. Legacy inputs are read-only; callers
/// persist only the returned scoped values.
enum AccountPreferenceAdoptionPlanner {
    static func resolve(
        _ snapshot: AccountPreferenceAdoptionSnapshot,
        existingValues: [String: AccountPreferenceValue],
        establishedLegacyOwner: Bool
    ) -> AccountPreferenceAdoptionResult {
        var values = validValues(existingValues)
        var adoptedGroups: Set<AccountPreferenceAtomicGroup> = []
        var skippedKeys: Set<String> = []

        let checkoutEntries = AccountPreferenceCatalog.entries(
            in: .vaultCheckout)
        for entry in checkoutEntries {
            values.removeValue(forKey: entry.canonicalKey)
        }
        if let pair = validCheckout(in: existingValues) {
            values.merge(pair) { current, _ in current }
        } else if establishedLegacyOwner,
                  let pair = validCheckout(in: snapshot.legacyValues) {
            values.merge(pair) { current, _ in current }
            adoptedGroups.insert(.vaultCheckout)
        } else if checkoutEntries.contains(where: {
            snapshot.legacyValues[$0.canonicalKey] != nil
        }) {
            skippedKeys.formUnion(checkoutEntries.map(\.canonicalKey))
        }

        for entry in AccountPreferenceCatalog.entries
            where entry.atomicGroup != .vaultCheckout {
            let key = entry.canonicalKey
            if values[key] != nil { continue }

            if establishedLegacyOwner {
                switch entry.adoptionPolicy {
                case .copyExplicit, .copyValid, .copyEstablishedExplicit:
                    if let value = validValue(
                        snapshot.legacyValues[key], for: entry) {
                        values[key] = value
                        adoptedGroups.insert(entry.atomicGroup)
                    } else if snapshot.legacyValues[key] != nil {
                        skippedKeys.insert(key)
                    }
                case .copyExplicitOrMaterializeFalse:
                    values[key] = validValue(
                        snapshot.legacyValues[key], for: entry)
                        ?? .bool(false)
                    adoptedGroups.insert(entry.atomicGroup)
                case .sealedLegacySnapshot:
                    if snapshot.legacySignupPosted == .value(true) {
                        values[key] = .bool(true)
                        adoptedGroups.insert(entry.atomicGroup)
                    }
                case .neverCopy:
                    if snapshot.legacyValues[key] != nil {
                        skippedKeys.insert(key)
                    }
                case .copyCompleteAtomicGroup:
                    break
                }
            } else if snapshot.legacyValues[key] != nil
                        || (
                            entry.adoptionPolicy == .sealedLegacySnapshot
                                && snapshot.legacySignupPosted != .absent
                        ) {
                skippedKeys.insert(key)
            }

            guard values[key] == nil,
                  entry.adoptionPolicy != .sealedLegacySnapshot else {
                continue
            }
            if establishedLegacyOwner,
               key == AccountPreferenceCatalog.brainChoice.canonicalKey {
                // Preserve the pre-picker paired-desktop migration signal:
                // absence means this established owner never chose. Fresh owners
                // still materialize the phone default below.
                continue
            }
            switch entry.freshDefault {
            case .value(let value), .explicit(let value):
                values[key] = value
            case .absent, .coldEmpty:
                break
            }
        }

        return AccountPreferenceAdoptionResult(
            scope: snapshot.scope,
            generation: snapshot.generation,
            adoptedValues: values,
            adoptedGroups: adoptedGroups,
            skippedKeys: skippedKeys)
    }

    private static func validValues(
        _ candidates: [String: AccountPreferenceValue]
    ) -> [String: AccountPreferenceValue] {
        var values: [String: AccountPreferenceValue] = [:]
        for entry in AccountPreferenceCatalog.entries
            where entry.atomicGroup != .vaultCheckout {
            if let value = validValue(
                candidates[entry.canonicalKey], for: entry) {
                values[entry.canonicalKey] = value
            }
        }
        return values
    }

    private static func validCheckout(
        in values: [String: AccountPreferenceValue]
    ) -> [String: AccountPreferenceValue]? {
        let idKey =
            AccountPreferenceCatalog.vaultCheckoutAttemptID.canonicalKey
        let planKey =
            AccountPreferenceCatalog.vaultCheckoutAttemptPlan.canonicalKey
        guard case .string(let id)? = values[idKey],
              !id.isEmpty,
              case .string(let plan)? = values[planKey],
              ["starter", "pro", "power"].contains(plan) else {
            return nil
        }
        return [idKey: .string(id), planKey: .string(plan)]
    }

    static func validValue(
        _ value: AccountPreferenceValue?,
        for entry: AccountPreferenceCatalogEntry
    ) -> AccountPreferenceValue? {
        guard let value else { return nil }
        switch entry.canonicalKey {
        case AccountPreferenceCatalog.onboardingPersona.canonicalKey:
            guard case .string(let raw) = value,
                  ["expert", "individual", "firm"].contains(raw) else {
                return nil
            }
            return value
        case AccountPreferenceCatalog.ambientAgentName.canonicalKey:
            guard case .string(let name) = value,
                  !name.trimmingCharacters(
                    in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            return value
        case AccountPreferenceCatalog.brainChoice.canonicalKey:
            guard case .string(let raw) = value,
                  ["phone", "computer", "cloud"].contains(raw) else {
                return nil
            }
            return value
        case AccountPreferenceCatalog.captureSilenceGapSeconds.canonicalKey:
            guard case .double(let seconds) = value, seconds > 0 else {
                return nil
            }
            return value
        case AccountPreferenceCatalog.captureOMIDesiredState.canonicalKey:
            guard case .string(let raw) = value,
                  ["listening", "paused"].contains(raw) else {
                return nil
            }
            return value
        case AccountPreferenceCatalog.vaultCheckoutAttemptID.canonicalKey,
             AccountPreferenceCatalog.vaultCheckoutAttemptPlan.canonicalKey:
            return nil
        default:
            switch (entry.valueKind, value) {
            case (.bool, .bool),
                 (.string, .string),
                 (.double, .double),
                 (.boolDictionary, .boolDictionary),
                 (.data, .data):
                return value
            default:
                return nil
            }
        }
    }
}

/// Cache-only live facade used by the production owners after Task 6. Reads never
/// touch defaults or identity persistence. Writes carry the initiating generation
/// through the existing preference mutation gate.
public enum AccountPreferences {
    static func currentSnapshot() -> AccountPreferenceSnapshot? {
        CaptureAccountScope.currentAccountPreferenceSnapshot()
    }

    public static func read<Value: Sendable & Equatable>(
        _ key: AccountPreferenceKey<Value>
    ) -> AccountPreferencePresence<Value> {
        CaptureAccountScope.currentAccountPreferenceSnapshot()?
            .presence(for: key) ?? .absent
    }

    public static func value<Value: Sendable & Equatable>(
        _ key: AccountPreferenceKey<Value>,
        default fallback: Value
    ) -> Value {
        guard case .value(let value) = read(key) else { return fallback }
        return value
    }

    @discardableResult
    public static func write<Value>(
        _ value: Value,
        for key: AccountPreferenceKey<Value>,
        generation: UInt64? = nil
    ) -> AccountPreferenceWriteResult {
        guard let entry = AccountPreferenceCatalog.entries.first(where: {
            $0.canonicalKey == key.canonicalKey
        }),
              entry.atomicGroup != .vaultCheckout,
              let encoded = AccountPreferenceValue.encode(value),
              AccountPreferenceAdoptionPlanner.validValue(
                encoded, for: entry) != nil else {
            return .rejected
        }
        return CaptureAccountScope.writeAccountPreference(
            value,
            for: key,
            expectedGeneration: generation)
    }

    @discardableResult
    public static func remove<Value>(
        _ key: AccountPreferenceKey<Value>,
        generation: UInt64? = nil
    ) -> AccountPreferenceWriteResult {
        guard !AccountPreferenceCatalog.entries(
            in: .vaultCheckout
        ).contains(where: { $0.canonicalKey == key.canonicalKey }) else {
            return .rejected
        }
        return CaptureAccountScope.removeAccountPreference(
            key,
            expectedGeneration: generation)
    }

    public static func writeCheckoutAttempt(
        id: String,
        plan: String,
        generation: UInt64? = nil
    ) -> AccountPreferenceWriteResult {
        CaptureAccountScope.writeCheckoutPreferencePair(
            id: id,
            plan: plan,
            expectedGeneration: generation)
    }

    public static func clearCheckoutAttempt(
        generation: UInt64? = nil
    ) -> AccountPreferenceWriteResult {
        CaptureAccountScope.clearCheckoutPreferencePair(
            expectedGeneration: generation)
    }
}

public enum AccountPreferenceWriteResult: Sendable, Equatable {
    case saved
    case stale
    case unresolved
    case rejected
    case failed
}

public struct AccountPreferenceWriteAcknowledgement: Sendable, Equatable {
    public let status: AccountPreferenceWriteResult
    public let scopedKey: String?
    public let persistedReadback: AccountPreferenceValue?

    fileprivate init(
        status: AccountPreferenceWriteResult,
        scopedKey: String? = nil,
        persistedReadback: AccountPreferenceValue? = nil
    ) {
        self.status = status
        self.scopedKey = scopedKey
        self.persistedReadback = persistedReadback
    }
}

enum AccountPreferenceWriteFault: Sendable {
    case droppedPersistence
    case mismatchedReadback
}

final class AccountPreferenceWriteBarrier: @unchecked Sendable {
    private let condition = NSCondition()
    private var shouldPauseNextWrite = false
    private var writeIsPaused = false
    private var transitionIsWaiting = false
    private var writeMayResume = false

    func pauseNextWriteAfterGateAcquisition() {
        condition.lock()
        shouldPauseNextWrite = true
        writeIsPaused = false
        transitionIsWaiting = false
        writeMayResume = false
        condition.unlock()
    }

    func waitUntilWriteIsPausedAfterGateAcquisition(
        timeout: TimeInterval
    ) -> Bool {
        wait(timeout: timeout) { writeIsPaused }
    }

    func waitUntilIdentityTransitionIsWaitingAtGate(
        timeout: TimeInterval
    ) -> Bool {
        wait(timeout: timeout) { transitionIsWaiting }
    }

    func resumePausedWrite() {
        condition.lock()
        writeMayResume = true
        condition.broadcast()
        condition.unlock()
    }

    func pauseWriterIfArmed() {
        condition.lock()
        guard shouldPauseNextWrite else {
            condition.unlock()
            return
        }
        writeIsPaused = true
        condition.broadcast()
        while !writeMayResume {
            condition.wait()
        }
        shouldPauseNextWrite = false
        condition.unlock()
    }

    func identityTransitionWillWaitAtGate() {
        condition.lock()
        if writeIsPaused && !writeMayResume {
            transitionIsWaiting = true
            condition.broadcast()
        }
        condition.unlock()
    }

    private func wait(
        timeout: TimeInterval,
        until predicate: () -> Bool
    ) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        condition.lock()
        defer { condition.unlock() }
        while !predicate() {
            guard condition.wait(until: deadline) else {
                return predicate()
            }
        }
        return true
    }
}

public final class AccountPreferenceWriteStore: @unchecked Sendable {
    private let applicationID: CFString
    private let barrier: AccountPreferenceWriteBarrier?
    private let fault: AccountPreferenceWriteFault?

    public init() {
        applicationID = kCFPreferencesCurrentApplication
        barrier = nil
        fault = nil
    }

    init(
        suiteName: String,
        barrier: AccountPreferenceWriteBarrier
    ) {
        applicationID = suiteName as CFString
        self.barrier = barrier
        fault = nil
    }

    init(
        suiteName: String,
        faultForTests: AccountPreferenceWriteFault
    ) {
        applicationID = suiteName as CFString
        barrier = nil
        fault = faultForTests
    }

    init(suiteName: String) {
        applicationID = suiteName as CFString
        barrier = nil
        fault = nil
    }

    public func write<Value>(
        _ value: Value,
        for key: AccountPreferenceKey<Value>,
        as binding: ScopedPreferenceBinding
    ) -> AccountPreferenceWriteAcknowledgement {
        guard !AccountPreferenceCatalog.entries(
            in: .vaultCheckout
        ).contains(where: { $0.canonicalKey == key.canonicalKey }) else {
            return .init(status: .rejected)
        }
        guard let encoded = AccountPreferenceValue.encode(value) else {
            return .init(status: .unresolved)
        }

        switch CaptureAccountScope.beginPreferenceStoreMutation(
            as: binding,
            barrier: barrier)
        {
        case .unresolved:
            return .init(status: .unresolved)
        case .stale:
            return .init(status: .stale)
        case .rejected:
            return .init(status: .rejected)
        case .acquired(let scoped):
            defer { CaptureAccountScope.endPreferenceStoreMutation() }
            let scopedKey = scoped.key(key.canonicalKey)
            let priorValue = storedValue(forKey: scopedKey)

            switch fault {
            case .droppedPersistence:
                break
            case .mismatchedReadback:
                set(
                    mismatchedDefaultsValue(for: encoded),
                    forKey: scopedKey)
            case nil:
                set(encoded.defaultsValue, forKey: scopedKey)
            }

            let synchronized = synchronize()
            let readback = persistedValue(
                matching: encoded,
                forKey: scopedKey)
            guard fault == nil,
                  synchronized,
                  readback == encoded else {
                restore(priorValue, forKey: scopedKey)
                return .init(status: .failed)
            }
            CaptureAccountScope.cachePreferenceValue(
                encoded,
                forCanonicalKey: key.canonicalKey,
                binding: binding)
            return .init(
                status: .saved,
                scopedKey: scopedKey,
                persistedReadback: readback)
        }
    }

    func readback<Value: Sendable & Equatable>(
        _ key: AccountPreferenceKey<Value>,
        as binding: ScopedPreferenceBinding
    ) -> AccountPreferencePresence<Value> {
        guard let scopedKey = CaptureAccountScope.currentPreferenceStoreKey(
            key.canonicalKey,
            as: binding),
              let value = storedValue(forKey: scopedKey) as? Value else {
            return .absent
        }
        return .value(value)
    }

    private func persistedValue(
        matching expected: AccountPreferenceValue,
        forKey key: String
    ) -> AccountPreferenceValue? {
        guard let value = storedValue(forKey: key) else { return nil }
        switch expected {
        case .bool:
            return (value as? Bool).map(AccountPreferenceValue.bool)
        case .string:
            return (value as? String).map(AccountPreferenceValue.string)
        case .double:
            return (value as? Double).map(AccountPreferenceValue.double)
        case .boolDictionary:
            return (value as? [String: Bool])
                .map(AccountPreferenceValue.boolDictionary)
        case .data:
            return (value as? Data).map(AccountPreferenceValue.data)
        }
    }

    private func mismatchedDefaultsValue(
        for value: AccountPreferenceValue
    ) -> Any {
        switch value {
        case .bool(let value):
            return !value
        case .string(let value):
            return value + ".mismatch"
        case .double(let value):
            return value + 1
        case .boolDictionary(let value):
            var mismatch = value
            mismatch["__foundryx_mismatch__"] = true
            return mismatch
        case .data(let value):
            return value + Data([0])
        }
    }

    private func restore(_ value: Any?, forKey key: String) {
        set(value, forKey: key)
        _ = synchronize()
    }

    private func storedValue(forKey key: String) -> Any? {
        CFPreferencesCopyAppValue(key as CFString, applicationID)
    }

    private func set(_ value: Any?, forKey key: String) {
        CFPreferencesSetAppValue(
            key as CFString,
            value.map { $0 as CFPropertyList },
            applicationID)
    }

    private func synchronize() -> Bool {
        CFPreferencesAppSynchronize(applicationID)
    }
}

public struct AccountPreferenceCompatibilityContext: Sendable, Equatable {
    public let ownerVoiceEnrolled: Bool
    public let hasPairedDesktop: Bool

    public init(
        ownerVoiceEnrolled: Bool = false,
        hasPairedDesktop: Bool = false
    ) {
        self.ownerVoiceEnrolled = ownerVoiceEnrolled
        self.hasPairedDesktop = hasPairedDesktop
    }
}

enum AccountPreferenceActivationStore {
    /// Read one already-activated owner's scoped values without adopting,
    /// materializing, or writing anything. This is the cold/locked restoration
    /// path: invalid values are omitted, and an incomplete checkout pair is
    /// omitted atomically. Callers bind the returned values to the generation
    /// they are about to publish in the process cache.
    static func restoreExisting(
        scope: String,
        defaults: UserDefaults
    ) -> [String: AccountPreferenceValue] {
        let scoped = CaptureAccountScope.ScopedPreferences(scope: scope)
        var values = explicitValues(
            defaults: defaults,
            key: { scoped.key($0) })
        let checkoutEntries = AccountPreferenceCatalog.entries(
            in: .vaultCheckout)
        let idKey =
            AccountPreferenceCatalog.vaultCheckoutAttemptID.canonicalKey
        let planKey =
            AccountPreferenceCatalog.vaultCheckoutAttemptPlan.canonicalKey
        guard case .string(let id)? = values[idKey],
              !id.isEmpty,
              case .string(let plan)? = values[planKey],
              ["starter", "pro", "power"].contains(plan) else {
            for entry in checkoutEntries {
                values.removeValue(forKey: entry.canonicalKey)
            }
            return values
        }
        return values
    }

    static func prepare(
        scope: String,
        generation: UInt64,
        identity: AuthIdentity?,
        establishedLegacyOwner: Bool,
        defaults: UserDefaults
    ) throws -> AccountPreferenceAdoptionResult {
        let scoped = CaptureAccountScope.ScopedPreferences(scope: scope)
        let existing = explicitValues(
            defaults: defaults,
            key: { scoped.key($0) })
        let legacy = establishedLegacyOwner
            ? explicitValues(defaults: defaults, key: { $0 })
            : [:]
        let legacySignup: AccountPreferencePresence<Bool>
        if establishedLegacyOwner, let identity {
            legacySignup = LegacySignupMarkerMigration.snapshotForActivation(
                identity: identity,
                ownerScope: scope,
                generation: generation,
                durableLegacyOwnerScope: scope,
                defaults: defaults)
        } else {
            legacySignup = .absent
        }
        let plan = AccountPreferenceAdoptionPlanner.resolve(
            .init(
                scope: scope,
                generation: generation,
                legacyValues: legacy,
                legacySignupPosted: legacySignup),
            existingValues: existing,
            establishedLegacyOwner: establishedLegacyOwner)
        try persist(
            plan.adoptedValues,
            scoped: scoped,
            defaults: defaults)
        return plan
    }

    private static func explicitValues(
        defaults: UserDefaults,
        key: (String) -> String
    ) -> [String: AccountPreferenceValue] {
        var values: [String: AccountPreferenceValue] = [:]
        for entry in AccountPreferenceCatalog.entries {
            let storageKey = key(entry.canonicalKey)
            guard defaults.object(forKey: storageKey) != nil,
                  let value = storedValue(
                    defaults: defaults,
                    key: storageKey,
                    kind: entry.valueKind) else {
                continue
            }
            if entry.atomicGroup == .vaultCheckout {
                values[entry.canonicalKey] = value
            } else if let valid =
                        AccountPreferenceAdoptionPlanner.validValue(
                            value,
                            for: entry) {
                values[entry.canonicalKey] = valid
            }
        }
        return values
    }

    private static func persist(
        _ values: [String: AccountPreferenceValue],
        scoped: CaptureAccountScope.ScopedPreferences,
        defaults: UserDefaults
    ) throws {
        var prior: [String: Any] = [:]
        var absentBefore: Set<String> = []
        for entry in AccountPreferenceCatalog.entries {
            let storageKey = scoped.key(entry.canonicalKey)
            if let value = defaults.object(forKey: storageKey) {
                prior[entry.canonicalKey] = value
            } else {
                absentBefore.insert(entry.canonicalKey)
            }
            if let value = values[entry.canonicalKey] {
                defaults.set(value.defaultsValue, forKey: storageKey)
            } else {
                defaults.removeObject(forKey: storageKey)
            }
        }

        guard defaults.synchronize(),
              explicitValues(
                defaults: defaults,
                key: { scoped.key($0) }) == values,
              AccountPreferenceCatalog.entries.allSatisfy({
                values[$0.canonicalKey] != nil
                    || defaults.object(
                        forKey: scoped.key($0.canonicalKey)) == nil
              }) else {
            for entry in AccountPreferenceCatalog.entries {
                let storageKey = scoped.key(entry.canonicalKey)
                if let value = prior[entry.canonicalKey] {
                    defaults.set(value, forKey: storageKey)
                } else if absentBefore.contains(entry.canonicalKey) {
                    defaults.removeObject(forKey: storageKey)
                }
            }
            _ = defaults.synchronize()
            throw CaptureAccountScopeError.activationState(
                "account preferences could not be atomically persisted and read back")
        }
    }

    private static func storedValue(
        defaults: UserDefaults,
        key: String,
        kind: AccountPreferenceValueKind
    ) -> AccountPreferenceValue? {
        switch kind {
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
}

/// The temporary inactive adapter for the shipped unscoped preference behavior.
/// No production owner selects the scoped snapshot branch in Task 1.
public final class AccountPreferenceCompatibilityStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let fault: AccountPreferenceWriteFault?

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        fault = nil
    }

    init(
        defaults: UserDefaults,
        faultForTests: AccountPreferenceWriteFault
    ) {
        self.defaults = defaults
        fault = faultForTests
    }

    public func read<Value: Sendable & Equatable>(
        _ key: AccountPreferenceKey<Value>,
        context: AccountPreferenceCompatibilityContext = .init()
    ) -> AccountPreferencePresence<Value> {
        let value = legacyValue(for: key.canonicalKey, context: context)
        guard let decoded = value?.decoded(as: Value.self) else {
            return .absent
        }
        return .value(decoded)
    }

    public func write<Value>(
        _ value: Value,
        for key: AccountPreferenceKey<Value>
    ) -> AccountPreferenceWriteResult {
        guard key.canonicalKey
                != AccountPreferenceCatalog.signupPosted.canonicalKey else {
            return .rejected
        }
        guard let encoded = AccountPreferenceValue.encode(value) else {
            return .unresolved
        }
        return persist(
            encoded.defaultsValue,
            forKey: key.canonicalKey,
            exactReadback: encoded)
    }

    public func remove<Value>(
        _ key: AccountPreferenceKey<Value>
    ) -> AccountPreferenceWriteResult {
        let canonicalKey = key.canonicalKey
        guard canonicalKey
                != AccountPreferenceCatalog.signupPosted.canonicalKey,
              canonicalKey
                != AccountPreferenceCatalog.vaultCheckoutAttemptID.canonicalKey,
              canonicalKey
                != AccountPreferenceCatalog.vaultCheckoutAttemptPlan.canonicalKey
        else {
            return .rejected
        }
        let priorValue = defaults.object(forKey: canonicalKey)
        guard fault == nil else { return .failed }
        defaults.removeObject(forKey: canonicalKey)
        guard defaults.synchronize(),
              defaults.object(forKey: canonicalKey) == nil else {
            restore(priorValue, forKey: canonicalKey)
            return .failed
        }
        return .saved
    }

    public func clearLegacyCheckoutAttempt() -> AccountPreferenceWriteResult {
        let idKey = AccountPreferenceCatalog.vaultCheckoutAttemptID.canonicalKey
        let planKey =
            AccountPreferenceCatalog.vaultCheckoutAttemptPlan.canonicalKey
        let priorID = defaults.object(forKey: idKey)
        let priorPlan = defaults.object(forKey: planKey)
        guard fault == nil else { return .failed }
        defaults.removeObject(forKey: idKey)
        defaults.removeObject(forKey: planKey)
        guard defaults.synchronize(),
              defaults.object(forKey: idKey) == nil,
              defaults.object(forKey: planKey) == nil else {
            restore(priorID, forKey: idKey, synchronize: false)
            restore(priorPlan, forKey: planKey)
            return .failed
        }
        return .saved
    }

    public func writeLegacyCheckoutAttempt(
        id: String,
        plan: String
    ) -> AccountPreferenceWriteResult {
        let idKey = AccountPreferenceCatalog.vaultCheckoutAttemptID.canonicalKey
        let planKey =
            AccountPreferenceCatalog.vaultCheckoutAttemptPlan.canonicalKey
        let priorID = defaults.object(forKey: idKey)
        let priorPlan = defaults.object(forKey: planKey)
        guard fault == nil else { return .failed }
        defaults.set(id, forKey: idKey)
        defaults.set(plan, forKey: planKey)
        guard defaults.synchronize(),
              defaults.string(forKey: idKey) == id,
              defaults.string(forKey: planKey) == plan else {
            restore(priorID, forKey: idKey, synchronize: false)
            restore(priorPlan, forKey: planKey)
            return .failed
        }
        return .saved
    }

    public func hasLegacyStringValue(
        for key: AccountPreferenceKey<String>
    ) -> Bool {
        defaults.string(forKey: key.canonicalKey) != nil
    }

    private func legacyValue(
        for key: String,
        context: AccountPreferenceCompatibilityContext
    ) -> AccountPreferenceValue? {
        switch key {
        case AccountPreferenceCatalog.onboardingCompleted.canonicalKey,
             AccountPreferenceCatalog.welcomeSeen.canonicalKey,
             AccountPreferenceCatalog.welcomeLetStraightIn.canonicalKey,
             AccountPreferenceCatalog.ambientEnabled.canonicalKey,
             AccountPreferenceCatalog.ambientOthersInline.canonicalKey,
             AccountPreferenceCatalog.waitlistJoined.canonicalKey:
            return .bool(defaults.bool(forKey: key))

        case AccountPreferenceCatalog.onboardingPersona.canonicalKey:
            guard let raw = defaults.string(forKey: key),
                  ["expert", "individual", "firm"].contains(raw) else {
                return .string("individual")
            }
            return .string(raw)

        case AccountPreferenceCatalog.ambientAgentName.canonicalKey:
            guard defaults.object(forKey: key) != nil,
                  let value = defaults.string(forKey: key) else {
                return nil
            }
            return .string(value)

        case AccountPreferenceCatalog.ambientGrading.canonicalKey:
            if defaults.object(forKey: key) != nil {
                return .bool(defaults.bool(forKey: key))
            }
            return .bool(context.ownerVoiceEnrolled)

        case AccountPreferenceCatalog.vaultCheckoutAttemptID.canonicalKey:
            guard let attempt = defaults.string(forKey: key), !attempt.isEmpty else {
                return nil
            }
            return .string(attempt)

        case AccountPreferenceCatalog.vaultCheckoutAttemptPlan.canonicalKey:
            let idKey = AccountPreferenceCatalog.vaultCheckoutAttemptID.canonicalKey
            guard let attempt = defaults.string(forKey: idKey), !attempt.isEmpty else {
                return nil
            }
            guard let raw = defaults.string(forKey: key),
                  ["starter", "pro", "power"].contains(raw) else {
                return .string("pro")
            }
            return .string(raw)

        case AccountPreferenceCatalog.brainChoice.canonicalKey:
            if let raw = defaults.string(forKey: key),
               ["phone", "computer", "cloud"].contains(raw) {
                return .string(raw)
            }
            return .string(context.hasPairedDesktop ? "computer" : "phone")

        case AccountPreferenceCatalog.captureSilenceGapSeconds.canonicalKey:
            let value = defaults.double(forKey: key)
            return .double(value > 0 ? value : 120)

        case AccountPreferenceCatalog.captureOMIDesiredState.canonicalKey:
            guard let raw = defaults.string(forKey: key),
                  ["listening", "paused"].contains(raw) else {
                return .string("listening")
            }
            return .string(raw)

        case AccountPreferenceCatalog.captureSourceEnabledOverrides.canonicalKey:
            let value = defaults.dictionary(forKey: key) as? [String: Bool] ?? [:]
            return .boolDictionary(value)

        case AccountPreferenceCatalog.modelsCache.canonicalKey:
            return defaults.data(forKey: key).map(AccountPreferenceValue.data)

        case AccountPreferenceCatalog.signupPosted.canonicalKey:
            return nil

        default:
            return nil
        }
    }

    private func persist(
        _ value: Any,
        forKey key: String,
        exactReadback: AccountPreferenceValue
    ) -> AccountPreferenceWriteResult {
        let priorValue = defaults.object(forKey: key)
        switch fault {
        case .droppedPersistence:
            break
        case .mismatchedReadback:
            defaults.set(false, forKey: key)
        case nil:
            defaults.set(value, forKey: key)
        }
        let synchronized = defaults.synchronize()
        let readback: AccountPreferenceValue?
        switch exactReadback {
        case .bool:
            readback = defaults.object(forKey: key) == nil
                ? nil
                : .bool(defaults.bool(forKey: key))
        case .string:
            readback = defaults.string(forKey: key)
                .map(AccountPreferenceValue.string)
        case .double:
            readback = defaults.object(forKey: key) == nil
                ? nil
                : .double(defaults.double(forKey: key))
        case .boolDictionary:
            readback = (defaults.dictionary(forKey: key) as? [String: Bool])
                .map(AccountPreferenceValue.boolDictionary)
        case .data:
            readback = defaults.data(forKey: key)
                .map(AccountPreferenceValue.data)
        }
        guard fault == nil,
              synchronized,
              readback == exactReadback else {
            restore(priorValue, forKey: key)
            return .failed
        }
        return .saved
    }

    private func restore(
        _ value: Any?,
        forKey key: String,
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
}

/// The legacy dynamic signup marker is quarantined behind verified capability
/// values. Normal Task-2 signup still uses the compatibility helper above; this
/// migration remains dormant until account-preference activation.
struct LegacySignupMarkerMigration {
    struct VerifiedIdentity: Sendable, Equatable {
        fileprivate let historicalCanonicalIdentity: String

        private init(historicalCanonicalIdentity: String) {
            self.historicalCanonicalIdentity =
                historicalCanonicalIdentity
        }

        fileprivate static func verified(
            _ historicalCanonicalIdentity: String
        ) -> Self {
            Self(historicalCanonicalIdentity: historicalCanonicalIdentity)
        }
    }

    struct DurableLegacyOwnerProof: Sendable, Equatable {
        fileprivate let scope: String
        fileprivate let generation: UInt64
        fileprivate let historicalCanonicalIdentity: String

        private init(
            scope: String,
            generation: UInt64,
            historicalCanonicalIdentity: String
        ) {
            self.scope = scope
            self.generation = generation
            self.historicalCanonicalIdentity =
                historicalCanonicalIdentity
        }

        fileprivate static func proven(
            scope: String,
            generation: UInt64,
            historicalCanonicalIdentity: String
        ) -> Self {
            Self(
                scope: scope,
                generation: generation,
                historicalCanonicalIdentity:
                    historicalCanonicalIdentity)
        }
    }

    struct DeletionTombstoneProof: Sendable, Equatable {
        fileprivate let scope: String
        fileprivate let generation: UInt64

        private init(scope: String, generation: UInt64) {
            self.scope = scope
            self.generation = generation
        }

        fileprivate static func proven(
            scope: String, generation: UInt64
        ) -> Self {
            Self(scope: scope, generation: generation)
        }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    static func retireForDeletion(
        identity: AuthIdentity,
        ownerScope: String,
        generation: UInt64,
        durableLegacyOwnerScope: String?,
        defaults: UserDefaults
    ) -> AccountPreferenceWriteResult {
        guard durableLegacyOwnerScope == ownerScope,
              let historicalIdentity = historicalCanonicalIdentity(identity)
        else {
            return .rejected
        }
        let identity = VerifiedIdentity.verified(historicalIdentity)
        let ownerProof = DurableLegacyOwnerProof.proven(
            scope: ownerScope,
            generation: generation,
            historicalCanonicalIdentity: historicalIdentity)
        let tombstone = DeletionTombstoneProof.proven(
            scope: ownerScope, generation: generation)
        return Self(defaults: defaults).retire(
            identity: identity,
            ownerProof: ownerProof,
            deletionTombstone: tombstone)
    }

    static func isAbsentForDeletion(
        identity: AuthIdentity,
        ownerScope: String,
        generation: UInt64,
        durableLegacyOwnerScope: String?,
        defaults: UserDefaults
    ) -> Bool {
        guard durableLegacyOwnerScope == ownerScope,
              let historicalIdentity = historicalCanonicalIdentity(identity)
        else {
            return false
        }
        let verified = VerifiedIdentity.verified(historicalIdentity)
        let proof = DurableLegacyOwnerProof.proven(
            scope: ownerScope,
            generation: generation,
            historicalCanonicalIdentity: historicalIdentity)
        return Self(defaults: defaults).snapshot(
            identity: verified, ownerProof: proof) == .absent
    }

    static func snapshotForActivation(
        identity: AuthIdentity,
        ownerScope: String,
        generation: UInt64,
        durableLegacyOwnerScope: String?,
        defaults: UserDefaults
    ) -> AccountPreferencePresence<Bool> {
        guard durableLegacyOwnerScope == ownerScope,
              let historicalIdentity = historicalCanonicalIdentity(identity)
        else {
            return .absent
        }
        let verified = VerifiedIdentity.verified(historicalIdentity)
        let proof = DurableLegacyOwnerProof.proven(
            scope: ownerScope,
            generation: generation,
            historicalCanonicalIdentity: historicalIdentity)
        return Self(defaults: defaults).snapshot(
            identity: verified,
            ownerProof: proof)
    }

    func snapshot(
        identity: VerifiedIdentity,
        ownerProof: DurableLegacyOwnerProof
    ) -> AccountPreferencePresence<Bool> {
        guard identity.historicalCanonicalIdentity
                == ownerProof.historicalCanonicalIdentity,
              defaults.object(forKey: historicalKey(identity)) != nil else {
            return .absent
        }
        return .value(defaults.bool(forKey: historicalKey(identity)))
    }

    func retire(
        identity: VerifiedIdentity,
        ownerProof: DurableLegacyOwnerProof,
        deletionTombstone: DeletionTombstoneProof
    ) -> AccountPreferenceWriteResult {
        guard identity.historicalCanonicalIdentity
                == ownerProof.historicalCanonicalIdentity,
              ownerProof.scope == deletionTombstone.scope,
              ownerProof.generation == deletionTombstone.generation else {
            return .rejected
        }
        let key = historicalKey(identity)
        defaults.removeObject(forKey: key)
        guard defaults.synchronize(),
              defaults.object(forKey: key) == nil else {
            return .failed
        }
        return .saved
    }

    private func historicalKey(_ identity: VerifiedIdentity) -> String {
        "foundryx.account.signup-posted.\(identity.historicalCanonicalIdentity)"
    }

    private static func historicalCanonicalIdentity(
        _ identity: AuthIdentity
    ) -> String? {
        identity.email?.lowercased()
    }
}

public enum WaitlistPrefs {
    public static func joined() -> Bool {
        AccountPreferences.value(
            AccountPreferenceCatalog.waitlistJoined,
            default: false)
    }

    public static func joined(
        compatibility: AccountPreferenceCompatibilityStore
    ) -> Bool {
        compatibility.read(AccountPreferenceCatalog.waitlistJoined)
            == .value(true)
    }

    @discardableResult
    public static func markJoined(
        generation: UInt64
    ) -> AccountPreferenceWriteResult {
        AccountPreferences.write(
            true,
            for: AccountPreferenceCatalog.waitlistJoined,
            generation: generation)
    }

    @discardableResult
    public static func markJoined(
        compatibility: AccountPreferenceCompatibilityStore,
        generation: UInt64
    ) -> AccountPreferenceWriteResult {
        _ = generation
        return compatibility.write(
            true,
            for: AccountPreferenceCatalog.waitlistJoined)
    }

    @discardableResult
    public static func completePost(
        succeeded: Bool,
        generation: UInt64
    ) -> AccountPreferenceWriteResult {
        guard succeeded else { return .rejected }
        return markJoined(generation: generation)
    }

    @discardableResult
    public static func completePost(
        succeeded: Bool,
        compatibility: AccountPreferenceCompatibilityStore,
        generation: UInt64
    ) -> AccountPreferenceWriteResult {
        guard succeeded else { return .rejected }
        return markJoined(
            compatibility: compatibility,
            generation: generation)
    }
}
