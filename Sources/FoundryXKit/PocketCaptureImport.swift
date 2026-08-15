// PocketCaptureImport — THE HAND-OFF, and deliberately the least original file in this leg.
//
// Everything here is a call to something that already shipped. A brought-over recording becomes
// a conversation by being written into the SAME on-disk shape a phone-mic or Omi recording is
// written into — the same `CaptureWAL`, the same `seg-%012llu.opus` segments, the same
// `meta.json` / `card.json` birth stamps, the same `.capture-source` marker, the same device
// sidecar, the same `.needs-finalize` marker — and then left alone. `CaptureManager`'s existing
// drain uploads it and its existing `tryFinalize` finalizes it, because from that point there
// is nothing about it that is Pocket-shaped.
//
// THE PRECEDENT THIS COPIES, LINE FOR LINE. `OmiRestorationSpool` already does exactly this for
// a background BLE restoration: it writes "into the STANDARD capture-WAL layout (same dir, same
// segment files, same source marker + start stamps)" and states that "Upload/finalize stay
// owned by CaptureManager; the spool only makes bytes durable on the phone." And
// `CaptureManager.merge` already does the finish: pre-existing segments on disk, then
// `markNeedsFinalize` → `sync()` → `tryFinalize`, touching no FrameRouter, no `beginSession`,
// no Live Activity and no `active`. This file is those two halves joined for a file that came
// off a recorder instead of out of a ring buffer.
//
// WHAT IS NOT HERE, ON PURPOSE:
//   * No upload. No finalize. No door call of any kind. Those belong to CaptureManager and
//     writing a second one is the thing this whole design forbids.
//   * No `beginStreaming()`. That is the flag that makes a WAL a LIVE capture — it is what
//     `status.streaming` reports and what the drain treats as "still arriving". A file that
//     already existed before the phone was involved is not arriving.
//   * No branch on "is this Pocket" anywhere downstream. The origin travels as DATA — the
//     `.capture-source` marker and the device sidecar — which is what `RecordingDeviceShape
//     .filePull` and `CaptureDeviceSidecar.sourceMarker(for:)` were already written to carry.

import Foundation

/// What one import produced.
public struct PocketImportedCapture: Sendable, Equatable {
    public let captureID: String
    public let opusPackets: Int
    public let seconds: Double
    /// The instant the conversation is dated to, after clock-skew resolution.
    public let startedAt: UInt64
    /// The clock warning `PocketConversationClock` earned, if the recorder's time is suspect.
    public let clockWarning: String?
}

public enum PocketCaptureImport {

    /// The capture-id prefix for a recording that was PULLED rather than streamed. It is not
    /// `omi-`, because a capture id is the one piece of provenance that survives every re-ingest
    /// and relaunch, and calling this audio Omi audio would be a lie that never washes out.
    /// Registered in `CaptureLibrary.sourcePrefixes` so the library counts it as a note.
    public static let captureIdPrefix = "pkt-"

    /// Mint the capture id for a recorder-reported instant. Same `yyyyMMdd-HHmmss` UTC stamp
    /// every other capture id carries, so `CaptureIdTime.startedAt(fromCaptureId:)` — which
    /// matches any `<8 digits>-<6 digits>` run, whatever the prefix — recovers it unchanged.
    ///
    /// The stamp is the RECORDER'S time, not the moment of the pull. A conversation that
    /// happened on Tuesday belongs on Tuesday even if the phone collected it on Friday, and the
    /// capture id is the durable fallback the conversation list sorts by.
    public static func captureId(startedAt: UInt64,
                                 uniqueSuffix: String = String(UUID().uuidString.prefix(8)))
        -> String
    {
        "\(captureIdPrefix)\(CaptureIdTime.stamp(fromEpochUTC: startedAt))-\(uniqueSuffix)"
    }

    /// TURN A HELD FILE INTO A CAPTURE THE EXISTING PIPELINE OWNS.
    ///
    /// - Parameter file: the mp3 in account-scoped custody. It is read, never moved or removed —
    ///   the recorder's promise is that Solleva deletes nothing, and this phone's copy is the
    ///   thing that makes a failed import retryable without asking the radio again.
    /// - Parameter baseDir: the captures root. THE SAME ONE `CaptureManager` hydrates from, or
    ///   the conversation is written somewhere nothing will ever look.
    /// - Returns: the capture that now exists on disk, pending finalize.
    /// - Throws: `PocketTranslationFailure` when the file is not audio this build can read. The
    ///   capture directory is removed in that case, so a failed import leaves no half-note.
    @discardableResult
    public static func makeConversation(
        fromHeldFile file: URL,
        recorder identity: RecordingDeviceIdentity,
        displayName: String,
        recorderReported: Date,
        broughtOverAt: Date = Date(),
        lastClockSet: Date? = nil,
        binding: CaptureAccountScope.AccountBinding?,
        baseDir: URL,
        log: DoorLog? = .shared
    ) throws -> PocketImportedCapture {
        // THE SHIPPED CLOCK RULE, not a second one. `PocketConversationClock` already decides
        // what to do with a recorder whose clock is ahead of this phone or predates the moment
        // its clock was last set, and already carries the sentence that says so.
        let clock = PocketConversationClock.resolve(reported: recorderReported,
                                                   broughtOver: broughtOverAt,
                                                   lastClockSet: lastClockSet,
                                                   calendar: Calendar.current)
        let startedAt = UInt64(max(0, clock.timeline.timeIntervalSince1970))
        let captureID = captureId(startedAt: startedAt)
        let dir = baseDir.appendingPathComponent(captureID, isDirectory: true)

        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            throw PocketTranslationFailure.decodeFailed
        }

