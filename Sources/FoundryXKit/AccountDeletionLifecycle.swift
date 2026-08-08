import Foundation
import Darwin

enum AccountDeletionCleanupGroup: String, Codable, CaseIterable, Sendable {
    case trackBPreferences
    case pairingPreferences
    case pairingSecrets
    case localRoot
    case legacyInputs
    case accountSurfaces
}

enum AccountDeletionPhase: String, Codable, Sendable {
    case cleanupPending
    case completed
}

enum AccountDeletionExposureBarrier: String, Codable, Sendable {
    case pending
    case closed
}

enum AccountDeletionLegacyDisposition: String, Codable, Sendable {
    case pending
    case retired
    case notOwned
}

struct AccountDeletionLifecycleRecord: Codable, Equatable, Sendable {
    var version: Int
    var ownerScope: String
    var deletionEpoch: UInt64
    var phase: AccountDeletionPhase
    var exposureBarrier: AccountDeletionExposureBarrier
    var blockedGeneration: UInt64?
    var completedGroups: [AccountDeletionCleanupGroup]
    var legacyDisposition: AccountDeletionLegacyDisposition

    private enum CodingKeys: String, CodingKey {
        case version
        case ownerScope
        case deletionEpoch
        case phase
        case exposureBarrier
        case blockedGeneration
        case completedGroups
        case legacyDisposition
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(ownerScope, forKey: .ownerScope)
        try container.encode(deletionEpoch, forKey: .deletionEpoch)
        try container.encode(phase, forKey: .phase)
        try container.encode(exposureBarrier, forKey: .exposureBarrier)
        if let blockedGeneration {
            try container.encode(
                blockedGeneration, forKey: .blockedGeneration)
        } else {
            try container.encodeNil(forKey: .blockedGeneration)
        }
        try container.encode(completedGroups, forKey: .completedGroups)
        try container.encode(
            legacyDisposition, forKey: .legacyDisposition)
    }
}

enum AccountDeletionLifecycleReadFailure: Error, Equatable, Sendable {
    case unreadable
    case protectedDataUnavailable
    case failed
}

enum AccountDeletionLifecycleBlockedReason: Equatable, Sendable {
    case corrupt
    case unsupportedVersion(Int)
    case unreadable
    case protectedDataUnavailable
    case failed
}

enum AccountDeletionLifecycleReadResult: Equatable, Sendable {
    case missing
    case record(AccountDeletionLifecycleRecord)
    case blocked(AccountDeletionLifecycleBlockedReason)

    var record: AccountDeletionLifecycleRecord? {
        if case .record(let record) = self { return record }
        return nil
    }
}

enum DeletionDurabilityOperation: Equatable, Sendable {
    case readCurrent
    case createUniqueTempSameDirectory0600
    case writeAll
    case fsyncFile
    case closeFile
    case renamePOSIX
    case fsyncParent
    case closeParent
    case typedReadback

    static let allCases: [Self] = [
        .readCurrent,
        .createUniqueTempSameDirectory0600,
        .writeAll,
        .fsyncFile,
        .closeFile,
        .renamePOSIX,
        .fsyncParent,
        .closeParent,
        .typedReadback,
    ]
}

enum DeletionWriteResult: Equatable, Sendable {
    case interrupted
    case written(Int)
}

protocol AccountDeletionLifecycleFileIO: Sendable {
    func read(_ url: URL) throws -> Data?
    func createUniqueTemporaryFile(in directory: URL, mode: Int) throws -> URL
    func writeSome(
        _ data: Data,
        from offset: Int,
        to temporaryFile: URL
    ) throws -> DeletionWriteResult
    func fsyncFile(at url: URL) throws
    func closeFile(at url: URL) throws
    func renamePOSIX(_ source: URL, to destination: URL) throws
    func fsyncParent(of url: URL) throws
    func closeParent(of url: URL) throws
}

enum DeletionFaultStage: String, CaseIterable, Sendable {
    case pendingSync
    case pendingReadback
    case resolutionGeneration
    case signedInMirror
    case widgetWithdrawal
    case liveExposureClosure
    case staleWorkCancellation
    case barrierVerification
    case barrierSync
    case barrierReadback
    case trackBPreferences
    case pairingPreferences
    case pairingSecrets
    case localRoot
    case legacyInputs
    case accountSurfaces
    case completedSync
    case completedReadback

    static let requiredV1: [Self] = [
        .pendingSync,
        .pendingReadback,
        .resolutionGeneration,
        .signedInMirror,
        .widgetWithdrawal,
        .liveExposureClosure,
        .staleWorkCancellation,
        .barrierVerification,
        .barrierSync,
        .barrierReadback,
        .trackBPreferences,
        .pairingPreferences,
        .pairingSecrets,
        .localRoot,
        .legacyInputs,
        .accountSurfaces,
        .completedSync,
        .completedReadback,
    ]
}

enum DeletionFaultBoundary: String, CaseIterable, Sendable {
    case before
    case after
}

struct DeletionFaultPoint: Hashable, Sendable {
    let boundary: DeletionFaultBoundary
    let stage: DeletionFaultStage

    init(_ boundary: DeletionFaultBoundary, _ stage: DeletionFaultStage) {
        self.boundary = boundary
        self.stage = stage
    }

    static let requiredV1 = DeletionFaultStage.requiredV1.flatMap { stage in
        [
            DeletionFaultPoint(.before, stage),
            DeletionFaultPoint(.after, stage),
        ]
    }
}

struct DeletionFaultInjector: Sendable {
    private let hook: @Sendable (DeletionFaultPoint) throws -> Void

    init(_ hook: @escaping @Sendable (DeletionFaultPoint) throws -> Void) {
        self.hook = hook
    }

    func callAsFunction(_ point: DeletionFaultPoint) throws {
        try hook(point)
    }

    static let none = DeletionFaultInjector { _ in }
}

enum AccountDeletionLifecycleError: Error, Equatable, Sendable {
    case invalidRecord
    case durability
    case staleEpoch(expected: UInt64, actual: UInt64)
    case typedReadbackMismatch
    case injectedCrash(DeletionFaultPoint)
    case staleBinding
    case preferenceMutationInProgress
    case exposureBarrierFailed
    case cleanupVerificationFailed(AccountDeletionCleanupGroup)
    case cleanupStepFailed(String, String)
    case blocked(AccountDeletionLifecycleBlockedReason)
}

