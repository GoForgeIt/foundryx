// PocketBringOver.swift — THE FIRST THING IN THIS APP THAT EVER ASKS A RECORDER FOR A FILE.
//
// WHAT WAS MISSING, MEASURED RATHER THAN ASSERTED. `PocketBLEClient.download(_:)` shipped
// fully implemented and fully unit-tested, and a tree-wide search for callers outside `Tests/`
// returned NOTHING — the same measurement `PocketRecorderCheck.swift` records about
// `listDates()`. That file names the three things it was waiting on, and two of them turned
// out to be the same decision asked twice: what the SINK for an imported file is. This file
// answers the smallest honest version of that question — durable custody on this phone, proven
// by reading the bytes back — and stops there.
//
// WHAT IT NOW DOES, AND WHERE IT STOPS. The sink this file's first version said was
// "unspecified" turned out to be already built and already shipping: a completed capture
// reaches Lore as `seg-*.opus` segments in a capture directory plus a `.needs-finalize` marker,
// and `CaptureManager`'s drain and `tryFinalize` do the rest. So the leg is a TRANSLATOR and
// nothing else — `PocketAudioTranslator` turns the recorder's MP3 into the Opus frames the
// pipeline already speaks, `PocketCaptureImport` writes them into the standard capture layout,
// and past that hand-off a brought-over recording executes the SAME functions as a phone-mic or
// Omi one. There is no second ingest route, no Pocket-specific upload, no parallel finalize and
// no `if pocket` anywhere downstream: the origin travels as DATA (the `.capture-source` marker
// and the device sidecar), which is what `RecordingDeviceShape.filePull` was already for.
//
// WHAT THIS DELIBERATELY DOES NOT DO.
//
//   * IT NEVER STARTS A LIVE RECORDING. No FrameRouter, no `beginSession`, no `beginStreaming`,
//     no Live Activity, no recording pill, no `active` capture, no currently-recording state.
//     The file existed on the recorder before the phone was involved and dressing that up as a
//     recording would be a lie about where the audio came from. It DOES write WAL segments,
//     because that is what a finished capture is made of and inventing a second way to hold
//     one is the thing this design forbids — `CaptureManager.merge` has shipped exactly that
//     shape (pre-existing segments → `markNeedsFinalize` → `sync` → `tryFinalize`) for months.
//   * IT ISSUES NO DELETE. `PocketRecorderCustodyPromise.text` is a promise, and a bring-over
//     is the one operation that would be tempted to break it. It is repeated on this panel.
//   * IT BRINGS ONE FILE. Not a backlog, not a queue, not a cadence — those are written
//     (`PocketDurableSync`, `PocketPresenceBackoff`) and still have no caller, and a scheduler
//     over a leg no human has ever watched finish is a bigger unwired module, not a smaller one.

import Foundation
import CryptoKit

/// ONE FILE BEING WRITTEN INTO CUSTODY, A CHUNK AT A TIME.
///
/// WHY THIS EXISTS RATHER THAN `keep(_:bytes:)`. The old shape took the whole recording as one
/// `Data` — which meant the radio had to accumulate the whole recording as one `Data` too, and
/// then custody held a SECOND copy of it to prove the re-read. Two hours of Pocket audio is
/// ~29 MB, so peak was ~58 MB of a phone's memory for a file that is only ever streamed
/// through. Nothing here holds more than one BLE notification.
public protocol PocketRecorderFileWriting: Sendable {
    /// Append arriving bytes. Throws if the phone will not take them.
    func write(_ chunk: Data) throws
    /// THE COMMIT POINT: re-read what was written, compare it against a digest accumulated
    /// while writing, and only then take the real name. Returns the byte count it re-read.
    func commit() throws -> Int
    /// Remove the partial artifact. Idempotent — safe to call after `commit`.
    func abandon()
}

