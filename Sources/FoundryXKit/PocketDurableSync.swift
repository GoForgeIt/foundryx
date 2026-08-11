import Foundation

public enum PocketSyncCadence: String, Sendable, Equatable { case away, idle, watching, pulling }

public struct PocketPresenceBackoff: Sendable, Equatable {
    private var misses = 0
    public init() {}
    public mutating func missed() -> TimeInterval {
        let delay = min(300, 60 * (1 << min(misses, 3)))
        misses += 1
        return TimeInterval(delay)
    }
    public mutating func found() { misses = 0 }
}

public struct PocketRecorderFileKey: Hashable, Codable, Sendable {
    public let deviceStorageKey: String
    public let date: String
    public let timestamp: String
    public init(identity: RecordingDeviceIdentity, date: String, timestamp: String) {
        deviceStorageKey = identity.storageKey; self.date = date; self.timestamp = timestamp
    }
}

public struct PocketInventoryCandidate: Sendable, Equatable {
    public let key: PocketRecorderFileKey
    public let announcedSize: Int
    public let closureEvidence: Bool
    public init(key: PocketRecorderFileKey, announcedSize: Int, closureEvidence: Bool) {
        self.key = key; self.announcedSize = announcedSize; self.closureEvidence = closureEvidence
    }
}

public enum PocketSyncGap: String, Error, Sendable, Equatable {
    case closureSafetyUnproven = "Pocket file closure safety is not yet proven"
    case stockCompatibilityUnproven = "Pocket stock-file compatibility is not yet proven"
    case truncatedPayload = "Pocket payload is truncated"
    case malformedMP3 = "Pocket payload is not a supported MP3"
    case durableVerificationFailed = "Pocket payload could not be verified after durable storage"
    case identityQuarantined = "Pocket identity is quarantined"
}

public struct PocketFileEvidence: Sendable, Equatable {
    public let stockCompatibilityRecorded: Bool
    public let closureSafetyRecorded: Bool
    public init(stockCompatibilityRecorded: Bool, closureSafetyRecorded: Bool) {
        self.stockCompatibilityRecorded = stockCompatibilityRecorded
        self.closureSafetyRecorded = closureSafetyRecorded
    }
}

public struct PocketPCM: Sendable, Equatable {
    public let bytes: Data
    public let sampleRate: Int
    public let channels: Int
    public init(bytes: Data, sampleRate: Int, channels: Int) {
        self.bytes = bytes; self.sampleRate = sampleRate; self.channels = channels
    }
}

public protocol PocketMP3Decoding: Sendable {
    func decode(_ mp3: Data) async throws -> PocketPCM
}

public struct PocketDurableReceipt: Sendable, Equatable {
    public let captureID: String
    public let checksum: String
    public let reReadableBytes: Data
}

public protocol PocketDurableImportStore: Sendable {
    func existingReceipt(for key: PocketRecorderFileKey) async -> PocketDurableReceipt?
    /// Atomically persists source bytes, verifies their checksum by reading them back, and
    /// commits key -> captureID. The receipt is the crash-recovery/downstream enqueue boundary.
    func commit(key: PocketRecorderFileKey, source: Data) async throws -> PocketDurableReceipt
}

public enum PocketFinalizedSource: String, Sendable, Equatable { case pocket = "Pocket", omi = "Omi" }

public struct PocketFinalizedJob: Sendable, Equatable {
    public let captureID: String
    public let source: PocketFinalizedSource
    public let pcm: PocketPCM
}

public protocol PocketFinalizedCaptureSink: Sendable {
    func enqueue(_ job: PocketFinalizedJob) async
}

public enum PocketImportOutcome: Sendable, Equatable {
    case imported(captureID: String)
    case alreadyImported(captureID: String)
    case retryable(PocketSyncGap)
}

public actor PocketDurableSync {
    private let store: any PocketDurableImportStore
    private let decoder: any PocketMP3Decoding
    private let finalized: any PocketFinalizedCaptureSink
    private var inFlight: Set<PocketRecorderFileKey> = []

    public init(store: any PocketDurableImportStore, decoder: any PocketMP3Decoding,
                finalized: any PocketFinalizedCaptureSink) {
        self.store = store; self.decoder = decoder; self.finalized = finalized
    }

    public static func ordered(_ candidates: [PocketInventoryCandidate]) -> [PocketInventoryCandidate] {
        candidates.sorted {
            if $0.key.date != $1.key.date { return $0.key.date > $1.key.date }
            if $0.announcedSize != $1.announcedSize { return $0.announcedSize < $1.announcedSize }
            return $0.key.timestamp < $1.key.timestamp
        }
    }

    public func importFile(_ candidate: PocketInventoryCandidate, payload: Data,
                           evidence: PocketFileEvidence) async -> PocketImportOutcome {
        guard evidence.stockCompatibilityRecorded else { return .retryable(.stockCompatibilityUnproven) }
        guard evidence.closureSafetyRecorded, candidate.closureEvidence else { return .retryable(.closureSafetyUnproven) }
        if let receipt = await store.existingReceipt(for: candidate.key) {
            return .alreadyImported(captureID: receipt.captureID)
        }
        guard !inFlight.contains(candidate.key) else { return .retryable(.durableVerificationFailed) }
        inFlight.insert(candidate.key); defer { inFlight.remove(candidate.key) }
        guard payload.count >= candidate.announcedSize else { return .retryable(.truncatedPayload) }
        guard payload.hasPocketMP3Sync else { return .retryable(.malformedMP3) }
        let pcm: PocketPCM
        do { pcm = try await decoder.decode(payload) }
        catch { return .retryable(.malformedMP3) }
        do {
            let receipt = try await store.commit(key: candidate.key, source: payload)
            guard receipt.reReadableBytes == payload else { return .retryable(.durableVerificationFailed) }
            await finalized.enqueue(.init(captureID: receipt.captureID, source: .pocket, pcm: pcm))
            return .imported(captureID: receipt.captureID)
        } catch { return .retryable(.durableVerificationFailed) }
    }
}

public struct PocketConversationTime: Sendable, Equatable {
    public let timeline: Date
    public let recorderReported: Date
    public let broughtOver: Date
    public let warning: String?
}

public enum PocketConversationClock {
    public static func resolve(reported: Date, broughtOver: Date, lastClockSet: Date?, calendar: Calendar) -> PocketConversationTime {
        let future = reported > broughtOver
        let beforeTrust = lastClockSet.map { reported < $0 } ?? true
        let timeline = future ? calendar.startOfDay(for: broughtOver) : reported
        return .init(timeline: timeline, recorderReported: reported, broughtOver: broughtOver,
                     warning: (future || beforeTrust) ? "Time reported by recorder — device clock may have drifted" : nil)
    }
}

public struct PocketAmbientResult: Sendable, Equatable {
    public let conversationID: String
    public let activityLineageCount: Int
    public let notificationCount: Int
}

public enum PocketPostCaptureParity {
    public static func ambientResult(conversationID: String, enabled: Bool) -> PocketAmbientResult {
        .init(conversationID: conversationID, activityLineageCount: enabled ? 1 : 0, notificationCount: 0)
    }
}

public enum PocketRecorderCustodyPromise {
    public static let text = "Solleva never deletes anything from your recorder."
    public static let automaticDeleteCommands = 0
}

private extension Data {
    var hasPocketMP3Sync: Bool {
        guard count >= 2 else { return false }
        return indices.dropLast().contains { self[$0] == 0xff && self[$0 + 1] == 0xf3 }
    }
}