enum AccountDeletionLifecycleCodec {
    static func encode(_ record: AccountDeletionLifecycleRecord) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(record)
    }

    static func decode(_ data: Data) throws -> AccountDeletionLifecycleRecord {
        guard let object = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any],
              let version = object["version"] as? NSNumber else {
            throw AccountDeletionLifecycleError.invalidRecord
        }
        let sealedKeys: Set<String> = [
            "version", "ownerScope", "deletionEpoch", "phase",
            "exposureBarrier", "blockedGeneration", "completedGroups",
            "legacyDisposition",
        ]
        guard Set(object.keys) == sealedKeys else {
            throw AccountDeletionLifecycleError.invalidRecord
        }
        guard version.intValue == 1 else {
            throw AccountDeletionLifecycleError.blocked(
                .unsupportedVersion(version.intValue))
        }
        let record: AccountDeletionLifecycleRecord
        do {
            record = try JSONDecoder().decode(
                AccountDeletionLifecycleRecord.self, from: data)
        } catch {
            throw AccountDeletionLifecycleError.invalidRecord
        }
        guard isValid(record) else {
            throw AccountDeletionLifecycleError.invalidRecord
        }
        return record
    }

    static func isValid(_ record: AccountDeletionLifecycleRecord) -> Bool {
        guard record.version == 1,
              AccountDeletionLifecycleStore.isValidOwnerScope(
                record.ownerScope),
              record.deletionEpoch > 0,
              Array(AccountDeletionCleanupGroup.allCases.prefix(
                record.completedGroups.count)) == record.completedGroups
        else { return false }
        if record.exposureBarrier == .pending {
            guard record.blockedGeneration == nil,
                  record.completedGroups.isEmpty,
                  record.legacyDisposition == .pending
            else { return false }
        } else {
            guard record.blockedGeneration != nil else { return false }
        }
        if record.phase == .completed {
            guard record.exposureBarrier == .closed,
                  record.completedGroups
                    == AccountDeletionCleanupGroup.allCases,
                  record.legacyDisposition != .pending
            else { return false }
        }
        if record.completedGroups.contains(.legacyInputs),
           record.legacyDisposition == .pending {
            return false
        }
        if !record.completedGroups.contains(.legacyInputs),
           record.legacyDisposition != .pending {
            return false
        }
        return true
    }
}

private final class SystemDeletionFileIO:
    AccountDeletionLifecycleFileIO, @unchecked Sendable
{
    private let lock = NSLock()
    private var fileDescriptors: [String: Int32] = [:]
    private var parentDescriptors: [String: Int32] = [:]

    func read(_ url: URL) throws -> Data? {
        let descriptor = Darwin.open(url.path, O_RDONLY)
        if descriptor < 0 {
            switch errno {
            case ENOENT: return nil
            case EACCES, EPERM:
                throw AccountDeletionLifecycleReadFailure.unreadable
            case EAGAIN:
                throw AccountDeletionLifecycleReadFailure
                    .protectedDataUnavailable
            default:
                throw AccountDeletionLifecycleReadFailure.failed
            }
        }
        defer { _ = Darwin.close(descriptor) }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count == 0 { return result }
            if count < 0 {
                if errno == EINTR { continue }
                if errno == EACCES || errno == EPERM {
                    throw AccountDeletionLifecycleReadFailure.unreadable
                }
                throw AccountDeletionLifecycleReadFailure.failed
            }
            result.append(buffer, count: count)
        }
    }

    func createUniqueTemporaryFile(
        in directory: URL,
        mode: Int
    ) throws -> URL {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        for _ in 0..<64 {
            let url = directory.appendingPathComponent(
                ".deletion-\(UUID().uuidString).tmp")
            let descriptor = Darwin.open(
                url.path, O_WRONLY | O_CREAT | O_EXCL, mode_t(mode))
            if descriptor >= 0 {
                lock.withLock { fileDescriptors[url.path] = descriptor }
                return url
            }
            if errno != EEXIST {
                throw AccountDeletionLifecycleError.durability
            }
        }
        throw AccountDeletionLifecycleError.durability
    }

    func writeSome(
        _ data: Data,
        from offset: Int,
        to temporaryFile: URL
    ) throws -> DeletionWriteResult {
        guard let descriptor = lock.withLock({
            fileDescriptors[temporaryFile.path]
        }) else {
            throw AccountDeletionLifecycleError.durability
        }
        return try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return .written(0) }
            let count = Darwin.write(
                descriptor,
                base.advanced(by: offset),
                data.count - offset)
            if count < 0 {
                if errno == EINTR { return .interrupted }
                throw AccountDeletionLifecycleError.durability
            }
            return .written(count)
        }
    }

    func fsyncFile(at url: URL) throws {
        guard let descriptor = lock.withLock({
            fileDescriptors[url.path]
        }), Darwin.fsync(descriptor) == 0 else {
            throw AccountDeletionLifecycleError.durability
        }
    }

    func closeFile(at url: URL) throws {
        guard let descriptor = lock.withLock({
            fileDescriptors.removeValue(forKey: url.path)
        }), Darwin.close(descriptor) == 0 else {
            throw AccountDeletionLifecycleError.durability
        }
    }

    func renamePOSIX(_ source: URL, to destination: URL) throws {
        guard Darwin.rename(source.path, destination.path) == 0 else {
            throw AccountDeletionLifecycleError.durability
        }
    }

    func fsyncParent(of url: URL) throws {
        let directory = url.deletingLastPathComponent()
        let descriptor = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY)
        guard descriptor >= 0, Darwin.fsync(descriptor) == 0 else {
            if descriptor >= 0 { _ = Darwin.close(descriptor) }
            throw AccountDeletionLifecycleError.durability
        }
        lock.withLock {
            parentDescriptors[directory.path] = descriptor
        }
    }

    func closeParent(of url: URL) throws {
        let path = url.deletingLastPathComponent().path
        guard let descriptor = lock.withLock({
            parentDescriptors.removeValue(forKey: path)
        }), Darwin.close(descriptor) == 0 else {
            throw AccountDeletionLifecycleError.durability
        }
    }
}

final class AccountDeletionLifecycleStore: @unchecked Sendable {
    final class OwnerAdmissionLease: @unchecked Sendable {
        private let releaseHook: () -> Void
        private var released = false
        init(release: @escaping () -> Void) { releaseHook = release }
        func release() {
            guard !released else { return }
            released = true
            releaseHook()
        }
        deinit { release() }
    }
    static let metadataDirectoryName = ".account-deletions-v1"
    private static let serializationLock = NSRecursiveLock()
    private static let testHookLock = NSLock()
    nonisolated(unsafe) private static var beforeOwnerLockAttemptHook:
        (@Sendable (String) -> Void)?

