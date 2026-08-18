// PocketRecordingDetail.swift — ONE RECORDING, AS A PAGE A PERSON CAN OPEN.
//
// THE DEFECT THIS EXISTS FOR, MEASURED ON NICK'S OWN RECORDER.
//
//   * THE SHELF ROW IS NOT A CONTROL. `RecordingDevicePageView`'s row is an `HStack` inside a
//     `VStack`, and the only interactive thing it has ever carried is `Remove it from the
//     recorder` — gated on `PocketRemoveFromRecorderPresentation.isOffered`, which is FALSE for
//     all nineteen of the recordings on `PKT01_BLUE_26079bc5` because not one of them has been
//     brought over. So on the one device this app was built for, not a single row on the page
//     has a single interactive element. A list of nineteen things none of which can be touched
//     is a readout, not a surface.
//   * THE OWNER CANNOT SAY "THAT ONE". `Bring over` takes `PocketBringOver.offeredNext`'s pick
//     — smallest first, minus what this phone holds. That is a good default and it is the ONLY
//     thing the owner can ask for. A person looking at the recording they made this morning has
//     no way to ask for the recording they made this morning.
//
// BOTH ARE THE SAME MISSING THING: there is nowhere in the app that is ABOUT one recording on a
// recorder. This is that place, as a value, so `swift test` can hold every word and every
// decision on it — `App/` does not compile in this package, and a rule written into a SwiftUI
// body is a rule no test in this repository can read.
//
// WHAT IT DOES NOT DO. It does not decide anything a shipped predicate already decides.
// Removal is `PocketRemoveFromRecorderPresentation.isOffered(for:)` — the same call the shelf
// row makes and the same one `PocketDeleteConsent`'s failable factory makes — so a detail page
// that offers the action and a consent that refuses it cannot disagree. The ceiling is
// `PocketBLEClient.maximumDownloadBytes`, the same constant `PocketBringOver.run` refuses
// against before it touches the radio.
//
// ONE DIVERGENCE, STATED RATHER THAN LEFT TO BE FOUND. Since 2026-08-18 this page applies that
// ceiling ONLY to a MEASURED byte count (`PocketRecordingExtent.bytes`), because the listing's
// fifth field is in a unit that has been measured and disproved — a listing of 4 was 19,770
// real bytes. `PocketBringOver.run` still pre-checks `recording.sizeBytes`, which is that same
// listing number times 1,024. So a recording with a listing over 262,144 is OFFERED here and
// would be refused there. On every device anybody has measured this is unreachable — the
// largest listing on `PKT01_BLUE_26079bc5` is 7,192 — and the transfer's own ceiling on the
// ANNOUNCED size is the check that means anything. The pre-check belongs to the transfer path
// and is left to whoever owns it; it is named here so it is a known divergence, not a surprise.

import Foundation

/// One labelled fact about one recording. `label` and `value` are separate because the label is
/// this app's word and the value is the recorder's, and a page that concatenated them would
/// make the recorder's own digits unsearchable.
public struct PocketRecordingDetailFact: Equatable, Sendable {
    public let label: String
    public let value: String
    public init(label: String, value: String) {
        self.label = label
        self.value = value
    }
}

/// WHAT A PERSON CAN DO WITH THIS ONE RECORDING FROM THIS PAGE.
///
/// A closed vocabulary rather than booleans on the page: a gate over "which actions does this
/// state offer" can then be written over the POPULATION (`allCases`) instead of over whichever
/// flag a test author remembered, which is the shape every other closed set in this file's
/// neighbourhood already uses.
public enum PocketRecordingDetailAction: String, Equatable, Sendable, CaseIterable {
    /// Ask the recorder for THIS file — not `offeredNext`'s pick.
    case bringItOver
    /// Take THIS file off the recorder. Offered only where the shelf row would offer it.
    case removeFromRecorder

    /// The button's words. Both come from the affordance that already owns them, so this page
    /// cannot invent a second spelling of a control that exists elsewhere on the same screen.
    public var title: String {
        switch self {
        case .bringItOver:        return PocketBringOverPresentation.actionTitle
        case .removeFromRecorder: return PocketRemoveFromRecorderPresentation.action
        }
    }

