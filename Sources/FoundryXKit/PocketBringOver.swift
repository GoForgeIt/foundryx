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
// WHAT THIS DELIBERATELY DOES NOT DO, AND WHY IT IS NOT A HALF-BUILD.
//
//   * IT DOES NOT DECODE, ENCODE, UPLOAD, OR FINALIZE. No MP3 decoder, no Opus, no
//     `CaptureBackend.finalize`, no `PocketFinalizedCaptureSink`. A brought-over file is a file
//     this phone is now holding; turning it into a conversation is a different leg with a
//     different unproven half, and building it against an unspecified sink is exactly how the
//     unwired modules this file exists beside got written.
//   * IT NEVER TOUCHES LIVE CAPTURE. `features/pocket-durable-sync.feature` forbids a pull
//     reaching the FrameRouter, the capture WAL, a Live Activity, the recording pill or any
//     currently-recording state — because the file already existed on the recorder before the
//     phone was involved, and dressing that up as a recording is a lie about where the audio
//     came from. Nothing here imports any of them.
//   * IT ISSUES NO DELETE. `PocketRecorderCustodyPromise.text` is a promise, and a bring-over
//     is the one operation that would be tempted to break it. It is repeated on this panel.
//   * IT BRINGS ONE FILE. Not a backlog, not a queue, not a cadence — those are written
//     (`PocketDurableSync`, `PocketPresenceBackoff`) and still have no caller, and a scheduler
//     over a leg no human has ever watched finish is a bigger unwired module, not a smaller one.

import Foundation

/// Where a brought-over file lives and how custody is proven.
public protocol PocketRecorderFileCustody: Sendable {
    func alreadyHeld(_ key: PocketRecorderFileKey) async -> Bool
    /// Persist atomically, then prove custody by READING THE FILE BACK and comparing bytes.
    /// Must remove any partial artifact on failure. Returns the byte count it re-read.
    func keep(_ key: PocketRecorderFileKey, bytes: Data) async throws -> Int
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

    public func alreadyHeld(_ key: PocketRecorderFileKey) async -> Bool {
        FileManager.default.fileExists(atPath: url(for: key).path)
    }

    public func keep(_ key: PocketRecorderFileKey, bytes: Data) async throws -> Int {
        let destination = url(for: key)
        let partial = destination.appendingPathExtension("partial")
        do {
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: partial, options: .atomic)
        } catch {
            try? FileManager.default.removeItem(at: partial)
            throw PocketRecorderCustodyFailure.couldNotWrite
        }
        // THE PROOF, AND THE REASON THIS IS NOT JUST A WRITE. The bytes are read back off the
        // filesystem and compared to the ones the radio handed over.
        guard let reRead = try? Data(contentsOf: partial), reRead == bytes else {
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
        return reRead.count
    }
}

/// What one bring-over established.
public enum PocketBringOverOutcome: Sendable, Equatable {
    case broughtOver(bytes: Int)
    case alreadyHeld
    case transferIncomplete     // fewer bytes than announced / stall / disconnect
    case unreadableRecording    // no MP3 sync, or refused by the size ceiling
    case recorderUnavailable(String)   // carries a presentation line, never a raw error
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

    /// Every line this affordance can render, so a claim about it is held over the POPULATION
    /// rather than over whichever string a test author remembered.
    ///
    /// THERE IS NO NOTE OF ITS OWN HERE ON PURPOSE. The deletion promise this action is most
    /// tempted to break already has a renderer on the panel this action lives on —
    /// `PocketRecorderCheckPresentation.sectionNote` — and a second copy of it beside the
    /// button would be the same sentence twice on one screen.
    public static let everyLine: [String] = [
        actionTitle, inProgressLine, broughtOverLine, alreadyHeldLine,
        transferIncompleteLine, unreadableRecordingLine,
    ]