    static func setBeforeOwnerLockAttemptHookForTests(
        _ hook: (@Sendable (String) -> Void)?
    ) {
        testHookLock.withLock { beforeOwnerLockAttemptHook = hook }
    }
    private static let failureLock = NSLock()
    nonisolated(unsafe) private static var readFailures:
        [String: AccountDeletionLifecycleReadFailure] = [:]

    private let container: URL
    private let fileIO: any AccountDeletionLifecycleFileIO

    init(
        container: URL,
        fileIO: any AccountDeletionLifecycleFileIO = SystemDeletionFileIO()
    ) {
        self.container = container
        self.fileIO = fileIO
    }

    static func setReadFailureForTests(
        _ failure: AccountDeletionLifecycleReadFailure?,
        ownerScope: String
    ) {
        failureLock.withLock {
            readFailures[ownerScope] = failure
        }
    }

    static func isValidOwnerScope(_ scope: String) -> Bool {
        guard scope.hasPrefix("acct-"), scope != "acct-none" else {
            return false
        }
        let digest = scope.dropFirst(5)
        return !digest.isEmpty && digest.count <= 16
            && digest.allSatisfy(\.isHexDigit)
    }

    func recordURL(ownerScope: String) throws -> URL {
        guard Self.isValidOwnerScope(ownerScope) else {
            throw AccountDeletionLifecycleError.invalidRecord
        }
        return container.appendingPathComponent(
            Self.metadataDirectoryName, isDirectory: true
        ).appendingPathComponent("\(ownerScope).json")
    }

    func read(ownerScope: String) -> AccountDeletionLifecycleReadResult {
        Self.serializationLock.withLock {
            readUnlocked(ownerScope: ownerScope)
        }
    }

    func readWithOwnerAdmission(
        ownerScope: String
    ) -> AccountDeletionLifecycleReadResult {
        Self.serializationLock.withLock {
            (try? withAdvisoryLock(ownerScope: ownerScope) {
                readUnlocked(ownerScope: ownerScope)
            }) ?? .blocked(.failed)
        }
    }

    func withOwnerAdmission<Result>(
        ownerScope: String,
        _ body: () throws -> Result
    ) throws -> Result? {
        return try Self.serializationLock.withLock {
            try withAdvisoryLock(ownerScope: ownerScope) {
                switch readUnlocked(ownerScope: ownerScope) {
                case .missing:
                    return try body()
                case .record(let record) where record.phase == .completed:
                    return try body()
                case .record, .blocked:
                    return nil
                }
            }
        }
    }

    func acquireOwnerAdmission(
        ownerScope: String
    ) -> OwnerAdmissionLease? {
        guard Self.serializationLock.try() else { return nil }
        guard let record = try? recordURL(ownerScope: ownerScope) else {
            Self.serializationLock.unlock()
            return nil
        }
        let directory = record.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        let lockURL = directory.appendingPathComponent("\(ownerScope).lock")
        let descriptor = Darwin.open(
            lockURL.path, O_RDWR | O_CREAT, mode_t(0o600))
        guard descriptor >= 0 else {
            Self.serializationLock.unlock()
            return nil
        }
        while Darwin.lockf(descriptor, F_TLOCK, 0) != 0 {
            if errno == EINTR { continue }
            _ = Darwin.close(descriptor)
            Self.serializationLock.unlock()
            return nil
        }
        let admitted: Bool
        switch readUnlocked(ownerScope: ownerScope) {
        case .missing:
            admitted = true
        case .record(let record):
            admitted = record.phase == .completed
        case .blocked:
            admitted = false
        }
        if admitted {
            return OwnerAdmissionLease {
                _ = Darwin.lockf(descriptor, F_ULOCK, 0)
                _ = Darwin.close(descriptor)
                Self.serializationLock.unlock()
            }
        } else {
            _ = Darwin.lockf(descriptor, F_ULOCK, 0)
            _ = Darwin.close(descriptor)
            Self.serializationLock.unlock()
            return nil
        }
    }

    func createPending(
        ownerScope: String
    ) throws -> AccountDeletionLifecycleRecord {
        let attemptHook = Self.testHookLock.withLock {
            Self.beforeOwnerLockAttemptHook
        }
        attemptHook?(ownerScope)
        let pending = try Self.serializationLock.withLock {
            try withAdvisoryLock(ownerScope: ownerScope) {
            let previous = readUnlocked(ownerScope: ownerScope)
            let epoch: UInt64
            switch previous {
            case .missing:
                epoch = 1
            case .record(let record):
                if record.phase == .cleanupPending {
                    return record
                }
                guard record.deletionEpoch < UInt64.max else {
                    throw AccountDeletionLifecycleError.durability
                }
                epoch = record.deletionEpoch + 1
            case .blocked(let reason):
                throw AccountDeletionLifecycleError.blocked(reason)
            }
            let record = AccountDeletionLifecycleRecord(
                version: 1,
                ownerScope: ownerScope,
                deletionEpoch: epoch,
                phase: .cleanupPending,
                exposureBarrier: .pending,
                blockedGeneration: nil,
                completedGroups: [],
                legacyDisposition: .pending)
            return try persist(record)
            }
        }
        CaptureAccountScope.cacheDurableDeletionTransition(
            pending, container: container)
        return pending
    }

    func compareAndSwap(
        ownerScope: String,
        expectedEpoch: UInt64,
        _ mutation: (inout AccountDeletionLifecycleRecord) -> Void
    ) throws -> AccountDeletionLifecycleRecord {
        let replacement = try Self.serializationLock.withLock {
            try withAdvisoryLock(ownerScope: ownerScope) {
            let current: AccountDeletionLifecycleRecord
            switch readUnlocked(ownerScope: ownerScope) {
            case .record(let record):
                current = record
            case .missing:
                throw AccountDeletionLifecycleError.staleEpoch(
                    expected: expectedEpoch, actual: 0)
            case .blocked(let reason):
                throw AccountDeletionLifecycleError.blocked(reason)
            }
            guard current.deletionEpoch == expectedEpoch else {
                throw AccountDeletionLifecycleError.staleEpoch(
                    expected: expectedEpoch,
                    actual: current.deletionEpoch)
            }
            var replacement = current
            mutation(&replacement)
            guard replacement.ownerScope == ownerScope,
                  replacement.deletionEpoch == expectedEpoch,
                  AccountDeletionLifecycleCodec.isValid(replacement),
                  Self.isLegalTransition(from: current, to: replacement) else {
                throw AccountDeletionLifecycleError.typedReadbackMismatch
            }
            return try persist(replacement)
            }
        }
        CaptureAccountScope.cacheDurableDeletionTransition(
            replacement, container: container)
        return replacement
    }