    /// Whether carrying it out destroys something. The view draws these differently, and
    /// "which one is destructive" is a fact about the action rather than about the drawing.
    public var isDestructive: Bool {
        switch self {
        case .bringItOver:        return false
        case .removeFromRecorder: return true
        }
    }
}

/// ONE RECORDING, EVERYTHING KNOWN ABOUT IT, AND EVERY ACTION IT ACTUALLY ADMITS.
public struct PocketRecordingDetailPage: Equatable, Sendable {
    /// The recorder's OWN name for this file, `<date>/<timestamp>`, carried verbatim. It is
    /// what a bring-over and a removal both put on the wire, and this firmware spells its
    /// timestamps two ways on one device — so nothing here re-derives it from a title.
    public let fileToken: String
    /// The heading: the recorder's reported instant, re-spaced and never re-interpreted.
    public let title: String
    /// What is actually known, each labelled. The long form, because there is one recording on
    /// this page and no list to get past — and SHORTER than it used to be: the `Size` row is
    /// gone, because it printed the listing's fifth field in a unit measured and disproved on
    /// 2026-08-18, and a `Length` row appears only once somebody has a real byte count.
    public let facts: [PocketRecordingDetailFact]
    /// The three places, one line each, each with its own age. NOT accompanied by
    /// `PocketPresencePresentation.label` — that summary is DERIVED from these three, and the
    /// shelf row's own gate ("no row states the same fact twice") exists because the page
    /// rendered both. One recording does not make the duplication acceptable.
    public let places: [PocketPlaceLine]
    /// What can be done, in a fixed order. Empty is a legitimate answer and is exactly the
    /// state all nineteen of Nick's recordings are in today.
    public let actions: [PocketRecordingDetailAction]
    /// WHY AN ACTION IS NOT HERE. One line per withheld action, in the same order
    /// `PocketRecordingDetailAction.allCases` is in.
    ///
    /// A greyed-out control for a state a person cannot reach from here is a puzzle; an absent
    /// control with no explanation is a mystery. The shipped rule for the shelf row was the
    /// first of those two — the predicate itself rather than a disabled button — and it left
    /// nineteen rows that say nothing about why they do nothing. This is the missing half.
    public let notes: [String]

    public init(fileToken: String,
                title: String,
                facts: [PocketRecordingDetailFact],
                places: [PocketPlaceLine],
                actions: [PocketRecordingDetailAction],
                notes: [String]) {
        self.fileToken = fileToken
        self.title = title
        self.facts = facts
        self.places = places
        self.actions = actions
        self.notes = notes
    }

    public func offers(_ action: PocketRecordingDetailAction) -> Bool {
        actions.contains(action)
    }

    /// NOTHING ON THIS PAGE IS SAID TWICE, ONE BAND APART.
    ///
    /// THE DEFECT THIS EXISTS FOR WAS PHOTOGRAPHED, not imagined. The first simulator run
    /// showed the page headed "2026-08-11 · 17:50" with "Recorded  2026-08-11 · 17:50" four
    /// lines beneath it — the same `PocketRecordingLabel.title` call rendered in two bands. It
    /// is the same defect the readings strip on the page above had, and the same one the shelf
    /// row had with its derived summary. It is not a rule anybody remembers; it is a rule that
    /// has to be checked.
    ///
    /// `false` when any labelled fact restates the heading, or when two facts share a label.
    public var factsNeverRepeatTheHeading: Bool {
        if facts.contains(where: { $0.value == title }) { return false }
        return Set(facts.map(\.label)).count == facts.count
    }
}

/// EVERY SENTENCE AND EVERY DECISION THIS PAGE MAKES.
public enum PocketRecordingDetailPresentation {

    // MARK: - The words

    /// The heading over the three places. It says "is", present tense, because every one of
    /// those three lines carries the age of its own answer directly underneath.
    public static let placesHeading = "Where this recording is"