    /// The line an outcome earns. `.recorderUnavailable` carries its own, because the reason a
    /// session never opened is the attach seam's to state, not this file's to guess at.
    public static func message(for outcome: PocketBringOverOutcome) -> String {
        switch outcome {
        case .broughtOver:              return broughtOverLine
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

    /// THE CEILING, AND THE ARITHMETIC BEHIND IT. Pocket fw-1.6 lists bytes at a fixed 32 kbps
    /// CBR — 4,000 bytes per second, the same constant `StoredFileDevicePresentation.duration`
    /// divides by — so 32 MB is about 2.2 hours of audio. The shape here holds the payload AND
    /// the copy it re-reads to prove custody in memory at the same time, so peak footprint is
    /// roughly twice the file. A recorder left running for a weekend can be holding far more
    /// than that, and the honest answer to one of those files is a refusal, not an attempt that
    /// takes the app down partway through.
    public static let maximumBytes = 32 * 1024 * 1024

    /// THE ONE THE SHELF OFFERS: smallest first. Long files are hours over BLE, and the first
    /// file anybody ever pulls off a Pocket should be the one that finishes.
    ///
    /// The comparator is NOT re-implemented here: `PocketDurableSync.ordered(_:)` is the
    /// shipped backlog order (newest day first, shorter file breaks the tie) and a second
    /// spelling of it would drift from the one the sync path uses.
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

    /// - Parameter attachment: injected so the Brine scenarios drive the SHIPPED attachment
    ///   over a faked radio rather than a faked attachment. A fresh attachment per pull is not
    ///   an optimisation to remove: `teardown()` retires the object's link and generation.
    public static func run(
        peripheralIdentifier id: UUID,
        advertisedName: String,
        recording: PocketRecording,
        custody: any PocketRecorderFileCustody = PocketRecorderFileStore(),
        attachment: RecordingDeviceAttachment = RecordingDeviceAttachment()
    ) async -> PocketBringOverOutcome {
        // BEFORE THE RADIO IS TOUCHED. Refusing a file only after opening a session would
        // spend the owner's battery and the recorder's time to arrive at the same no.
        guard recording.sizeBytes <= maximumBytes else { return .unreadableRecording }

        let result = await attachment.withAuthenticatedSession(
            peripheralIdentifier: id, advertisedName: advertisedName
        ) { client, identity in
            await pull(client: client, identity: identity,
                       recording: recording, custody: custody)
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

    private static func pull(client: PocketBLEClient,
                             identity: PocketAuthenticatedIdentity,
                             recording: PocketRecording,
                             custody: any PocketRecorderFileCustody) async -> PocketBringOverOutcome {
        let key = PocketRecorderFileKey(identity: identity.recordingDeviceIdentity,
                                        date: recording.date,
                                        timestamp: recording.timestamp)
        // BEFORE ANY COMMAND IS ISSUED. Asking a recorder for hours of audio this phone is
        // already holding is the one avoidable cost in this whole leg.
        if await custody.alreadyHeld(key) { return .alreadyHeld }

        let payload: Data
        do {
            payload = try await client.download(recording.request)
        } catch let error as PocketProtocolError {
            switch error {
            case .malformedResponse, .unsupportedOperation:
                // THE RECORDER ANSWERED AND THIS BUILD COULD NOT USE THE ANSWER: no `0xFF 0xF3`
                // sync anywhere, a size it did not state, or a firmware without the command.
                return .unreadableRecording
            case .timeout, .stall, .disconnected, .transportFailure, .cancelled:
                // IT STOPPED ARRIVING. There is no error frame for this on the wire — the
                // recorder simply goes quiet — so silence past the deadline IS the evidence.
                return .transferIncomplete
            case .unauthenticated, .busy, .malformedSecret, .authenticationRejected,
                 .unsupportedProtocol:
                return .recorderUnavailable(PocketRecorderCheckPresentation.keyUnusableLine)
            }
        } catch {
            return .transferIncomplete
        }

        do {
            return .broughtOver(bytes: try await custody.keep(key, bytes: payload))
        } catch {
            // THE BYTES ARRIVED AND THIS PHONE COULD NOT PROVE IT IS HOLDING THEM. Custody has
            // already removed whatever it wrote, so "nothing was kept" is a fact rather than a
            // hope, and the recorder still has the only copy — which it always did.
            return .transferIncomplete
        }
    }
}

#endif