    private static func isLegalTransition(
        from current: AccountDeletionLifecycleRecord,
        to replacement: AccountDeletionLifecycleRecord
    ) -> Bool {
        if current.phase == .completed { return replacement == current }
        guard current.version == replacement.version,
              current.ownerScope == replacement.ownerScope,
              current.deletionEpoch == replacement.deletionEpoch
        else { return false }

        if current.exposureBarrier == .pending {
            return replacement.exposureBarrier == .closed
                && replacement.blockedGeneration != nil
                && replacement.completedGroups.isEmpty
                && replacement.legacyDisposition == .pending
                && replacement.phase == .cleanupPending
        }
        guard replacement.exposureBarrier == .closed,
              let oldGeneration = current.blockedGeneration,
              let newGeneration = replacement.blockedGeneration,
              newGeneration >= oldGeneration
        else { return false }

        if replacement.completedGroups == current.completedGroups {
            if replacement.phase == .completed {
                return current.completedGroups
                    == AccountDeletionCleanupGroup.allCases
                    && replacement.legacyDisposition
                        == current.legacyDisposition
                    && replacement.blockedGeneration
                        == current.blockedGeneration
            }
            return replacement.phase == .cleanupPending
                && replacement.legacyDisposition
                    == current.legacyDisposition
        }
        guard replacement.phase == .cleanupPending,
              replacement.completedGroups
                == current.completedGroups
                    + [AccountDeletionCleanupGroup.allCases[
                        current.completedGroups.count]]
        else { return false }
        let appended = replacement.completedGroups.last
        if appended == .legacyInputs {
            return current.legacyDisposition == .pending
                && replacement.legacyDisposition != .pending
        }
        return replacement.legacyDisposition == current.legacyDisposition
    }

    private func withAdvisoryLock<Result>(
        ownerScope: String,
        _ body: () throws -> Result
    ) throws -> Result {
        let record = try recordURL(ownerScope: ownerScope)
        let directory = record.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        let lockURL = directory.appendingPathComponent(
            "\(ownerScope).lock")
        let descriptor = Darwin.open(
            lockURL.path, O_RDWR | O_CREAT, mode_t(0o600))
        guard descriptor >= 0 else {
            throw AccountDeletionLifecycleError.durability
        }
        defer { _ = Darwin.close(descriptor) }
        let hook = Self.testHookLock.withLock {
            Self.beforeOwnerLockAttemptHook
        }
        hook?(ownerScope)
        while Darwin.lockf(descriptor, F_LOCK, 0) != 0 {
            if errno == EINTR { continue }
            throw AccountDeletionLifecycleError.durability
        }
        defer { _ = Darwin.lockf(descriptor, F_ULOCK, 0) }
        return try body()
    }

    private func readUnlocked(
        ownerScope: String
    ) -> AccountDeletionLifecycleReadResult {
        guard let url = try? recordURL(ownerScope: ownerScope) else {
            return .blocked(.corrupt)
        }
        if let failure = Self.failureLock.withLock({
            Self.readFailures[ownerScope]
        }) {
            switch failure {
            case .unreadable: return .blocked(.unreadable)
            case .protectedDataUnavailable:
                return .blocked(.protectedDataUnavailable)
            case .failed: return .blocked(.failed)
            }
        }
        do {
            guard let data = try fileIO.read(url) else { return .missing }
            do {
                let record = try AccountDeletionLifecycleCodec.decode(data)
                guard record.ownerScope == ownerScope else {
                    return .blocked(.corrupt)
                }
                return .record(record)
            } catch AccountDeletionLifecycleError.blocked(
                .unsupportedVersion(let version)
            ) {
                return .blocked(.unsupportedVersion(version))
            } catch {
                return .blocked(.corrupt)
            }
        } catch let failure as AccountDeletionLifecycleReadFailure {
            switch failure {
            case .unreadable: return .blocked(.unreadable)
            case .protectedDataUnavailable:
                return .blocked(.protectedDataUnavailable)
            case .failed: return .blocked(.failed)
            }
        } catch {
            let description = String(describing: error)
            if description == "unreadable" {
                return .blocked(.unreadable)
            }
            if description == "protectedDataUnavailable" {
                return .blocked(.protectedDataUnavailable)
            }
            return .blocked(.failed)
        }
    }

    private func persist(
        _ record: AccountDeletionLifecycleRecord
    ) throws -> AccountDeletionLifecycleRecord {
        let destination = try recordURL(ownerScope: record.ownerScope)
        let directory = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        let temporary = try fileIO.createUniqueTemporaryFile(
            in: directory, mode: 0o600)
        var renamed = false
        var closed = false
        do {
            let encoded = try AccountDeletionLifecycleCodec.encode(record)
            var offset = 0
            while offset < encoded.count {
                switch try fileIO.writeSome(
                    encoded, from: offset, to: temporary) {
                case .interrupted:
                    continue
                case .written(let count):
                    guard count > 0 else {
                        throw AccountDeletionLifecycleError.durability
                    }
                    offset += count
                }
            }
            try fileIO.fsyncFile(at: temporary)
            try fileIO.closeFile(at: temporary)
            closed = true
            try fileIO.renamePOSIX(temporary, to: destination)
            renamed = true
            try fileIO.fsyncParent(of: destination)
            try fileIO.closeParent(of: destination)
            try CaptureAccountScope
                .publishSharedDeletionTransitionBeforeReadback(
                    record,
                    container: container)
            guard let readback = try fileIO.read(destination),
                  let decoded = try? AccountDeletionLifecycleCodec.decode(readback),
                  decoded == record else {
                throw AccountDeletionLifecycleError.typedReadbackMismatch
            }
            return decoded
        } catch {
            if !closed { try? fileIO.closeFile(at: temporary) }
            if !renamed {
                try? FileManager.default.removeItem(at: temporary)
            }
            throw error
        }
    }
}