    // `recordedLabel = "Recorded"` USED TO BE HERE, AND THE PHOTOGRAPH IS WHY IT IS NOT.
    //
    // The first simulator run of this page showed the heading "2026-08-11 · 17:50" and, four
    // lines under it, "Recorded    2026-08-11 · 17:50". One fact, twice, one band apart —
    // literally the same `PocketRecordingLabel.title` call rendered in both places. This page's
    // own feature file already names that defect on the band above ("A recorder does not state
    // its charge twice, one band apart"), and it took a picture to see it here.
    //
    // THE DATE STAYED AND THE LABEL WENT. A recording on a recorder has no name but its
    // instant, so the instant IS the heading, and `factsNeverRepeatTheHeading` holds it.
    /// "LENGTH", NOT "SIZE". A size in bytes is a fact about a file; how long the recording
    /// runs is the fact a person is actually after, and it is the one this app can now defend
    /// — 32 kbps CBR is 4,000 bytes/second, measured off the first two files that ever came
    /// off a Pocket. The row is only drawn when somebody has a real byte count.
    public static let lengthLabel = "Length"
    /// The wire identity, shown because it is what a person reads back to somebody when a
    /// transfer goes wrong, and because ONE device spells it two different ways.
    public static let recorderNameLabel = "The recorder calls it"

    public static let closeAction = "Done"

    /// The bring-over is withheld because the bytes are already here. NOT
    /// `PocketBringOverPresentation.alreadyHeldLine` — that sentence reports an action that was
    /// carried out and did nothing ("nothing was brought over again"), and nothing has been
    /// carried out here.
    public static let alreadyHereLine =
        "Solleva already has this recording, so there's nothing to bring over."

    /// The recorder is not holding it. Reachable on a page whose shelf reading is older than
    /// the removal that emptied it.
    public static let notOnTheRecorderLine =
        "The recorder isn't holding this recording."

    /// THE CEILING, SAID BEFORE THE RADIO IS OPENED RATHER THAN AFTER.
    /// `PocketBringOver.run` refuses a file over `PocketBLEClient.maximumDownloadBytes` before
    /// it touches the transport; a button that is certain to earn that refusal is a button that
    /// spends somebody's tap to be told no.
    public static let tooBigLine =
        "This recording is bigger than Solleva can bring over from the recorder."

    /// The whole population, so a claim about this page's copy is held over every line it can
    /// render rather than over whichever one a test author remembered. The lines it borrows
    /// are named by their owners, never re-spelled here.
    public static var everyLine: [String] {
        [placesHeading, lengthLabel, recorderNameLabel, closeAction,
         alreadyHereLine, notOnTheRecorderLine, tooBigLine]
            + PocketRecordingDetailAction.allCases.map(\.title)
            + PocketRecordingExtentPresentation.everyLine
    }

    // MARK: - Finding the one the finger landed on

    /// The recorder's own name for a file. One spelling, in the kit, because the app builds
    /// this token in four places and a fifth spelling of it is a fifth chance to ask a recorder
    /// to delete a different recording than the one under the finger.
    public static func fileToken(_ recording: PocketRecording) -> String {
        recording.date + "/" + recording.timestamp
    }

    /// WHICH LISTED RECORDING THIS ROW IS, AND THE READING IT WAS DRAWN FROM — resolved
    /// together or not at all.
    ///
    /// `nil` when the shelf cannot answer for this id: the token is not in the listing, or the
    /// readings are absent or shorter than the listing. That state is REACHABLE and is not
    /// theoretical — `shelfRecordings` is restated on every check while the readings are only
    /// restated on a check that reached the recorder, so one good check followed by one failed
    /// one leaves the page holding rows with no readings behind them. Returning `nil` is what
    /// lets the caller say so instead of pairing a row to somebody else's reading by index.
    public static func located(_ id: String,
                               among recordings: [PocketRecording],
                               presences: [PocketRecordingPresence]?)
        -> (recording: PocketRecording, presence: PocketRecordingPresence)? {
        guard let presences,
              let index = recordings.firstIndex(where: { fileToken($0) == id }),
              index < presences.count else { return nil }
        return (recordings[index], presences[index])
    }

    // MARK: - The page

