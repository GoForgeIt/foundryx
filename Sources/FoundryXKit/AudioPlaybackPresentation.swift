import Foundation

/// Pure presentation logic for in-app playback of a capture's door audio (the "Listen"
/// row and the speaker voice-sample row). Views own AVFoundation and the AVAudioSession;
/// THIS type owns the honesty decisions so scenarios can pin them as unit-backed steps:
///
///  1. Whether playback is disabled because a recording is active — and the copy for it.
///  2. How a fetch/playback error maps to an HONEST human outcome (never raw NSError
///     text): a pruned recording ("Audio no longer available") reads distinctly from an
///     offline computer ("Can't reach your computer").
///
/// WHERE THE AUDIO IS — CORRECTED. This type used to open with "audio is only ever kept on
/// the operator's computer (and in the phone's in-memory replay cache) — never persisted on
/// the phone". That was true of every recording this app made itself, and a recording brought
/// off a pocket recorder falsifies it: `PocketRecorderFileStore` writes the recorder's own MP3
/// into the account-scoped `pocket-recordings` directory and never removes it, because that
/// held file is what makes a failed import free to retry.
///
/// So there are now two homes, and `PocketLocalPlayback.source(forCapture:)` is the one place
/// that decides between them. A recording this phone made still lives on the computer and reads
/// exactly as it always did. A recording HELD HERE plays from here, with no computer involved —
/// and when it will not play, the reason must never be borrowed from the computer's vocabulary,
/// because blaming an unreachable Mac for a file in this app's own container is a lie a person
/// cannot act on.
public enum AudioPlaybackPresentation {

    /// Why playback isn't happening, in the user's terms.
    ///  • `unavailable` — the door returned 404 / no bytes: the recording was pruned on
    ///    the computer (recordings aren't kept there forever).
    ///  • `unreachable` — the door couldn't be reached at all (offline / computer asleep):
    ///    the audio lives on the computer, which we can't reach right now.
    ///  • `failed` — anything else (undecodable bytes, an unexpected server error).
    ///  • `heldButUnreadable` — the bytes are HERE, in this app's own container, and this phone
    ///    could not decode them. It exists so a recording on the phone can never be reported as
    ///    a computer that could not be reached: the computer was never asked, and telling
    ///    somebody to go wake their Mac would send them to fix a machine that is not involved.
    public enum Outcome: Equatable, Sendable {
        case unavailable
        case unreachable
        case failed
        case heldButUnreadable
    }

    /// The two-line copy for an outcome. `subtitle` is nil when a single line says it all.
    public struct Copy: Equatable, Sendable {
        public let title: String
        public let subtitle: String?
        public init(title: String, subtitle: String? = nil) {
            self.title = title
            self.subtitle = subtitle
        }
    }

    /// The honest reason playback is off while a recording is active — `nil` when it
    /// isn't (playback is allowed). Matches the app's plain, non-technical voice.
    public static func playbackDisabledReason(isRecording: Bool) -> String? {
        isRecording ? "Playback is off while you're taking a note" : nil
    }

    /// Map a fetch/playback error to an honest outcome. The audio-fetch path returns
    /// `nil` (not an error) for a 404, so views map the nil case to `.unavailable`
    /// directly; this covers the THROWN paths (`DoorError`, `URLError`) plus a safety
    /// mapping for a 404 that arrives as an error.
    public static func failurePresentation(for error: Error) -> Outcome {
        if let doorError = error as? DoorError {
            switch doorError {
            case .http(404):
                return .unavailable            // pruned on the computer
            case .transport:
                return .unreachable            // couldn't reach the door
            case .unauthorized, .http:
                return .failed
            }
        }
        if error is URLError {
            // Every URLError from an audio fetch is a connectivity story: the door lives
            // on the computer and we couldn't reach it. Read it as "unreachable", never
            // as a raw error string.
            return .unreachable
        }
        return .failed
    }

    // ── Whole-conversation player progress ──────────────────────────────────────
    // The "Listen" control plays the ENTIRE capture start-to-finish; while it plays it
    // shows how far in you are. These pure formatters pin the scrubber's elapsed readout
    // and fill so the SwiftUI row (which owns the AVAudioPlayer clock) can't drift.

    /// A compact "m:ss" clock label for one time value (an elapsed position or a total
    /// duration). NaN / negative / infinite inputs clamp to "0:00"; sub-second is floored.
    public static func clock(_ seconds: Double) -> String {
        let total = (seconds.isFinite && seconds > 0) ? Int(seconds) : 0
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// The whole-conversation player's elapsed readout — "elapsed / total"
    /// (e.g. "0:12 / 4:05"). The elapsed side never runs past the total.
    public static func elapsed(currentSeconds: Double, durationSeconds: Double) -> String {
        let dur = (durationSeconds.isFinite && durationSeconds > 0) ? durationSeconds : 0
        let cur = min(max(currentSeconds.isFinite ? currentSeconds : 0, 0), dur)
        return "\(clock(cur)) / \(clock(dur))"
    }

    /// The 0…1 fill for the scrubber. 0 when the duration is unknown/zero; clamped so a
    /// late clock tick past `duration` can't overshoot the track.
    public static func progressFraction(currentSeconds: Double, durationSeconds: Double) -> Double {
        let dur = (durationSeconds.isFinite && durationSeconds > 0) ? durationSeconds : 0
        guard dur > 0 else { return 0 }
        let cur = min(max(currentSeconds.isFinite ? currentSeconds : 0, 0), dur)
        return cur / dur
    }

    /// The copy for an outcome — the exact human lines the rows render.
    public static func copy(for outcome: Outcome) -> Copy {
        switch outcome {
        case .unavailable:
            return Copy(title: "Audio no longer available",
                        subtitle: "Voice note audio lives on your computer and isn't kept there forever.")
        case .unreachable:
            return Copy(title: "Can't reach your computer",
                        subtitle: "Your voice note audio lives there.")
        case .failed:
            return Copy(title: "Couldn't play this audio")
        case .heldButUnreadable:
            // NOT "your computer". This recording came off a recorder and its original file is
            // on this iPhone; the subtitle says where it is so the sentence is actionable
            // instead of pointing at a machine that was never asked.
            return Copy(title: "Couldn't play this recording",
                        subtitle: "Its file is on this iPhone, so your computer isn't needed.")
        }
    }

    /// Every human line this type can render, so a claim about it is held over the POPULATION
    /// rather than over whichever string a test author remembered — and so "the held-on-phone
    /// failure does not reuse the computer's sentence" is an assertion that cannot pass
    /// vacuously.
    public static var everyLine: [String] {
        [Outcome.unavailable, .unreachable, .failed, .heldButUnreadable].flatMap { outcome -> [String] in
            let c = copy(for: outcome)
            return [c.title, c.subtitle].compactMap { $0 }
        }
    }
}