/// Where a brought-over file lives, how custody is proven, and what it became.
public protocol PocketRecorderFileCustody: Sendable {
    func alreadyHeld(_ key: PocketRecorderFileKey) async -> Bool
    /// Where this phone is holding the file, or nil when it is not holding it.
    func heldFile(_ key: PocketRecorderFileKey) async -> URL?
    /// Open a streaming commit for this key. Must leave nothing behind on failure.
    func beginKeeping(_ key: PocketRecorderFileKey) async throws -> any PocketRecorderFileWriting
    /// THE CONVERSATION THIS FILE BECAME, or nil when it has not become one yet.
    ///
    /// It is a separate fact from "the bytes are held", and conflating them is a data-loss
    /// shape: a phone that died between the custody commit and the import would hold the file
    /// forever, answer `alreadyHeld` yes, never ask the recorder again — and never make the
    /// conversation. With the receipt separate, the retry costs no radio time at all: the
    /// bytes are already here, so the import simply runs again off the held file.
    func conversation(for key: PocketRecorderFileKey) async -> String?
    func noteConversation(_ captureID: String, for key: PocketRecorderFileKey) async
}

/// Why custody refused to claim it is holding something.
public enum PocketRecorderCustodyFailure: Error, Sendable, Equatable {
    /// The bytes could not be written, or the directory could not be made.
    case couldNotWrite
    /// They were written and came back different. THE ONLY REASON THIS CASE EXISTS is that
    /// "the write call returned without throwing" is not the same claim as "the file is there
    /// and it is the file" — and custody is the second claim or it is nothing.
    case didNotReadBackIdentical
}

/// FILESYSTEM CUSTODY, WITH THE RE-READ AS THE COMMIT POINT.
///
/// The bytes go to a `.partial` sibling, are read back and compared, and only then take the
/// real name. So a crash, a full disk or a truncated write leaves a `.partial` that
/// `alreadyHeld` will never claim, instead of a short file that looks exactly like a good one.
public struct PocketRecorderFileStore: PocketRecorderFileCustody {
    private let explicitRoot: URL?

    /// - Parameter root: injected so a hermetic suite can hold real files somewhere it owns.
    ///   The default is the ACCOUNT-SCOPED private store, not a shared app directory: a file
    ///   brought over from a recorder is somebody's recording of a room they were in, and
    ///   `AccountDataIsolation` holds every durable user-private path to that rule.
    public init(root: URL? = nil) {
        self.explicitRoot = root
    }

    /// RESOLVED WHEN A FILE IS ACTUALLY TOUCHED, never at construction. `currentRoot()` takes a
    /// process-wide lock and reads an on-disk registry, and this store is built by a
    /// `@MainActor` model — doing that work in a property initialiser is a main-thread disk
    /// read on a screen appearing.
    private var root: URL {
        explicitRoot ?? CaptureAccountScope.privateURL(for: .pocketRecordings)
    }

    /// One file's address on this phone, from the recorder's own reported day and instant.
    /// `deviceStorageKey` is first because two recorders may report the same day and the same
    /// timestamp and be holding entirely different audio.
    public func url(for key: PocketRecorderFileKey) -> URL {
        root.appendingPathComponent(key.deviceStorageKey, isDirectory: true)
            .appendingPathComponent(key.date, isDirectory: true)
            .appendingPathComponent("\(key.timestamp).mp3")
    }

    /// The receipt that says which conversation this file became. It sits beside the audio so
    /// custody's two facts — "the bytes are here" and "they are a conversation" — travel
    /// together and are still two facts.
    public func receiptURL(for key: PocketRecorderFileKey) -> URL {
        url(for: key).deletingPathExtension().appendingPathExtension("capture")
    }

    public func alreadyHeld(_ key: PocketRecorderFileKey) async -> Bool {
        FileManager.default.fileExists(atPath: url(for: key).path)
    }

    public func heldFile(_ key: PocketRecorderFileKey) async -> URL? {
        let target = url(for: key)
        return FileManager.default.fileExists(atPath: target.path) ? target : nil
    }

    public func conversation(for key: PocketRecorderFileKey) async -> String? {
        guard let data = try? Data(contentsOf: receiptURL(for: key)),
              let id = String(data: data, encoding: .utf8), !id.isEmpty else { return nil }
        return id
    }

    public func noteConversation(_ captureID: String, for key: PocketRecorderFileKey) async {
        try? Data(captureID.utf8).write(to: receiptURL(for: key), options: [.atomic])
    }

