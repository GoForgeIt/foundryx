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

/// NOT THE PRODUCTION DECODER, AND IT MUST NOT BECOME ONE.
///
/// `decode(_ mp3: Data) -> PocketPCM` takes the whole recording as one `Data` and returns the
/// whole decode as another. At fw-1.6's 32 kbps CBR, two hours is ~29 MB of MP3 that decodes to
/// **691 MB of PCM** — so a conformance to this protocol that actually decoded a real Pocket
/// file would take the app down, and only ever passed review because every fixture driving it
/// is a handful of bytes. The shipped path is `PocketAudioTranslator`, which streams: it holds
/// one read block and one 20 ms Opus packet, flat in the length of the recording.
///
/// This shape survives only because `PocketDurableSync` — the actor it belongs to — still has
/// no caller outside `Tests/`. If that actor is ever wired, this is the first thing that has to
/// go.
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

/// Every line the recorder's clock can make a person read, in the kit, for the same reason every
/// other device string is: `swift test` cannot compile `App/`.
public enum PocketRecorderClockPresentation {
    /// THE ONLY CLOCK SENTENCE THIS BUILD CAN HONESTLY SAY. It names the proof (the recorder is
    /// ahead of this phone) and what was done about it (filed under the arrival day) rather than
    /// the old "may have drifted", which was a guess dressed as a finding.
    public static let recorderAheadLine =
        "The recorder's clock is ahead of this phone, so this recording is filed under the day "
        + "it arrived."

    public static let everyLine: [String] = [recorderAheadLine]
}

/// WHAT A BROUGHT-OVER RECORDING'S TIME IS, AND WHEN THIS APP IS ALLOWED TO DOUBT IT.
///
/// ## The defect this replaces
///
/// This rule used to take a `lastClockSet: Date?` trust point and read `nil` — "we have never
/// set this recorder's clock" — as EVIDENCE THAT THE CLOCK WAS WRONG:
///
/// ```swift
/// let beforeTrust = lastClockSet.map { reported < $0 } ?? true   // nil -> true
/// ```
///
/// Nothing in this repository ever passed that argument. `PocketCaptureImport.makeConversation`
/// defaulted it to `nil` and its one production caller took the default, so `beforeTrust` was
/// `true` for every recording that has ever come off a recorder and every one of them was
/// labelled suspect. A warning that fires on everything says nothing. The parameter is gone
/// rather than defaulted, because a trust point nothing can produce is not a trust point.
///
/// ## Why this reads and does not write
///
/// The obvious repair is `APP&T` — set the recorder's clock and the trust point becomes real.
/// It was not taken, for two MEASURED reasons (hardware probe of firmware 1.6, 2026-08-16,
/// `foundry-hearth/reference/pocket-ble-protocol.md`):
///
///   * **There is no clock-READ verb.** No command in the firmware's verb set answers with the
///     device's own time. `APP&T` is write-only.
///   * **"Time: Synced to host" is not a readback.** `pocket-libre`'s `status` prints that as an
///     unconditional literal right after issuing a blind `set_time()`. It reports what the CLI
///     just did, not what the recorder said.
///
/// So the recorder has exactly one way to state that its clock is adrift: stamp a recording
/// LATER than the moment this phone received it, which is a time no recording can honestly
/// have. That is the whole of the evidence, so it is the whole of the rule.
///
/// ## The limit, stated rather than hidden
///
/// A recorder whose clock is stuck in the PAST is not detectable this way and this build does
/// not claim to detect it. Doing so needs either a clock-read verb the firmware does not have,
/// or the `APP&T` write — which has never been issued to any real device, and which would be a
/// WRITE on a path that otherwise only reads.
public enum PocketConversationClock {
    public static func resolve(reported: Date, broughtOver: Date, calendar: Calendar) -> PocketConversationTime {
        // THE ONLY DEVICE-SOURCED PROOF THERE IS. Everything else is a guess, and the previous
        // version of this line shipped a guess to nineteen recordings at once.
        let recorderIsAhead = reported > broughtOver
        // CLAMPED FOR GROUPING, NEVER OVERWRITTEN. A conversation dated to next week sorts above
        // everything forever; `recorderReported` keeps what the device actually said so the row
        // can still show the recorder's own digits.
        let timeline = recorderIsAhead ? calendar.startOfDay(for: broughtOver) : reported
        return .init(timeline: timeline, recorderReported: reported, broughtOver: broughtOver,
                     warning: recorderIsAhead ? PocketRecorderClockPresentation.recorderAheadLine : nil)
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

/// THE PROMISE A PERSON READS, AND WHAT MAKES IT TRUE.
///
/// It used to say *"Solleva never deletes anything from your recorder."* That was a description
/// of a missing feature rather than a policy, and it was about to become a lie: Nick's ruling of
/// 2026-08-16 is that a person MAY remove a recording from their own recorder once Solleva can
/// prove it already holds it somewhere else, either by choosing it or by arming an automatic
/// clear that is off by default.
///
/// So the promise is the one that survives that: nothing is removed that the owner did not ask
/// for. `PocketRecorderCommandGate` is what makes it a policy instead of a sentence — every
/// command this app composes for a recorder passes it, and a deletion nobody chose is refused
/// before the radio and recorded as refused.
public enum PocketRecorderCustodyPromise {
    public static let text = "Solleva never deletes anything you didn't ask it to."

    /// THE INVARIANT THAT WAS ALWAYS CORRECTLY NAMED — no *automatic* delete, which is a
    /// different and weaker claim than no delete. Kept as the declared policy; the PROOF is
    /// `PocketRecorderCommandLedger`, because a constant equal to zero is a claim no mutation
    /// can falsify and this one was asserted in four suites for months.
    public static let automaticDeleteCommands = 0
}

private extension Data {
    var hasPocketMP3Sync: Bool {
        guard count >= 2 else { return false }
        return indices.dropLast().contains { self[$0] == 0xff && self[$0 + 1] == 0xf3 }
    }
}
