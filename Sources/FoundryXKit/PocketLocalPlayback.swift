// PocketLocalPlayback.swift — THE FIRST AUDIO THIS APP EVER KEPT, AND THE ROW THAT SAYS SO.
//
// THE CLAIM THIS FILE FALSIFIES, AND CORRECTS IN THE SAME CHANGE.
// `AudioPlaybackPresentation` opened with a sentence that was true for every recording this app
// had ever made:
//
//     "Audio is only ever kept on the operator's computer (and in the phone's in-memory replay
//      cache) — never persisted on the phone"
//
// A recording brought off a pocket recorder breaks it. `PocketRecorderFileStore` writes the
// recorder's own MP3 into the account-scoped `pocket-recordings` directory and NEVER removes it
// (`PocketBringOver.swift:31` — "IT ISSUES NO DELETE"), because that held file is the one thing
// that makes a failed import free to retry. So the bytes of a brought-over recording are sitting
// on the phone, whole, while `playAudio()` asks a computer for them over the network.
//
// WHAT THAT COSTS A PERSON. `DoorClient.captureAudio` reaches the operator's Mac. A recorder is
// the one capture source somebody carries precisely because no computer is nearby — a hike, a
// flight, another country. Routing its playback through the door means the recording a person is
// physically holding is unplayable exactly when they went to the trouble of carrying a recorder.
// Worse, the failure LIES: `AudioPlaybackPresentation.copy(for: .unreachable)` says "Can't reach
// your computer — your voice note audio lives there", about a file in this app's own container.
//
// THE LOOKUP IS AN INVERSION OF THE ONE AUTHORITY, NOT A SECOND INDEX. Custody already writes
// `<timestamp>.capture` beside `<timestamp>.mp3` holding the capture id that file became
// (`PocketRecorderFileStore.noteConversation`). Asking "which held file is this capture" is that
// same receipt read backwards. A separate captureID → path index would be a SECOND answer to the
// question custody already answers, and two answers to "where is this recording" is how one gets
// lost.
//
// WHAT IS DELIBERATELY NOT HERE — THE STANDING TRADE, NAMED. Listen and reclaiming the local MP3
// delete each other: the moment this file can play the held original, deleting the held original
// becomes a way to make a playable recording unplayable. Listen ships; reclamation does not, and
// `PocketLocalCopyPresentation.keptHereLine` says so ON THE ROW rather than leaving it as a
// silence somebody has to discover.

import Foundation
#if canImport(AVFoundation)
import AVFoundation
#endif

/// WHERE THE BYTES FOR ONE CONVERSATION ACTUALLY ARE. Two cases, because there are two places,
/// and the app had a vocabulary for only one of them.
public enum ConversationAudioSource: Equatable, Sendable {
    /// The recorder's own file, in this account's custody on this phone. Nothing is fetched.
    case heldOnThisPhone(URL)
    /// Every other recording: made here, uploaded, and served back by the door.
    case onTheComputer

    public var heldFile: URL? {
        if case .heldOnThisPhone(let url) = self { return url }
        return nil
    }
}

public enum PocketLocalPlayback {