    public func beginKeeping(_ key: PocketRecorderFileKey) async throws -> any PocketRecorderFileWriting {
        let destination = url(for: key)
        let partial = destination.appendingPathExtension("partial")
        do {
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: partial.path) {
                try FileManager.default.removeItem(at: partial)
            }
            guard FileManager.default.createFile(atPath: partial.path, contents: nil) else {
                throw PocketRecorderCustodyFailure.couldNotWrite
            }
            return try PocketRecorderFileWriter(partial: partial, destination: destination)
        } catch {
            try? FileManager.default.removeItem(at: partial)
            throw PocketRecorderCustodyFailure.couldNotWrite
        }
    }
}

/// THE STREAMING COMMIT, WITH THE RE-READ STILL THE COMMIT POINT.
///
/// The bytes go to a `.partial` sibling; a digest of everything handed over is accumulated as
/// they are written; then the partial is READ BACK OFF THE FILESYSTEM in bounded chunks and its
/// digest compared. Only then does it take the real name. So a crash, a full disk or a
/// truncated write leaves a `.partial` that `alreadyHeld` will never claim, instead of a short
/// file that looks exactly like a good one.
///
/// COMPARING DIGESTS RATHER THAN BYTES IS NOT A WEAKENING. The old proof compared two whole
/// copies in memory, which is the same claim for twice the file's footprint; SHA-256 over the
/// same two streams answers the identical question — "is what came back the thing that went
/// in" — in constant space. What it gives up is the ability to say WHERE they differ, and
/// custody never said that anyway: it deletes the artifact either way.
public final class PocketRecorderFileWriter: PocketRecorderFileWriting, @unchecked Sendable {
    /// Bytes re-read per pass on the verification sweep.
    static let verifyChunkBytes = 1 << 20

    private let lock = NSLock()
    private let partial: URL
    private let destination: URL
    private let handle: FileHandle
    private var digest = SHA256()
    private var written = 0
    private var closed = false

    init(partial: URL, destination: URL) throws {
        self.partial = partial
        self.destination = destination
        self.handle = try FileHandle(forWritingTo: partial)
    }

    public func write(_ chunk: Data) throws {
        try lock.withLock {
            guard !closed else { throw PocketRecorderCustodyFailure.couldNotWrite }
            do { try handle.write(contentsOf: chunk) }
            catch { throw PocketRecorderCustodyFailure.couldNotWrite }
            digest.update(data: chunk)
            written += chunk.count
        }
    }

    public func commit() throws -> Int {
        try lock.withLock {
            guard !closed else { throw PocketRecorderCustodyFailure.couldNotWrite }
            closed = true
            do {
                try handle.synchronize()
                try handle.close()
            } catch {
                try? FileManager.default.removeItem(at: partial)
                throw PocketRecorderCustodyFailure.couldNotWrite
            }
            let expected = digest.finalize()
            guard let reader = try? FileHandle(forReadingFrom: partial) else {
                try? FileManager.default.removeItem(at: partial)
                throw PocketRecorderCustodyFailure.didNotReadBackIdentical
            }
            var reRead = SHA256()
            var count = 0
            while true {
                let block = (try? reader.read(upToCount: Self.verifyChunkBytes)) ?? nil
                guard let block, !block.isEmpty else { break }
                reRead.update(data: block)
                count += block.count
            }
            try? reader.close()
            guard count == written, reRead.finalize() == expected else {
                try? FileManager.default.removeItem(at: partial)
                throw PocketRecorderCustodyFailure.didNotReadBackIdentical
            }
            do {
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.moveItem(at: partial, to: destination)
            } catch {
                try? FileManager.default.removeItem(at: partial)
                throw PocketRecorderCustodyFailure.couldNotWrite
            }
            return count
        }
    }

    public func abandon() {
        lock.withLock {
            if !closed { try? handle.close(); closed = true }
            try? FileManager.default.removeItem(at: partial)
        }
    }
}