enum AccountDeletionLifecycleEvent: Sendable {
    case pendingDurableReadback
    case barrierClosedDurableReadback
    case completedDurableReadback
}

struct AccountDeletionLifecycleEnvironment: Sendable {
    let authorizePendingDeletion:
        @Sendable (
            CaptureAccountScope.AccountBinding,
            @Sendable () throws -> AccountDeletionLifecycleRecord
        ) throws -> (AccountDeletionLifecycleRecord, UInt64)
    let verifyCurrentBinding:
        @Sendable (CaptureAccountScope.AccountBinding) throws -> Bool
    let blockResolution:
        @Sendable (CaptureAccountScope.AccountBinding) throws -> UInt64
    let deliverIdentityBoundary: @Sendable (UInt64) -> Void
    let setSignedInMirrorFalse:
        @Sendable (CaptureAccountScope.AccountBinding) throws -> Void
    let withdrawWidget:
        @Sendable (CaptureAccountScope.AccountBinding) throws
            -> AccountExposureCloseResult
    let closeLiveExposures:
        @Sendable (CaptureAccountScope.AccountBinding) async
            -> [AccountExposureAcknowledgement]
    let cancelStaleWork:
        @Sendable (CaptureAccountScope.AccountBinding) async
            -> [AccountExposureAcknowledgement]
    let verifyExposureBarrier:
        @Sendable (
            [AccountExposureAcknowledgement],
            [AccountExposureAcknowledgement]
        ) throws -> Bool
    let removeGroup:
        @Sendable (
            AccountDeletionCleanupGroup,
            CaptureAccountScope.AccountBinding,
            Bool
        ) throws -> Void
    let verifyGroupAbsent:
        @Sendable (
            AccountDeletionCleanupGroup,
            CaptureAccountScope.AccountBinding
        ) throws -> Bool
    let legacyOwnerScope: @Sendable () throws -> String?
    let reassertDeletionBarrier:
        @Sendable (String) throws
            -> (CaptureAccountScope.AccountBinding, UInt64)?

    init(
        verifyCurrentBinding:
            @escaping @Sendable (CaptureAccountScope.AccountBinding) throws -> Bool,
        blockResolution:
            @escaping @Sendable (CaptureAccountScope.AccountBinding) throws -> UInt64,
        deliverIdentityBoundary: @escaping @Sendable (UInt64) -> Void,
        setSignedInMirrorFalse:
            @escaping @Sendable (CaptureAccountScope.AccountBinding) throws -> Void,
        withdrawWidget:
            @escaping @Sendable (CaptureAccountScope.AccountBinding) throws
                -> AccountExposureCloseResult,
        closeLiveExposures:
            @escaping @Sendable (CaptureAccountScope.AccountBinding) async
                -> [AccountExposureAcknowledgement],
        cancelStaleWork:
            @escaping @Sendable (CaptureAccountScope.AccountBinding) async
                -> [AccountExposureAcknowledgement],
        verifyExposureBarrier:
            @escaping @Sendable (
                [AccountExposureAcknowledgement],
                [AccountExposureAcknowledgement]
            ) throws -> Bool,
        removeGroup:
            @escaping @Sendable (
                AccountDeletionCleanupGroup,
                CaptureAccountScope.AccountBinding,
                Bool
            ) throws -> Void,
        verifyGroupAbsent:
            @escaping @Sendable (
                AccountDeletionCleanupGroup,
                CaptureAccountScope.AccountBinding
            ) throws -> Bool,
        legacyOwnerScope: @escaping @Sendable () throws -> String?,
        reassertDeletionBarrier:
            @escaping @Sendable (String) throws
                -> (CaptureAccountScope.AccountBinding, UInt64)? = { _ in nil },
        authorizePendingDeletion:
            (@Sendable (
                CaptureAccountScope.AccountBinding,
                @Sendable () throws -> AccountDeletionLifecycleRecord
            ) throws -> (AccountDeletionLifecycleRecord, UInt64))? = nil
    ) {
        self.verifyCurrentBinding = verifyCurrentBinding
        self.blockResolution = blockResolution
        self.deliverIdentityBoundary = deliverIdentityBoundary
        self.setSignedInMirrorFalse = setSignedInMirrorFalse
        self.withdrawWidget = withdrawWidget
        self.closeLiveExposures = closeLiveExposures
        self.cancelStaleWork = cancelStaleWork
        self.verifyExposureBarrier = verifyExposureBarrier
        self.removeGroup = removeGroup
        self.verifyGroupAbsent = verifyGroupAbsent
        self.legacyOwnerScope = legacyOwnerScope
        self.reassertDeletionBarrier = reassertDeletionBarrier
        self.authorizePendingDeletion = authorizePendingDeletion
            ?? { binding, persist in
                let pending = try persist()
                return (pending, binding.generation)
            }
    }
}

final class AccountDeletionLifecycle: @unchecked Sendable {
    enum LockState: Equatable { case locked, unlocked }

    private let lock = NSLock()
    private let store: AccountDeletionLifecycleStore
    private let environment: AccountDeletionLifecycleEnvironment
    private let faultInjector: DeletionFaultInjector
    private let eventObserver:
        @Sendable (AccountDeletionLifecycleEvent) -> Void
    private let progressObserver: @Sendable (String) -> Void
    private var activeOperations: Set<String> = []

    private(set) var lockStateForTests: LockState = .unlocked
    private(set) var mainSyncCountForTests = 0

    init(
        store: AccountDeletionLifecycleStore,
        environment: AccountDeletionLifecycleEnvironment,
        faultInjector: DeletionFaultInjector = .none,
        eventObserver:
            @escaping @Sendable (AccountDeletionLifecycleEvent) -> Void
                = { _ in },
        progressObserver: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.store = store
        self.environment = environment
        self.faultInjector = faultInjector
        self.eventObserver = eventObserver
        self.progressObserver = progressObserver
    }

    func record(
        ownerScope: String
    ) -> AccountDeletionLifecycleReadResult {
        store.read(ownerScope: ownerScope)
    }

    func preflightBegin(
        binding: CaptureAccountScope.AccountBinding
    ) throws {
        if CaptureAccountScope.isInsidePreferenceMutation {
            throw AccountDeletionLifecycleError.preferenceMutationInProgress
        }
        guard try environment.verifyCurrentBinding(binding) else {
            throw AccountDeletionLifecycleError.staleBinding
        }
    }