    /// - Parameter brain: which brain is on. It changes only the REASON a removal is withheld:
    ///   on `.justMyPhone` there is no second place for a copy to go, so the honest sentence is
    ///   that one rather than "not confirmed yet", which implies waiting would help.
    /// - Parameter now: the instant the ages are rendered against, injected rather than read
    ///   off the clock inside, so a scenario states an age instead of racing one.
    /// - Parameter extent: how big this recording ACTUALLY is, when anybody has measured it.
    ///   The default is the honest one and is also the ordinary one: a recording that has
    ///   never been fetched has only a listing number, whose unit has been measured and
    ///   disproved (`PocketRecordingExtent`), so this page states no magnitude for it and says
    ///   so in a sentence instead.
    public static func page(for recording: PocketRecording,
                            presence: PocketRecordingPresence,
                            brain: BrainChoice,
                            extent: PocketRecordingExtent = .listedUnitUnresolved,
                            now: Date) -> PocketRecordingDetailPage {
        var actions: [PocketRecordingDetailAction] = []
        var notes: [String] = []

        // THE BRING-OVER. Additive, so it asks only that nothing KNOWN rules it out: the phone
        // already holding the bytes, the recorder answering that it does not have them, or a
        // file over the ceiling the transfer refuses before it opens a session.
        if let refusal = bringOverRefusal(for: presence, extent: extent) {
            notes.append(refusal)
        } else {
            actions.append(.bringItOver)
        }

        // THE REMOVAL. Destructive, so it asks for POSITIVE answers on both sides: the recorder
        // says it has this file, and the safety predicate every other destructive path in this
        // app reads says a copy is proven somewhere else. `unknown` satisfies neither.
        if let refusal = removalRefusal(for: presence, brain: brain) {
            notes.append(refusal)
        } else {
            actions.append(.removeFromRecorder)
        }

        // AND WHY THERE IS NO LENGTH, once, in words. A stated absence with no way out of it
        // is a shrug — the rule the readings strip already follows — and the way out is the
        // `Bring it over` button decided immediately above.
        if !extent.isMeasured {
            notes.append(PocketRecordingExtentPresentation.unknownUntilBroughtOverLine)
        }

        return PocketRecordingDetailPage(
            fileToken: fileToken(recording),
            title: PocketRecordingLabel.title(date: recording.date,
                                              timestamp: recording.timestamp),
            // THE LENGTH FACT IS OMITTED, NOT BLANKED, when nobody has measured this
            // recording. A `Length` row holding "—" or "Unknown" is the absence with a label
            // in front of it; the sentence in `notes` says the true thing instead, and names
            // the action on this same page that would settle it.
            facts: [
                PocketRecordingExtentPresentation.line(extent).map {
                    PocketRecordingDetailFact(label: lengthLabel, value: $0)
                },
                PocketRecordingDetailFact(label: recorderNameLabel,
                                          value: fileToken(recording)),
            ].compactMap { $0 },
            places: PocketPresencePresentation.lines(presence, now: now),
            actions: actions,
            notes: notes)
    }

    /// `nil` ⇒ the bring-over is offered.
    ///
    /// THE CEILING IS CHECKED AGAINST A MEASURED BYTE COUNT AND NOTHING ELSE. It used to be
    /// checked against `recording.sizeBytes`, which is the listing's fifth field scaled by
    /// 1,024 — a unit measured and disproved on 2026-08-18 — so "This recording is bigger than
    /// Solleva can bring over" was a claim about size derived from a number that is not a size.
    /// A recording nobody has measured is OFFERED, and the transfer's own ceiling on the
    /// announced byte count is what refuses it if it really is too big. Predicting a refusal
    /// from an unresolved unit is how a person is told no about a file that would have come
    /// over fine.
    public static func bringOverRefusal(for presence: PocketRecordingPresence,
                                        extent: PocketRecordingExtent) -> String? {
        if presence.onThisPhone.answer == .yes { return alreadyHereLine }
        if presence.onRecorder.answer == .no { return notOnTheRecorderLine }
        if let bytes = extent.byteCount, bytes > PocketBLEClient.maximumDownloadBytes {
            return tooBigLine
        }
        return nil
    }

    /// `nil` ⇒ the removal is offered. It reads `isOffered(for:)` rather than re-deriving the
    /// predicate, so this page and the shelf row cannot come to two different answers about
    /// whether one recording is safe to take off a recorder.
    public static func removalRefusal(for presence: PocketRecordingPresence,
                                      brain: BrainChoice) -> String? {
        if presence.onRecorder.answer != .yes { return notOnTheRecorderLine }
        if PocketRemoveFromRecorderPresentation.isOffered(for: presence) { return nil }
        switch brain {
        case .justMyPhone:
            return PocketRemoveFromRecorderPresentation.nowhereElseLine
        case .myComputer, .foundryCloud:
            return PocketRemoveFromRecorderPresentation.notProvenSafeLine
        }
    }
}