/// What one bring-over established.
public enum PocketBringOverOutcome: Sendable, Equatable {
    /// The file is in custody AND it is a conversation. `captureID` is carried because the
    /// running app has to be able to hand exactly this capture to `CaptureManager` — an
    /// outcome that only said "it worked" would leave the conversation invisible until the
    /// next launch, which is the difference between a file on a phone and a recording a
    /// person can read.
    ///
    /// `clockWarning` IS CARRIED FOR THE SAME REASON `captureID` IS: it is a fact about this
    /// recording that only the import could establish, and dropping it here is precisely how
    /// `PocketImportedCapture.clockWarning` came to be a field nothing on earth read.
    case broughtOver(bytes: Int, captureID: String, clockWarning: String?)
    /// The bytes AND the conversation were already here; the recorder was not asked again.
    case alreadyHeld(captureID: String)
    case transferIncomplete     // fewer bytes than announced / stall / disconnect
    case unreadableRecording    // no MP3 sync, refused by the ceiling, or not audio at all
    case recorderUnavailable(String)   // carries a presentation line, never a raw error

    /// The conversation this bring-over produced, if it produced one.
    public var captureID: String? {
        switch self {
        case .broughtOver(_, let id, _), .alreadyHeld(let id): return id
        default: return nil
        }
    }
}

/// Every string this affordance can render, in the kit, for the same reason every other device
/// string is: `swift test` cannot compile `App/`.
public enum PocketBringOverPresentation {
    /// PLAIN, AND NOT "Download" OR "Sync". The file is on the recorder and the owner is asking
    /// for it to also be here; "download" is a word about a network and "sync" is a promise
    /// about everything, which is not what this button does.
    public static let actionTitle = "Bring over"

    /// While the radio is working. Hours over BLE is a real possibility for a long file, so
    /// this says what is happening rather than implying it is nearly done.
    public static let inProgressLine = "Bringing this recording over…"

    /// IT SAYS THE FILE IS STILL ON THE RECORDER, because "bring over" is the one word in this
    /// flow somebody could reasonably read as "move", and this is the moment they would.
    public static let broughtOverLine =
        "This recording is now in Solleva. It's still on the recorder too."

    public static let alreadyHeldLine =
        "Solleva already has this recording, so nothing was brought over again."

    /// NOTHING WAS KEPT, said in those words. A partial file that looked like a recording and
    /// played as silence would be worse than no file, so custody keeps nothing at all — and
    /// this line is what makes that visible rather than a silent no-op.
    public static let transferIncompleteLine =
        "The transfer didn't finish, so nothing was kept. The recording is still on the "
        + "recorder — try again when it's nearby."

    public static let unreadableRecordingLine =
        "Solleva couldn't read this recording, so nothing was kept. It's still on the recorder."

    /// THE OWNER WALKED AWAY, OR LOCKED THEIR PHONE, AND CAME BACK TO A PAGE THAT SAID NOTHING.
    ///
    /// A bring-over over BLE can take hours for a long file — this file's own `inProgressLine`
    /// says so — and the recorder page stops the errand when it disappears or the app leaves
    /// the foreground, which is the right call for a radio session and the wrong thing to do
    /// silently. Backgrounding is not an exotic case: it is what a person DOES during a slow
    /// transfer. Before this line, `cancel()` tore the session down, wrote `left-the-page` to a
    /// log nobody reads, and left the message nil, so the page a person returned to looked
    /// exactly like one where nothing had ever been asked for.
    ///
    /// It says the same three things every other stopped-transfer line says: what stopped, that
    /// nothing was removed from the recorder, and how to start again.
    public static let leftTheRecorderLine =
        "Solleva stopped bringing this recording over when it left the recorder's page. "
        + "Nothing was removed from the recorder — tap Bring it over to start again."