    func begin(
        binding: CaptureAccountScope.AccountBinding
    ) async throws -> AccountDeletionLifecycleRecord {
        try preflightBegin(binding: binding)
        try enter(ownerScope: binding.scope)
        defer { leave(ownerScope: binding.scope) }
        let (pending, _) =
            try environment.authorizePendingDeletion(binding) {
                try self.store.createPending(ownerScope: binding.scope)
            }
        // Synthetic interruption coverage begins only after the request is
        // durably admitted. Pre-admission persistence failures are exercised
        // separately and must never be represented as pending deletion.
        try inject(.before, .pendingSync)
        try inject(.after, .pendingSync)
        try inject(.before, .pendingReadback)
        eventObserver(.pendingDurableReadback)
        try inject(.before, .resolutionGeneration)
        let blockedGeneration = try environment.blockResolution(binding)
        try inject(.after, .resolutionGeneration)
        try inject(.before, .signedInMirror)
        try environment.setSignedInMirrorFalse(binding)
        try inject(.after, .signedInMirror)
        try inject(.before, .widgetWithdrawal)
        let widgetResult = try environment.withdrawWidget(binding)
        guard Self.isWidgetTerminalSuccess(widgetResult) else {
            throw AccountDeletionLifecycleError.exposureBarrierFailed
        }
        try inject(.after, .widgetWithdrawal)
        // The pending-readback admission boundary includes all three immediate
        // fail-closed gates, so an injected post-readback crash cannot expose B.
        try inject(.after, .pendingReadback)
        return try await continuePending(
            pending, binding: binding,
            reassertedGeneration: blockedGeneration,
            immediateGatesClosed: true)
    }

    func recover(
        ownerScope: String
    ) async throws -> AccountDeletionLifecycleRecord {
        try enter(ownerScope: ownerScope)
        defer { leave(ownerScope: ownerScope) }
        let record: AccountDeletionLifecycleRecord
        switch store.read(ownerScope: ownerScope) {
        case .record(let value):
            record = value
        case .missing:
            throw AccountDeletionLifecycleError.invalidRecord
        case .blocked(let reason):
            throw AccountDeletionLifecycleError.blocked(reason)
        }
        guard record.phase != .completed else { return record }
        guard let (binding, generation) =
                try environment.reassertDeletionBarrier(ownerScope) else {
            throw AccountDeletionLifecycleError.staleBinding
        }
        return try await continuePending(
            record,
            binding: binding,
            reassertedGeneration: generation)
    }

    private func continuePending(
        _ starting: AccountDeletionLifecycleRecord,
        binding: CaptureAccountScope.AccountBinding,
        reassertedGeneration: UInt64? = nil,
        immediateGatesClosed: Bool = false
    ) async throws -> AccountDeletionLifecycleRecord {
        var record = starting

        if !immediateGatesClosed {
            progressObserver("signedInMirror")
            try inject(.before, .resolutionGeneration)
        }
        let blockedGeneration = try reassertedGeneration
            ?? environment.blockResolution(binding)
        if !immediateGatesClosed {
            progressObserver("widgetWithdrawal")
            try inject(.after, .resolutionGeneration)
        }
        if !immediateGatesClosed {
            try inject(.before, .signedInMirror)
            do {
                try environment.setSignedInMirrorFalse(binding)
            } catch {
                throw AccountDeletionLifecycleError.cleanupStepFailed(
                    "signedInMirror", String(describing: error))
            }
            try inject(.after, .signedInMirror)
        }
        environment.deliverIdentityBoundary(blockedGeneration)

        if !immediateGatesClosed {
            try inject(.before, .widgetWithdrawal)
            let widgetResult = try environment.withdrawWidget(binding)
            guard Self.isWidgetTerminalSuccess(widgetResult) else {
                throw AccountDeletionLifecycleError.exposureBarrierFailed
            }
            try inject(.after, .widgetWithdrawal)
        }

        progressObserver("liveExposureClosure")
        try inject(.before, .liveExposureClosure)
        let live = await environment.closeLiveExposures(binding)
        guard Self.allAcknowledged(live) else {
            throw AccountDeletionLifecycleError.exposureBarrierFailed
        }
        try inject(.after, .liveExposureClosure)

        progressObserver("staleWorkCancellation")
        try inject(.before, .staleWorkCancellation)
        let stale = await environment.cancelStaleWork(binding)
        guard Self.allAcknowledged(stale) else {
            throw AccountDeletionLifecycleError.exposureBarrierFailed
        }
        try inject(.after, .staleWorkCancellation)

        progressObserver("barrierVerification")
        try inject(.before, .barrierVerification)
        guard try environment.verifyExposureBarrier(live, stale) else {
            throw AccountDeletionLifecycleError.exposureBarrierFailed
        }
        try inject(.after, .barrierVerification)

        progressObserver("barrierSync")
        try inject(.before, .barrierSync)
        do {
            record = try store.compareAndSwap(
                ownerScope: binding.scope,
                expectedEpoch: record.deletionEpoch
            ) {
                $0.exposureBarrier = .closed
                $0.blockedGeneration = blockedGeneration
            }
        } catch {
            throw AccountDeletionLifecycleError.cleanupStepFailed(
                "barrierSync", String(describing: error))
        }
        try inject(.after, .barrierSync)
        try inject(.before, .barrierReadback)
        eventObserver(.barrierClosedDurableReadback)
        try inject(.after, .barrierReadback)

        for completed in record.completedGroups {
            guard try environment.verifyGroupAbsent(completed, binding) else {
                throw AccountDeletionLifecycleError
                    .cleanupVerificationFailed(completed)
            }
        }
        let legacyOwned = try environment.legacyOwnerScope() == binding.scope
        for group in AccountDeletionCleanupGroup.allCases
            .dropFirst(record.completedGroups.count) {
            progressObserver(group.rawValue)
            try inject(.before, DeletionFaultStage(rawValue: group.rawValue)!)
            do {
                try environment.removeGroup(group, binding, legacyOwned)
            } catch {
                throw AccountDeletionLifecycleError.cleanupStepFailed(
                    group.rawValue, String(describing: error))
            }
            guard try environment.verifyGroupAbsent(group, binding) else {
                throw AccountDeletionLifecycleError
                    .cleanupVerificationFailed(group)
            }
            do {
                record = try store.compareAndSwap(
                    ownerScope: binding.scope,
                    expectedEpoch: record.deletionEpoch
                ) {
                    $0.completedGroups.append(group)
                    if group == .legacyInputs {
                        $0.legacyDisposition =
                            legacyOwned ? .retired : .notOwned
                    }
                }
            } catch {
                throw AccountDeletionLifecycleError.cleanupStepFailed(
                    "\(group.rawValue)Sync", String(describing: error))
            }
            try inject(.after, DeletionFaultStage(rawValue: group.rawValue)!)
        }

        progressObserver("completedSync")
        try inject(.before, .completedSync)
        do {
            record = try store.compareAndSwap(
                ownerScope: binding.scope,
                expectedEpoch: record.deletionEpoch
            ) { $0.phase = .completed }
        } catch {
            throw AccountDeletionLifecycleError.cleanupStepFailed(
                "completedSync", String(describing: error))
        }
        try inject(.after, .completedSync)
        try inject(.before, .completedReadback)
        eventObserver(.completedDurableReadback)
        try inject(.after, .completedReadback)
        return record
    }