        // THE SAME DURABLE BIRTH STAMPS `beginSession` AND THE RESTORATION SPOOL WRITE. A
        // capture without them is a directory of audio, not a conversation.
        ConversationMetaStore.recordStart(captureId: captureID, baseDir: baseDir, at: startedAt)
        _ = ConversationCardStore.recordStart(captureId: captureID, baseDir: baseDir,
                                              startedAt: startedAt)
        // PROVENANCE AS DATA. `CaptureDeviceSidecar.sourceMarker(for:)` already maps
        // `.filePull` — the shape a stored-file recorder has — to its own marker value, and
        // `CaptureManager`'s resume-candidate scan already refuses to resume anything that is
        // not marked `omi`. So a pulled recording can never be adopted as a live conversation,
        // by shipped code, without this file asking for it.
        let marker = CaptureDeviceSidecar.sourceMarker(for: identity.shape)
        try? Data(marker.utf8).write(to: CaptureManager.sourceMarkerURL(captureID, baseDir: baseDir),
                                     options: [.atomic])
        // THE SAME DERIVATION `CaptureWAL` DOES FOR AN EXPLICIT ROOT. Reading the scope off an
        // absent binding would silently skip the device record — and a conversation with no
        // device record is one whose attribution can never be recovered, which is precisely
        // what `CaptureDeviceSidecar` exists to prevent.
        let owner = binding ?? CaptureAccountScope.binding(forExplicitRoot: baseDir)
        if let scope = owner?.scope {
            let context = CaptureDeviceContext(identity: identity,
                                               displayName: displayName,
                                               accountScope: scope)
            if !CaptureDeviceSidecar.write(context, captureId: captureID, baseDir: baseDir) {
                log?.error("pocket-import: capture \(captureID) opened but its device record "
                           + "could not be written")
            }
        }
        CaptureEventLog.append(.captureStarted, captureId: captureID,
                               payload: ["source": marker, "mode": "brought-over"],
                               baseDir: baseDir)

        // THE WAL — the production one, with the production segment encoding. A PLACEHOLDER
        // target, exactly as `OmiRestorationSpool` uses: this WAL is a WRITER. The upload is
        // driven by the `CaptureManager`-owned WAL for the same id once the manager adopts it,
        // which is the only thing holding the real bearer.
        let placeholder = DoorTarget(baseURL: URL(string: "http://127.0.0.1:0")!, bearer: "")
        let wal = CaptureWAL(captureId: captureID,
                             target: placeholder,
                             baseDir: baseDir,
                             binding: binding,
                             log: log)

        let translated: PocketTranslatedAudio
        do {
            translated = try PocketAudioTranslator.translate(fileAt: file) { packet in
                wal.appendFrame(packet)
            }
            wal.finish()   // flush the tail segment; NEVER `beginStreaming` — this is not live
        } catch {
            wal.finish()
            // NOTHING HALF-MADE SURVIVES. A directory with birth stamps and no audio is a
            // conversation card that will never say anything, and it would still be there
            // after a relaunch claiming to be a recording.
            try? FileManager.default.removeItem(at: dir)
            throw error
        }

        let seconds = translated.durationSeconds
        ConversationMetaStore.recordEnd(captureId: captureID, baseDir: baseDir,
                                        at: startedAt + UInt64(max(0, seconds.rounded())),
                                        location: nil)

        // THE MARKER THE EXISTING FINALIZE LANE READS. `CaptureManager.tryFinalize` gates on it
        // and on every segment being ACK'd; `retryPendingFinalizes` retries it forever. Written
        // through the shared helper rather than a fourth copy of the literal.
        CaptureManager.markNeedsFinalizeOnDisk(captureID, baseDir: baseDir)

        log?.info("pocket-import: capture \(captureID) written — \(translated.opusPackets) "
                  + "frames, \(String(format: "%.1f", seconds))s, pending finalize")
        return PocketImportedCapture(captureID: captureID,
                                     opusPackets: translated.opusPackets,
                                     seconds: seconds,
                                     startedAt: startedAt,
                                     clockWarning: clock.warning)
    }
}