    /// Every line this affordance can render, so a claim about it is held over the POPULATION
    /// rather than over whichever string a test author remembered.
    ///
    /// THERE IS NO NOTE OF ITS OWN HERE ON PURPOSE. The deletion promise this action is most
    /// tempted to break already has a renderer on the panel this action lives on —
    /// `PocketRecorderCheckPresentation.sectionNote` — and a second copy of it beside the
    /// button would be the same sentence twice on one screen.
    ///
    /// `PocketRecorderClockPresentation` IS IN HERE because `message(for:)` can now append it,
    /// and a population claim that missed a line this affordance renders would be a population
    /// claim about the wrong population.
    public static let everyLine: [String] = [
        actionTitle, inProgressLine, broughtOverLine, alreadyHeldLine,
        transferIncompleteLine, unreadableRecordingLine, leftTheRecorderLine,
    ] + PocketRecorderClockPresentation.everyLine

    /// The line an outcome earns. `.recorderUnavailable` carries its own, because the reason a
    /// session never opened is the attach seam's to state, not this file's to guess at.
    ///
    /// THE CLOCK WARNING IS READ HERE, AND THIS IS THE ONLY PLACE IT COULD BE. It was computed
    /// on every import and then dropped on the floor — `PocketImportedCapture.clockWarning`
    /// went into a struct that this file's own `conversation(_:)` discarded, so a field that
    /// could only ever be produced by an import was consumed by nothing at all. It goes AFTER
    /// the landing sentence: the first thing a person needs is whether their recording is here.
    public static func message(for outcome: PocketBringOverOutcome) -> String {
        switch outcome {
        case .broughtOver(_, _, let clockWarning):
            guard let clockWarning else { return broughtOverLine }
            return broughtOverLine + " " + clockWarning
        case .alreadyHeld:              return alreadyHeldLine
        case .transferIncomplete:       return transferIncompleteLine
        case .unreadableRecording:      return unreadableRecordingLine
        case .recorderUnavailable(let line): return line
        }
    }
}

#if canImport(CoreBluetooth)

/// ONE BRING-OVER: open a session, ask for one file, prove it landed, close it.
public enum PocketBringOver {

    /// THE CEILING. One value, enforced where the bytes actually arrive — see
    /// `PocketBLEClient.maximumDownloadBytes` for the arithmetic and for why it is no longer
    /// 32 MB. Checked HERE against the LISTED size purely to save the owner a session that was
    /// always going to end in a refusal; the binding checks are the client's, because the listed
    /// size and the announced size are two different numbers from the same untrusted device and
    /// only one of them governs how many bytes actually turn up.
    public static let maximumBytes = PocketBLEClient.maximumDownloadBytes

    /// THE ONE THE SHELF OFFERS: smallest first. Long files are hours over BLE, and the first
    /// file anybody ever pulls off a Pocket should be the one that finishes.
    ///
    /// The comparator is NOT re-implemented here: `PocketDurableSync.ordered(_:)` is the
    /// shipped backlog order (newest day first, shorter file breaks the tie) and a second
    /// spelling of it would drift from the one the sync path uses.
    /// THE NEXT one the shelf offers — the smallest this phone does not already hold.
    ///
    /// `offered(_:)` below is ordering ONLY, and ordering alone re-offers the same file
    /// forever: bring it over, re-read the shelf, and the winner of the comparator is still
    /// the winner, because nothing subtracts what is already here. A person with a backlog
    /// could bring over exactly one recording per recorder, for the life of the device, at
    /// the cost of a Bluetooth handshake every time.
    ///
    /// The exclusion key is (date, timestamp) — the recorder's OWN name for a file, which is
    /// what both the shelf listing and the custody key are built from. Deliberately not the
    /// size: two takes can be the same length, and a file that changed size between listings
    /// is a different fact worth noticing rather than silently re-offering.
    ///
    /// Pure and synchronous so the choice is testable without a disk. The caller supplies
    /// what it holds; see `offeredNext(_:custody:identity:)` for the async form that asks
    /// custody.
    public static func offered(_ recordings: [PocketRecording],
                               excluding held: Set<PocketRecordingRequest>) -> PocketRecording? {
        offered(recordings.filter { !held.contains($0.request) })
    }