    /// THE HELD ORIGINAL FOR A CAPTURE, or nil when this phone is not holding one.
    ///
    /// GATE INTEGRITY. This is a directory enumeration plus a small read per receipt — disk, and
    /// therefore a bug on the main actor for exactly the reason `CaptureRetention.isConfirmedInLore`
    /// is. The count is taken AT THE OPERATION (`CaptureManager.noteMainThreadDecode()`, a no-op
    /// off-main) so any future caller that drags it onto main trips the deterministic counter
    /// rather than only the callers somebody thought to look at.
    ///
    /// THE PREFIX IS A FAST NO AND NEVER A YES. `PocketCaptureImport.captureIdPrefix` is the only
    /// prefix a pulled recording is ever minted with, so a capture without it cannot be in pocket
    /// custody and is refused without touching the disk at all — that is what keeps a phone-mic
    /// conversation's Listen tap exactly as cheap as it was. It is not evidence in the other
    /// direction: a `pkt-` capture is only held if a receipt names it AND the audio beside that
    /// receipt exists.
    public static func heldFile(forCapture captureID: String, in root: URL) -> URL? {
        guard captureID.hasPrefix(PocketCaptureImport.captureIdPrefix) else { return nil }
        CaptureManager.noteMainThreadDecode()
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: root,
                                         includingPropertiesForKeys: nil,
                                         options: [.skipsHiddenFiles]) else { return nil }
        for case let receipt as URL in walker where receipt.pathExtension == "capture" {
            guard let data = try? Data(contentsOf: receipt),
                  let named = String(data: data, encoding: .utf8),
                  named == captureID else { continue }
            // THE RECEIPT IS NOT THE AUDIO. A receipt whose MP3 was never committed — or was
            // removed out from under us — is not a held recording, and claiming it is would
            // route playback at a file that is not there.
            let audio = receipt.deletingPathExtension().appendingPathExtension("mp3")
            return fm.fileExists(atPath: audio.path) ? audio : nil
        }
        return nil
    }

    /// WHERE PLAYBACK SHOULD GO. The one decision, in one place, so the view cannot hold a
    /// second opinion about it.
    ///
    /// - Parameter pocketRoot: injected for a hermetic suite. The default is the ACCOUNT-SCOPED
    ///   private store — the same one `PocketRecorderFileStore` writes into — because a held
    ///   recording is somebody's recording of a room they were in.
    public static func source(forCapture captureID: String,
                              pocketRoot: URL? = nil) -> ConversationAudioSource {
        let root = pocketRoot ?? CaptureAccountScope.privateURL(for: .pocketRecordings)
        guard let held = heldFile(forCapture: captureID, in: root) else { return .onTheComputer }
        return .heldOnThisPhone(held)
    }

    #if canImport(AVFoundation)
    /// A PLAYER OVER THE HELD FILE, or nil when this phone cannot decode what it is holding.
    ///
    /// The decoder is ASKED rather than assumed: a file that ends in `.mp3` because custody named
    /// it that is not proof it is audio, and the honest failure for a file we hold is "we could
    /// not play what is here", never "we could not reach your computer".
    public static func player(forHeldFile url: URL) -> AVAudioPlayer? {
        guard let player = try? AVAudioPlayer(contentsOf: url), player.duration > 0 else {
            return nil
        }
        return player
    }
    #endif

    /// THE THREE PLACES FOR ONE CONVERSATION, IN STEP 5'S VOCABULARY AND NOT A PARALLEL ONE.
    ///
    /// `PocketPresenceReader.presence` answers the same question keyed by the RECORDER's file
    /// key, which is what a shelf row has. A conversation row has a capture id and nothing else,
    /// so this is the same three readings assembled from the same predicate
    /// (`PocketDurability.durableElsewhere`) — not a second computation of "is this safe".
    ///
    /// - Parameter recorderListedAt: when a recorder's shelf last listed this recording, or nil.
    ///   A conversation row is not attached to a live recorder, so nil is the ordinary case and
    ///   it reads `unknown` — which is the truth: nobody asked the recorder.
    public static func presence(forCapture captureID: String,
                                heldFile: URL?,
                                recorderListedAt: Date?,
                                durability: (any PocketDurabilityEvidence)?,
                                askedAt: Date) -> PocketRecordingPresence {
        let onRecorder: PocketPlaceReading = recorderListedAt.map {
            PocketPlaceReading(answer: .yes, observedAt: $0)
        } ?? .neverAsked
        let onThisPhone = PocketPlaceReading(answer: heldFile == nil ? .no : .yes,
                                             observedAt: askedAt)
        guard durability != nil else {
            return PocketRecordingPresence(onRecorder: onRecorder,
                                           onThisPhone: onThisPhone,
                                           safeElsewhere: .neverAsked)
        }
        let safe = PocketDurability.durableElsewhere(captureID: captureID, evidence: durability)
        return PocketRecordingPresence(
            onRecorder: onRecorder,
            onThisPhone: onThisPhone,
            safeElsewhere: PocketPlaceReading(answer: safe ? .yes : .no, observedAt: askedAt))
    }
}

/// THE LINES A HELD RECORDING'S ROW RENDERS. In the kit like every other device string, because
/// `swift test` cannot compile `App/`.
public enum PocketLocalCopyPresentation {
    /// PLAYS WITHOUT A COMPUTER, said plainly, because the whole point of carrying a recorder is
    /// that no computer is nearby.
    public static let playsHereLine = "This plays from this iPhone — no computer needed."

    /// THE STANDING TRADE, ON THE SURFACE. Listen and reclaiming the local copy delete each
    /// other; Listen shipped and reclamation did not, so the row says what Solleva is keeping
    /// and what it cannot yet do about it. A missing capability that is stated is a decision; a
    /// missing capability that is silent is a bug somebody finds later.
    public static let keptHereLine =
        "Solleva keeps the recorder's original file on this iPhone. Freeing that space isn't "
        + "something Solleva can do yet."

    public static var everyLine: [String] { [playsHereLine, keptHereLine] }
}