    private func enter(ownerScope: String) throws {
        try lock.withLock {
            lockStateForTests = .locked
            defer { lockStateForTests = .unlocked }
            guard activeOperations.insert(ownerScope).inserted else {
                throw AccountDeletionLifecycleError.durability
            }
        }
    }

    private func leave(ownerScope: String) {
        lock.withLock {
            _ = activeOperations.remove(ownerScope)
        }
    }

    private func inject(
        _ boundary: DeletionFaultBoundary,
        _ stage: DeletionFaultStage
    ) throws {
        try faultInjector(DeletionFaultPoint(boundary, stage))
    }

    fileprivate static func isTerminalSuccess(
        _ result: AccountExposureCloseResult
    ) -> Bool {
        result == .closed || result == .alreadyClosed
    }

    /// Widget ownerMismatch is produced only after the snapshot store has
    /// corroborated that any retained payload envelope belongs to another owner.
    /// It is intentionally terminal here only; participant mismatches still fail
    /// `allAcknowledged` because they cannot prove that exposure was closed.
    private static func isWidgetTerminalSuccess(
        _ result: AccountExposureCloseResult
    ) -> Bool {
        isTerminalSuccess(result) || result == .ownerMismatch
    }

    private static func allAcknowledged(
        _ acknowledgements: [AccountExposureAcknowledgement]
    ) -> Bool {
        acknowledgements.allSatisfy { isTerminalSuccess($0.result) }
    }
}

private final class LiveAccountDeletionContext: @unchecked Sendable {
    let container: URL
    let defaults: UserDefaults
    let secretStore: any PairingSecretStore
    let pairingServices: (cell: String, door: String)
    let exposureCoordinator: AccountExposureCoordinator
    let verifiedIdentityForScope: @Sendable (String) -> AuthIdentity?
    let legacyEnumerationObserver: @Sendable (URL) -> Void

    init(
        container: URL,
        defaults: UserDefaults,
        secretStore: any PairingSecretStore,
        pairingServices: (cell: String, door: String),
        exposureCoordinator: AccountExposureCoordinator,
        verifiedIdentityForScope:
            @escaping @Sendable (String) -> AuthIdentity?,
        legacyEnumerationObserver: @escaping @Sendable (URL) -> Void
    ) {
        self.container = container
        self.defaults = defaults
        self.secretStore = secretStore
        self.pairingServices = pairingServices
        self.exposureCoordinator = exposureCoordinator
        self.verifiedIdentityForScope = verifiedIdentityForScope
        self.legacyEnumerationObserver = legacyEnumerationObserver
    }

    func withdrawWidget(
        binding: CaptureAccountScope.AccountBinding
    ) -> AccountExposureCloseResult {
        switch CaptureWidgetSnapshotStore.withdraw(
            expectedOwner: binding.scope) {
        case .withdrawn:
            return .closed
        case .alreadyAbsent:
            return .alreadyClosed
        case .ownerMismatch:
            return .ownerMismatch
        case .persistenceFailed:
            return .persistenceFailed
        }
    }