    /// The async form: ask custody which files are already here, then offer the next one.
    ///
    /// Asks per recording rather than fetching a manifest, because `alreadyHeld` is the only
    /// authority on the question and a second index of it would be a second answer to
    /// "do we have this" — the shape that loses recordings.
    ///
    /// A recording whose bytes are held but which has NOT become a conversation is still
    /// "held" here, and that is correct: re-pulling it over the radio would cost the owner a
    /// session to re-fetch bytes already on the phone. The import retries off the held file.
    public static func offeredNext(_ recordings: [PocketRecording],
                                   custody: any PocketRecorderFileCustody,
                                   identity: RecordingDeviceIdentity) async -> PocketRecording? {
        var held: Set<PocketRecordingRequest> = []
        for recording in recordings {
            let key = PocketRecorderFileKey(identity: identity,
                                            date: recording.date,
                                            timestamp: recording.timestamp)
            if await custody.alreadyHeld(key) { held.insert(recording.request) }
        }
        return offered(recordings, excluding: held)
    }

    public static func offered(_ recordings: [PocketRecording]) -> PocketRecording? {
        // The identity is a placeholder because ordering reads only day, size and instant —
        // and a real one is not knowable from a shelf listing alone.
        let ordering = RecordingDeviceIdentity(shape: .filePull, hardwareToken: "ordering")
        let candidates = recordings.map {
            PocketInventoryCandidate(
                key: PocketRecorderFileKey(identity: ordering,
                                           date: $0.date,
                                           timestamp: $0.timestamp),
                announcedSize: $0.sizeBytes,
                closureEvidence: true)
        }
        guard let first = PocketDurableSync.ordered(candidates).first else { return nil }
        return recordings.first {
            $0.date == first.key.date && $0.timestamp == first.key.timestamp
        }
    }

    /// WHERE THE CONVERSATION IS WRITTEN, and why it is a parameter.
    ///
    /// The default is the account-scoped captures root — the SAME directory `CaptureManager`
    /// hydrates from, because a conversation written anywhere else is a directory nothing will
    /// ever look in. It is injectable so a hermetic suite can own the library it asserts about.
    public struct Destination: Sendable {
        public let baseDir: URL
        public let binding: CaptureAccountScope.AccountBinding?
        public let log: DoorLog?
        /// THE BINDING IS ONLY DEFAULTED WHEN THE ROOT IS. `CaptureWAL` accepts a binding only
        /// when its root MATCHES the directory it was handed, and silently writes nothing when
        /// they disagree — so pairing an explicit root with the ambient account's binding is a
        /// capture that opens, appends every frame, and has no segments on disk. Left nil, the
        /// WAL derives the right binding for the root it was actually given.
        public init(baseDir: URL? = nil,
                    binding: CaptureAccountScope.AccountBinding? = nil,
                    log: DoorLog? = .shared) {
            if let baseDir {
                self.baseDir = baseDir
                self.binding = binding
            } else {
                let resolved = binding ?? CaptureAccountScope.currentAccountBinding()
                self.baseDir = resolved?.root ?? CaptureWAL.documentsCaptures()
                self.binding = resolved
            }
            self.log = log
        }
    }

    /// - Parameter attachment: injected so the Brine scenarios drive the SHIPPED attachment
    ///   over a faked radio rather than a faked attachment. A fresh attachment per pull is not
    ///   an optimisation to remove: `teardown()` retires the object's link and generation.
    /// - Parameter destination: the capture library the resulting conversation is written into.
    public static func run(
        peripheralIdentifier id: UUID,
        advertisedName: String,
        recording: PocketRecording,
        custody: any PocketRecorderFileCustody = PocketRecorderFileStore(),
        attachment: RecordingDeviceAttachment = RecordingDeviceAttachment(),
        destination: Destination = Destination()
    ) async -> PocketBringOverOutcome {
        // BEFORE THE RADIO IS TOUCHED. Refusing a file only after opening a session would
        // spend the owner's battery and the recorder's time to arrive at the same no.
        guard recording.sizeBytes <= maximumBytes else { return .unreadableRecording }

        let result = await attachment.withAuthenticatedSession(
            peripheralIdentifier: id, advertisedName: advertisedName
        ) { client, identity in
            await pull(client: client, identity: identity, advertisedName: advertisedName,
                       recording: recording, custody: custody, destination: destination)
        }
        switch result {
        case .ran(let outcome):
            return outcome
        case .unavailable(let attach):
            // THE ATTACH SEAM'S OWN SENTENCE, never a raw error. This panel is a read on a
            // recorder the account already remembers, so the same mapping the check earns is
            // the one that is true here.
            return .recorderUnavailable(
                PocketRecorderCheckPresentation.message(for: .unavailable(attach))
                    ?? PocketRecorderCheckPresentation.notThisRecorderLine)
        }
    }

