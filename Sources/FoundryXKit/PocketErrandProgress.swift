// PocketErrandProgress — WHICH RECORDING THE ERRAND IN FLIGHT IS ABOUT.
//
// WHAT NICK ASKED FOR, in his words: "if I could click on an individual recording and click
// bring over, it should show me the loading screen right there rather than taking me back to
// the home screen, and then if I do go back to the home screen, well, it is loading, it should
// show the loading spinner on the specific recording that I clicked to bring over not just at
// the top."
//
// WHY THE APP COULD NOT DO IT. The recorder page's model had ONE in-flight flag per kind of
// errand — `isChecking`, `isBringingOver`, `isRemoving` — and not one of them had a subject.
// The page knew a transfer was running and could not say which of nineteen recordings it was
// running for, so the only place a spinner could honestly go was the top of the page, and the
// sheet the owner tapped had to close itself and send them back there to see it. It is the
// same missing per-recording identity that made the rows inert: a list of things with no
// address is a list nothing can be said about.
//
// SO THE ERRAND CARRIES ITS SUBJECT, and every surface asks the SAME question of it — "is this
// about the recording I am drawing?" — rather than each one inventing an answer from a Bool.
// The decision lives here because `swift test` cannot compile `App/`: a rule written in a
// SwiftUI body is a rule nothing in this repository can hold.

import Foundation

/// THE ERRAND THAT IS RUNNING, AND WHAT IT IS ABOUT.
///
/// `recordingId` is the recorder's OWN name for the file — `<date>/<timestamp>` — the same
/// token the shelf row is addressed by and the same one `custody.commit` records. It is `nil`
/// for an errand about the whole recorder (reading the shelf), because pretending a check is
/// about a particular recording would put a spinner on a row for work that is not its own.
public struct PocketErrandInFlight: Sendable, Equatable {
    /// One of `PocketErrandCommand`'s subject tokens.
    public let subject: String
    /// The recording this errand is about, or `nil` when it is about the recorder itself.
    public let recordingId: String?

    public init(subject: String, recordingId: String? = nil) {
        self.subject = subject
        self.recordingId = recordingId
    }

    /// WHETHER THIS ERRAND IS ABOUT ONE RECORDING rather than about the recorder itself.
    ///
    /// A fact about the errand, not a second rule: `progress(_:for:)` folds a whole-recorder
    /// errand into `.elsewhere`, which is right for a ROW (an action taken while the shelf is
    /// being replaced would be taken against a listing on its way out) and wrong for the band
    /// above the list — the panel's headline already says "Checking the recorder…" while a
    /// check runs, and a band repeating it underneath is the same fact twice on one screen.
    public var isAboutOneRecording: Bool { recordingId != nil }
}

/// WHAT ONE RECORDING'S SURFACE SHOWS WHILE AN ERRAND IS IN FLIGHT.
///
/// Three states, not two, and the third is the one a Bool cannot express: the radio is busy
/// with something ELSE. A row that spins for another recording's transfer is a lie about where
/// the bytes are going, and a button that is simply greyed out with no sentence is the defect
/// this whole surface has been fixing all week.
public enum PocketErrandProgress: Sendable, Equatable {
    /// Nothing is running.
    case idle
    /// The errand in flight is about THIS recording. Draw a spinner and this line.
    case thisRecording(String)
    /// Something is running, and it is not about this recording. No spinner — this line.
    case elsewhere(String)

    /// Whether THIS recording is the one being worked on. The spinner's predicate.
    public var isThisRecording: Bool {
        if case .thisRecording = self { return true }
        return false
    }

    /// The sentence to draw, or `nil` when nothing is running.
    public var line: String? {
        switch self {
        case .idle: return nil
        case .thisRecording(let line), .elsewhere(let line): return line
        }
    }

    /// Whether an action on this recording can be taken right now. ONE RADIO, ONE ERRAND: the
    /// recorder page refuses a second session while any errand is running, so an enabled
    /// button would be a control whose tap is dropped in silence.
    public var blocksAnAction: Bool {
        if case .idle = self { return false }
        return true
    }
}

/// Every string this behaviour renders, in the kit, for the same reason every other device
/// string is.
public enum PocketErrandProgressPresentation {

    /// THE ONE QUESTION EVERY SURFACE ASKS. A shelf row asks it with its own id; the page about
    /// one recording asks it with the same token it was resolved from — so the two cannot
    /// disagree about which recording is moving.
    public static func progress(_ inFlight: PocketErrandInFlight?,
                                for fileToken: String) -> PocketErrandProgress {
        guard let inFlight else { return .idle }
        guard let recordingId = inFlight.recordingId else {
            // AN ERRAND ABOUT THE RECORDER ITSELF. It is not about this recording and it is not
            // nothing: while the shelf is being re-read every row's readings are being replaced,
            // so an action taken now would be taken against a listing that is on its way out.
            return .elsewhere(wholeRecorderLine(subject: inFlight.subject))
        }
        if recordingId == fileToken {
            return .thisRecording(thisRecordingLine(subject: inFlight.subject))
        }
        return .elsewhere(anotherRecordingLine(subject: inFlight.subject))
    }