    func legacyOwnerScope() -> String? {
        let marker = container.appendingPathComponent(".migrated-to")
        guard let data = try? Data(contentsOf: marker) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func remove(
        group: AccountDeletionCleanupGroup,
        binding: CaptureAccountScope.AccountBinding,
        legacyOwned: Bool
    ) throws {
        switch group {
        case .trackBPreferences:
            for key in AccountPreferenceCatalog.entries.map(\.canonicalKey) {
                defaults.removeObject(
                    forKey: "\(binding.scope).\(key)")
            }
            try synchronizeDefaults()
        case .pairingPreferences:
            for key in [
                "foundryx.cell.url",
                "foundryx.cell.authMode",
                "foundryx.door.url",
            ] {
                defaults.removeObject(
                    forKey: "\(binding.scope).\(key)")
            }
            try synchronizeDefaults()
        case .pairingSecrets:
            for service in [
                pairingServices.cell,
                pairingServices.door,
            ] {
                let result = secretStore.removeExplicitOwner(
                    service: service,
                    account: binding.scope)
                guard result.succeeded else {
                    throw AccountDeletionLifecycleError.durability
                }
            }
        case .localRoot:
            if FileManager.default.fileExists(atPath: binding.root.path) {
                try FileManager.default.removeItem(at: binding.root)
            }
        case .legacyInputs:
            guard legacyOwned else { return }
            for legacyPreferenceKey in
                AccountPreferenceCatalog.entries.map(\.canonicalKey)
                + [
                    "foundryx.cell.url",
                    "foundryx.cell.authMode",
                    "foundryx.door.url",
                ] {
                defaults.removeObject(forKey: legacyPreferenceKey)
            }
            if let identity = verifiedIdentityForScope(binding.scope) {
                guard LegacySignupMarkerMigration.retireForDeletion(
                    identity: identity,
                    ownerScope: binding.scope,
                    generation: binding.generation,
                    durableLegacyOwnerScope: legacyOwnerScope(),
                    defaults: defaults) == .saved else {
                    throw AccountDeletionLifecycleError.durability
                }
            }
            try synchronizeDefaults()
            for service in [
                pairingServices.cell,
                pairingServices.door,
            ] {
                let result = secretStore.removeExplicitOwner(
                    service: service, account: "")
                guard result.succeeded else {
                    throw AccountDeletionLifecycleError.durability
                }
            }
        case .accountSurfaces:
            let outcomes = AccountSurfaceRegistry.eraseAll(
                binding, defaults: defaults)
            guard outcomes.values.allSatisfy(\.isTerminalSuccess) else {
                let failures = outcomes
                    .filter { !$0.value.isTerminalSuccess }
                    .sorted { $0.key.rawValue < $1.key.rawValue }
                    .map { "\($0.key.rawValue)=\($0.value)" }
                    .joined(separator: ", ")
                throw AccountDeletionLifecycleError.cleanupStepFailed(
                    group.rawValue, failures)
            }
        }
    }

    func verify(
        group: AccountDeletionCleanupGroup,
        binding: CaptureAccountScope.AccountBinding
    ) -> Bool {
        switch group {
        case .trackBPreferences:
            return AccountPreferenceCatalog.entries.allSatisfy {
                defaults.object(
                    forKey: "\(binding.scope).\($0.canonicalKey)") == nil
            }
        case .pairingPreferences:
            return [
                "foundryx.cell.url",
                "foundryx.cell.authMode",
                "foundryx.door.url",
            ].allSatisfy {
                defaults.object(
                    forKey: "\(binding.scope).\($0)") == nil
            }
        case .pairingSecrets:
            return [
                pairingServices.cell,
                pairingServices.door,
            ].allSatisfy {
                secretStore.inspect(
                    service: $0,
                    account: binding.scope) == .notFound
            }
        case .localRoot:
            return !FileManager.default.fileExists(
                atPath: binding.root.path)
        case .legacyInputs:
            guard legacyOwnerScope() == binding.scope else { return true }
            let preferencesAbsent =
                (AccountPreferenceCatalog.entries.map(\.canonicalKey)
                    + [
                        "foundryx.cell.url",
                        "foundryx.cell.authMode",
                        "foundryx.door.url",
                    ]).allSatisfy { legacyPreferenceKey in
                        defaults.object(
                            forKey: legacyPreferenceKey) == nil
                    }
            let signupAbsent: Bool
            if let identity = verifiedIdentityForScope(binding.scope) {
                signupAbsent =
                    LegacySignupMarkerMigration.isAbsentForDeletion(
                        identity: identity,
                        ownerScope: binding.scope,
                        generation: binding.generation,
                        durableLegacyOwnerScope: legacyOwnerScope(),
                        defaults: defaults)
            } else {
                signupAbsent = false
            }
            return preferencesAbsent
                && signupAbsent
                && secretStore.inspect(
                    service: pairingServices.cell,
                    account: "") == .notFound
                && secretStore.inspect(
                    service: pairingServices.door,
                    account: "") == .notFound
        case .accountSurfaces:
            // Erasers are idempotent and verify their terminal state. Re-running on
            // recovery proves cross-process and keychain state after a crash.
            return AccountSurfaceRegistry.eraseAll(
                binding, defaults: defaults
            ).values.allSatisfy(\.isTerminalSuccess)
        }
    }

    private func synchronizeDefaults() throws {
        guard defaults.synchronize() else {
            throw AccountDeletionLifecycleError.durability
        }
    }
}

extension AccountDeletionLifecycle {
    static func live(
        container: URL,
        defaults: UserDefaults,
        secretStore: any PairingSecretStore,
        pairingServices: (cell: String, door: String),
        exposureCoordinator: AccountExposureCoordinator,
        verifiedIdentityForScope:
            @escaping @Sendable (String) -> AuthIdentity?,
        legacyEnumerationObserver:
            @escaping @Sendable (URL) -> Void,
        faultInjector: DeletionFaultInjector = .none,
        progressObserver: @escaping @Sendable (String) -> Void = { _ in }
    ) -> AccountDeletionLifecycle {
        let context = LiveAccountDeletionContext(
            container: container,
            defaults: defaults,
            secretStore: secretStore,
            pairingServices: pairingServices,
            exposureCoordinator: exposureCoordinator,
            verifiedIdentityForScope: verifiedIdentityForScope,
            legacyEnumerationObserver: legacyEnumerationObserver)
        let environment = AccountDeletionLifecycleEnvironment(
            verifyCurrentBinding: { binding in
                CaptureAccountScope.isCurrent(binding)
            },
            blockResolution: { binding in
                try CaptureAccountScope.blockForAccountDeletion(
                    expected: binding)
            },
            deliverIdentityBoundary: { generation in
                CaptureAccountScope.deliverAccountDeletionBoundary(
                    generation: generation)
            },
            setSignedInMirrorFalse: { _ in
                try CaptureAccountScope
                    .setSignedInMirrorFalseForAccountDeletion()
            },
            withdrawWidget: { binding in
                context.withdrawWidget(binding: binding)
            },
            closeLiveExposures: { binding in
                await context.exposureCoordinator
                    .closeRegisteredExposures(expected: binding)
            },
            cancelStaleWork: { binding in
                await context.exposureCoordinator
                    .cancelRegisteredStaleWork(expected: binding)
            },
            verifyExposureBarrier: { live, stale in
                (live + stale).allSatisfy {
                    $0.result == .closed
                        || $0.result == .alreadyClosed
                }
            },
            removeGroup: { group, binding, legacyOwned in
                try context.remove(
                    group: group,
                    binding: binding,
                    legacyOwned: legacyOwned)
            },
            verifyGroupAbsent: { group, binding in
                context.verify(group: group, binding: binding)
            },
            legacyOwnerScope: {
                context.legacyOwnerScope()
            },
            reassertDeletionBarrier: { ownerScope in
                // Recovery may run before AuthStore can publish a pending activation.
                // The verified OAuth identity is therefore the ownership proof for
                // the signed-out path; never reconstruct a destructive binding
                // without that exact proof.
                guard verifiedIdentityForScope(ownerScope) != nil else {
                    throw AccountDeletionLifecycleError.staleBinding
                }
                return try CaptureAccountScope.reassertAccountDeletionBarrier(
                    ownerScope: ownerScope,
                    verifiedSignedOutOwner: true)
            },
            authorizePendingDeletion: { binding, persistPending in
                let pending =
                    try CaptureAccountScope.persistPendingAccountDeletion(
                    expected: binding,
                    persistPending: persistPending)
                return (pending, binding.generation)
            })
        return AccountDeletionLifecycle(
            store: AccountDeletionLifecycleStore(container: container),
            environment: environment,
            faultInjector: faultInjector,
            progressObserver: progressObserver)
    }
}