    /// THE SAME SINK, REACHED WITHOUT THE RADIO — what a transport swap actually means.
    ///
    /// Bytes that arrived some other way (today: over the recorder's own WiFi, which is what
    /// `PocketFastSyncErrand` is) are kept by EXACTLY the steps a Bluetooth pull is kept by:
    /// the same `PocketRecorderFileCustody`, the same commit-by-re-read, the same
    /// `PocketCaptureImport`, the same conversation receipt, the same `PocketBringOverOutcome`
    /// vocabulary. There is no second ingest route and no `if fastSync` downstream of here —
    /// which is the property AC2 of the fast-sync track is about, and the reason this is a
    /// second entry point into one function rather than a second copy of it.
    ///
    /// It takes the whole payload as one `Data` because an HTTP body is one response; the BLE
    /// path streams because a radio hands over one notification at a time. That is the only
    /// difference, and it is the transport's, not custody's.
    public static func keep(payload: Data,
                            from identity: RecordingDeviceIdentity,
                            advertisedName: String,
                            recording: PocketRecording,
                            custody: any PocketRecorderFileCustody = PocketRecorderFileStore(),
                            destination: Destination = Destination()) async -> PocketBringOverOutcome {
        let key = PocketRecorderFileKey(identity: identity,
                                        date: recording.date,
                                        timestamp: recording.timestamp)
        if let held = await custody.heldFile(key), let existing = await custody.conversation(for: key) {
            _ = held
            return .alreadyHeld(captureID: existing)
        }
        let writer: any PocketRecorderFileWriting
        do { writer = try await custody.beginKeeping(key) }
        catch { return .transferIncomplete }
        let bytes: Int
        do {
            try writer.write(payload)
            bytes = try writer.commit()
        } catch {
            // NOTHING IS KEPT, and custody has already removed the partial. The recorder still
            // holds the only copy, which it always did.
            writer.abandon()
            return .transferIncomplete
        }
        guard let held = await custody.heldFile(key) else { return .transferIncomplete }
        return await conversation(from: held, key: key, bytes: bytes,
                                  deviceIdentity: identity,
                                  advertisedName: advertisedName,
                                  recording: recording, custody: custody,
                                  destination: destination)
    }