    /// WHAT THE BAND ABOVE THE LIST SHOWS — the same question, minus the one answer the panel's
    /// headline already owns.
    ///
    /// THE BAND IS THE THIRD SURFACE and it was the last one left on a global Bool. Its spinner
    /// read `if check.isBringingOver`, which is true for ANY transfer, under a button that
    /// offers exactly one file (`PocketBringOver.offered`'s pick) — so asking for a different
    /// recording from that recording's own page made this band say "Bringing this recording
    /// over…" beneath a button about a file nothing was happening to. That is Nick's "not just
    /// at the top", in the place he was looking.
    ///
    /// WHY IT IS NOT JUST `progress(_:for:)`. A whole-recorder errand folds into `.elsewhere`,
    /// which is right for a ROW — while the shelf is being replaced an action would be taken
    /// against a listing on its way out — and wrong here: this band sits DIRECTLY BENEATH a
    /// headline that already says "Checking the recorder…" while a check runs, and repeating it
    /// is the same fact twice on one screen. So a check is `.idle` to this surface and to no
    /// other, which is a rule, so it lives here rather than as a second condition in a SwiftUI
    /// body that nothing in this repository can execute.
    public static func bandProgress(_ inFlight: PocketErrandInFlight?,
                                    for fileToken: String) -> PocketErrandProgress {
        guard inFlight?.isAboutOneRecording == true else { return .idle }
        return progress(inFlight, for: fileToken)
    }

    /// What is happening TO THIS RECORDING, named after the errand rather than after a generic
    /// "working". "Bringing this recording over…" and "Taking this recording off the recorder…"
    /// are different enough that somebody glancing at a row knows which one they asked for.
    public static func thisRecordingLine(subject: String) -> String {
        switch subject {
        case PocketErrandCommand.bringOverSubject: return PocketBringOverPresentation.inProgressLine
        case PocketErrandCommand.removalSubject:
            return PocketRemoveFromRecorderPresentation.inProgressLine
        case PocketErrandCommand.shelfSubject: return PocketRecorderCheckPresentation.checkingLine
        default: return busyWithThisRecorderLine
        }
    }

    /// The radio is on a DIFFERENT recording. It says which kind of work, and it says why this
    /// one is waiting — "one at a time" is the shape this surface actually has, and the panel's
    /// own note already says so.
    public static func anotherRecordingLine(subject: String) -> String {
        switch subject {
        case PocketErrandCommand.bringOverSubject:
            return "Solleva is bringing another recording over from this recorder. It can only "
                + "do one at a time."
        case PocketErrandCommand.removalSubject:
            return "Solleva is taking another recording off this recorder. It can only do one "
                + "at a time."
        default: return busyWithThisRecorderLine
        }
    }

    /// An errand about the recorder rather than about any one recording.
    public static func wholeRecorderLine(subject: String) -> String {
        subject == PocketErrandCommand.shelfSubject
            ? PocketRecorderCheckPresentation.checkingLine
            : busyWithThisRecorderLine
    }

    /// The fallback, and it promises nothing it cannot name. A subject this file does not know
    /// is still a busy radio, and saying so is honest; guessing which errand it is would not be.
    public static let busyWithThisRecorderLine =
        "Solleva is using this recorder right now. It can only do one thing at a time."

    /// THE POPULATION. Every line this behaviour can render, so a claim about its copy is held
    /// over the whole set rather than over whichever string a test author remembered.
    public static var everyLine: [String] {
        var lines = [busyWithThisRecorderLine]
        for subject in PocketErrandCommand.everySubject {
            lines.append(thisRecordingLine(subject: subject))
            lines.append(anotherRecordingLine(subject: subject))
            lines.append(wholeRecorderLine(subject: subject))
        }
        return lines
    }
}

extension PocketErrandCommand {
    /// THE THREE THINGS AN ERRAND CAN BE ABOUT, as a population.
    ///
    /// It lives beside the progress rules rather than beside the constants because it exists
    /// for them: a claim about "the line every errand renders" has to be held over the whole
    /// set, or it is a claim about whichever subject a test author remembered.
    public static var everySubject: [String] { [shelfSubject, bringOverSubject, removalSubject] }
}

extension PocketRecordingDetailAction {
    /// WHETHER THE PAGE ABOUT ONE RECORDING STAYS OPEN AFTER THE OWNER ASKS FOR THIS.
    ///
    /// NICK'S WORDS, and the defect they name: "if I could click on an individual recording and
    /// click bring over, it should show me the loading screen right there rather than taking me
    /// back to the home screen". The sheet closed itself the instant the transfer was asked
    /// for, on the reasoning that the page behind it already reported the errand — which was
    /// true and is the wrong trade: the owner asked HERE, and being sent back to a list to
    /// watch a global spinner is being told less than they knew a moment earlier.
    ///
    /// A REMOVAL IS DIFFERENT AND THE DIFFERENCE IS REAL. It ends with the recording gone from
    /// the recorder, so the page about it becomes a page about something that is not there —
    /// and this surface resolves that page live, which would leave the owner reading "Solleva
    /// can't act on that recording right now" as the reward for a deletion that worked.
    ///
    /// It is a rule rather than an `if` in a body because `swift test` cannot compile `App/`.
    public var leavesThePageOpen: Bool {
        switch self {
        case .bringItOver:        return true
        case .removeFromRecorder: return false
        }
    }
}