    private static func pull(client: PocketBLEClient,
                             identity: PocketAuthenticatedIdentity,
                             advertisedName: String,
                             recording: PocketRecording,
                             custody: any PocketRecorderFileCustody,
                             destination: Destination) async -> PocketBringOverOutcome {
        let deviceIdentity = identity.recordingDeviceIdentity
        let key = PocketRecorderFileKey(identity: deviceIdentity,
                                        date: recording.date,
                                        timestamp: recording.timestamp)
        // BEFORE ANY COMMAND IS ISSUED. Asking a recorder for hours of audio this phone is
        // already holding is the one avoidable cost in this whole leg.
        //
        // "HELD" AND "IS A CONVERSATION" ARE ASKED SEPARATELY. A phone that died between the
        // custody commit and the import holds the bytes and has no conversation; treating that
        // as "already done" would strand the recording forever. The retry costs no radio time —
        // the file is here — so it simply runs the import again off the held file.
        if let held = await custody.heldFile(key) {
            if let existing = await custody.conversation(for: key) {
                return .alreadyHeld(captureID: existing)
            }
            return await conversation(from: held, key: key, bytes: nil,
                                      deviceIdentity: deviceIdentity,
                                      advertisedName: advertisedName,
                                      recording: recording, custody: custody,
                                      destination: destination)
        }

        let writer: any PocketRecorderFileWriting
        do { writer = try await custody.beginKeeping(key) }
        catch { return .transferIncomplete }

        let bytes: Int
        do {
            // STREAMED STRAIGHT TO DISK. The radio hands over one notification at a time and
            // each one goes to the file; nothing accumulates, so a two-hour recording costs the
            // same memory as a two-second one.
            _ = try await client.download(recording.request, ceilingBytes: maximumBytes) { chunk in
                try writer.write(chunk)
            }
            bytes = try writer.commit()
        } catch let error as PocketProtocolError {
            writer.abandon()
            switch error {
            case .malformedResponse, .unsupportedOperation:
                // THE RECORDER ANSWERED AND THIS BUILD COULD NOT USE THE ANSWER: no `0xFF 0xF3`
                // sync anywhere, a size it did not state or exceeded, or a firmware without the
                // command.
                return .unreadableRecording
            case .timeout, .stall, .disconnected, .transportFailure, .cancelled:
                // IT STOPPED ARRIVING. There is no error frame for this on the wire — the
                // recorder simply goes quiet — so silence past the deadline IS the evidence.
                return .transferIncomplete
            case .unauthenticated, .busy, .malformedSecret, .authenticationRejected,
                 .unsupportedProtocol:
                return .recorderUnavailable(PocketRecorderCheckPresentation.keyUnusableLine)
            case .deletionNobodyChose:
                // UNREACHABLE FROM HERE AND NAMED ANYWAY. A bring-over composes no deletion —
                // that is the invariant `features/pocket-recorder-delete-consent.feature`
                // holds. If one ever appears on this path the gate refuses it, and the owner
                // is told the recording did not come over rather than being told a story about
                // their recorder: nothing was taken from it, which is the whole point.
                return .transferIncomplete
            }
        } catch {
            // THE BYTES ARRIVED AND THIS PHONE COULD NOT PROVE IT IS HOLDING THEM. Custody has
            // already removed whatever it wrote, so "nothing was kept" is a fact rather than a
            // hope, and the recorder still has the only copy — which it always did.
            writer.abandon()
            return .transferIncomplete
        }

        guard let held = await custody.heldFile(key) else { return .transferIncomplete }
        return await conversation(from: held, key: key, bytes: bytes,
                                  deviceIdentity: deviceIdentity,
                                  advertisedName: advertisedName,
                                  recording: recording, custody: custody,
                                  destination: destination)
    }

    /// THE HAND-OFF, AND THE END OF THIS FILE'S JOB. Past `PocketCaptureImport` the recording is
    /// a capture directory in the normal library with the normal birth stamps and the normal
    /// pending-finalize marker, and every function that touches it from here — drain, resync,
    /// finalize, ingest, transcription, titling — is the one every other recording runs.
    private static func conversation(from held: URL,
                                     key: PocketRecorderFileKey,
                                     bytes: Int?,
                                     deviceIdentity: RecordingDeviceIdentity,
                                     advertisedName: String,
                                     recording: PocketRecording,
                                     custody: any PocketRecorderFileCustody,
                                     destination: Destination) async -> PocketBringOverOutcome {
        let imported: PocketImportedCapture
        do {
            imported = try PocketCaptureImport.makeConversation(
                fromHeldFile: held,
                recorder: deviceIdentity,
                displayName: advertisedName,
                recorderReported: PocketRecordingLabel.reportedInstant(
                    date: recording.date, timestamp: recording.timestamp) ?? Date(),
                binding: destination.binding,
                baseDir: destination.baseDir,
                log: destination.log)
        } catch {
            // IT IS IN CUSTODY AND IT IS NOT AUDIO. The bytes stay — they are the owner's
            // recording and the only thing that makes a later retry free — but no conversation
            // is claimed, and the line says the recording could not be read.
            return .unreadableRecording
        }
        await custody.noteConversation(imported.captureID, for: key)
        // `resourceValues`, NEVER `attributesOfItem` — the latter is a whole-attribute stat that
        // has cost this app measured main-thread hangs, and reading the file back to count its
        // bytes would undo the entire reason nothing on this path is held in memory.
        let onDisk = (try? held.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return .broughtOver(bytes: bytes ?? onDisk, captureID: imported.captureID,
                            clockWarning: imported.clockWarning)
    }
}

#endif
