// PocketMeasuredFigures — which numbers about a recorder Solleva is ALLOWED to print, and the
// frame a recorder actually sent that entitles it to.
//
// THE DEFECT THIS EXISTS FOR.
//
//   On 2026-08-16 a real Pocket went on the line for the first time in this program's life.
//   Everything printed about a recorder before that morning descended from ONE third-party
//   decode of firmware 1.3.3 — a firmware nobody here has ever run — and the app had no way to
//   tell a figure a recorder stated from a figure somebody assumed. So both shipped, side by
//   side, in the same type face:
//
//     1. `StoredFileDevicePresentation.duration` printed "44 min" on every shelf row by
//        dividing the recorder's stated kilobytes by 4,000 bytes/second. The recorder never
//        said 4,000. It came from the 1.3.3 decode, and was then "confirmed" by a fixture we
//        encoded OURSELVES with ffmpeg and lame to match the belief. No audio has ever come off
//        a Pocket — `APP&U` has still never been sent to one — so the divisor is a guess
//        wearing a measurement's clothes, and the row it produced was the most confident number
//        on the page.
//
//     2. `PocketFastSyncPresentation.setup.body` opened with "Much faster for long backlogs."
//        The WiFi transfer has never been performed. The endpoint the device serves files from
//        is recorded as UNCONFIRMED by pocket-libre upstream. The "~150×" behind that sentence
//        is a flagged planning guess that was never timed on either leg. `PocketFastSyncProgress`
//        already refused to print a rate without `measuredRate` — and then the offer sheet said
//        it in words, one screen earlier, where nothing was checking.
//
//   A guess and a measurement rendered identically is how a program stops being able to tell
//   which of its own numbers it can defend.
//
// THE SHAPE. Every figure this app can print about a recorder is registered here with the
// frame that entitles it — `MCU&SPA&058767&058992`, verbatim — or with the reason nobody has
// measured it. Production ASKS this registry before printing. A figure resting on a guess is
// WITHHELD, not softened: "about", "roughly" and "much faster" are the same guess with a hedge
// in front of it, and a hedge is not evidence.
//
// AND IT CARRIES ITS OWN WAY OUT. Each withheld figure states what would close it, because a
// prohibition nobody can discharge gets deleted by the next person who wants the number.
//
// WHAT IS DELIBERATELY NOT REGISTERED HERE: "read 20 minutes ago". That is this PHONE's clock
// measuring itself (`RecordingDeviceReadingPresentation.ago`), not a claim about a recorder.
// This registry governs claims about the DEVICE.
//
// AMENDMENT, 2026-08-18 — TWO ENTRIES CHANGED SIDES, AND ONE OF THEM WAS THE ANSWER TO THE
// OTHER'S "closed by".
//
//   Two files came off `PKT01_BLUE_26079bc5` — the first ever. `MCU&U&` announced 19,770 bytes
//   for a recording the listing called 4, and 185,078 for one it called 46.
//
//   * `recorder.recordingSize` WAS PRINTED and is now WITHHELD. Its support said "The listing
//     states kilobytes per file", which the pair above disproves twice over — as bytes the
//     listing is out by 4,943x then 4,023x, as kibibytes by 4.83x then 3.93x. A unit off by a
//     VARYING factor is not a unit, and the row was printing "4 KB" for a 19,770-byte file.
//   * `recorder.recordingDuration` WAS WITHHELD and is now PRINTED — but only over a real byte
//     count. Its old `closedBy` asked for exactly this: pull a recording and decode it. Both
//     files are MPEG-2 Layer III, 32 kbps, 16 kHz, mono (frame header 0xFFF348C4), and 32 kbps
//     CBR is 4,000 bytes/second. So the divisor that used to be a fabrication is measured; what
//     makes it honest is not the number but what it divides.
//   * `recorder.freeSpace` still prints, and prints a RATIO. `recorder.storageAmount` is new
//     and withheld: the storage frame's unit is no more resolved than the listing's.
//
//   The register worked. Both moves are one-line support changes, made beside the paragraph
//   saying what would justify them, which is what this file is for.

import Foundation

// MARK: - What entitles a figure to be printed

/// Why a figure is, or is not, allowed in front of a person.
public enum PocketFigureSupport: Sendable, Equatable {

    /// A recorder said it. `artifact` names the file under `evidence/pocket` that holds the
    /// exchange, and `frame` is the reply VERBATIM — the whole frame, never a prefix.
    ///
    /// THE WHOLE FRAME IS LOAD-BEARING. `MCU&D&ERR` shares a prefix with `MCU&DIRS`,
    /// `MCU&DIRS_SUM` and a delete success ack; a matcher on `"MCU&D"` matches all four, and
    /// one of the four means a recording is gone.
    case recorderSaidSo(artifact: String, frame: String)

    /// Nobody has measured it. `because` says why it is still open and `closedBy` says what
    /// would settle it — both required, so a withheld figure can never become a bare "no".
    case planningGuess(because: String, closedBy: String)

    /// WE MEASURED IT LOCALLY, ON HARDWARE, AND IT IS STILL NOT PRINTED.
    ///
    /// NAMED FOR THE WITHHOLDING, NOT FOR THE MEASURING — a cross-vendor review pointed out that
    /// a case called `weMeasured` reads as "approved", and the predictable failure is a future
    /// caller switching on it and rendering the value because *measured* sounds like *safe*. The
    /// name now carries the constraint rather than the provenance alone.
    ///
    /// The third state exists because the first two could not express a true thing: a figure the
    /// RECORDER never announced but which we established ourselves. Before this case a measured
    /// rate had to be filed as a `planningGuess` — a lie — or as `recorderSaidSo` with an invented
    /// frame, which is a worse lie and would have been caught by the frame gate.
    ///
    /// IT DOES NOT LICENSE PRINTING, and that is the point. `isPrinted` stays false for it, so
    /// the rule above survives intact: only something a recorder said about ITSELF, right now,
    /// goes in front of a person. A rate measured once, on one unit, at one distance, in one
    /// radio environment is sound enough to decide an architecture and not sound enough to put an
    /// ETA on somebody's screen — their conditions will differ. **Known and withheld are not a
    /// contradiction; conflating them is what put "~150×" in front of a person.**
    case locallyMeasuredButWithheld(artifact: String, method: String)
}

/// One figure this app can put in front of a person about a recorder.
public struct PocketFigure: Sendable, Equatable {

    /// Stable id. Used by production to ask about ITSELF, so a figure and its permission
    /// cannot drift apart the way a comment and its code do.
    public let id: String

    /// The production symbol that would print it. Named so this registry is auditable against
    /// the tree rather than believed.
    public let renderedBy: String

    /// What the figure is in the person's words — the thing the gate reports when it refuses.
    public let describes: String

    public let support: PocketFigureSupport

    /// Printed exactly when a recorder said it. There is no third state on purpose: a figure
    /// that is "printed with a caveat" is a printed figure.
    public var isPrinted: Bool {
        if case .recorderSaidSo = support { return true }
        return false
    }

    /// The reason a withheld figure is withheld, for the surface that has to explain itself.
    public var withheldBecause: String? {
        switch support {
        case .recorderSaidSo:
            return nil
        case .planningGuess(let because, let closedBy):
            return "\(because) Closed by: \(closedBy)"
        case .locallyMeasuredButWithheld(let artifact, let method):
            return "Measured, not announced by the recorder, so it is not printed: \(method) "
                + "See \(artifact)."
        }
    }
}

// MARK: - The register

public enum PocketMeasuredFigures {

    /// Where the observations live, relative to the repo root.
    public static let evidenceDirectory = "evidence/pocket"

    /// The recorder every frame below came off, and the firmware it was running. Both are
    /// required to appear in every artifact: a frame with no device and no firmware beside it
    /// is a screenshot of a number, not evidence.
    public static let benchDeviceIdentifier = "PKT01_BLUE_26079bc5"
    public static let benchFirmwareVersion = "1.6"

    /// The raw capture, kept byte-for-byte as the probe wrote it.
    public static let verbProbeArtifact = "PKT01_BLUE_26079bc5-fw1.6-20260816-verb-probe.json"

    /// The write-up — including the section naming everything that was NOT measured.
    public static let benchArtifact = "PKT01_BLUE_26079bc5-fw1.6-20260816-bench.md"

    /// The 2026-08-21 throughput measurement — two timed downloads, rate and setup separated.
    public static let bleThroughputArtifact =
        "PKT01_BLUE_26079bc5-fw1.6-20260821-ble-throughput.md"

    /// THE FIRST TWO FILES THAT EVER CAME OFF A POCKET, 2026-08-18. It is what entitles this
    /// app to state a LENGTH, and simultaneously what disqualifies the listing number from
    /// stating anything at all.
    public static let firstDownloadArtifact =
        "PKT01_BLUE_26079bc5-fw1.6-20260818-first-download.md"

    public enum Id {
        public static let battery = "recorder.battery"
        public static let firmware = "recorder.firmware"
        public static let freeSpace = "recorder.freeSpace"
        public static let storageAmount = "recorder.storageAmount"
        public static let recordingSize = "recorder.recordingSize"
        public static let recordingDuration = "recorder.recordingDuration"
        public static let fastSyncSpeed = "recorder.fastSyncSpeed"
        public static let deleteSpaceReclaimed = "recorder.deleteSpaceReclaimed"
    }

    public static let all: [PocketFigure] = [
        PocketFigure(
            id: Id.battery,
            renderedBy: "RecordingDeviceReadingPresentation.lines",
            describes: "how much charge the recorder has left",
            support: .recorderSaidSo(artifact: verbProbeArtifact, frame: "MCU&BAT&58")),

        PocketFigure(
            id: Id.firmware,
            renderedBy: "RecordingDeviceReadingPresentation.lines",
            describes: "which firmware the recorder runs",
            support: .recorderSaidSo(artifact: verbProbeArtifact, frame: "MCU&FW&1.6")),

        PocketFigure(
            id: Id.freeSpace,
            renderedBy: "RecordingDeviceReadingPresentation.storageFullness",
            describes: "how full the recorder is",
            // A RATIO, WHICH IS UNIT-FREE, AND THAT IS THE WHOLE REASON IT SURVIVES.
            // `MCU&SPA&<used>&<total>` states two numbers in a unit nobody has resolved — the
            // hardware is a 64 GB recorder and these figures are five digits — so used ÷ total
            // is every bit of this frame that can be defended, and it is also the thing a
            // person opens the page to find out. Rendering it as "225 KB free of 57.6 MB" is
            // what this app used to do, and it is wrong however the unit is eventually read.
            support: .recorderSaidSo(artifact: verbProbeArtifact,
                                     frame: "MCU&SPA&058767&058992")),

        PocketFigure(
            id: Id.storageAmount,
            renderedBy: "(nothing — withheld; the recorder's storage unit is unresolved)",
            describes: "how much room is left on the recorder, as an amount",
            support: .planningGuess(
                because: """
                    MCU&SPA&058767&058992 states used and total in a unit nobody has resolved. \
                    The sum of the 19 listed recordings matches that total, so the figure is \
                    internally consistent — but the listing's own unit is unresolved too, so \
                    the two agree with each other and with nothing measured. Rendered as \
                    kilobytes it reads "225 KB free of 57.6 MB" on a 64 GB recorder, which is \
                    wrong however it is read.
                    """,
                closedBy: """
                    Record a clip of a known byte length onto PKT01_BLUE_26079bc5, take \
                    APP&SPACE before and after, and record the delta against the bytes. \
                    Tracked upstream as O-STORAGE-UNIT.
                    """)),

        PocketFigure(
            id: Id.recordingSize,
            renderedBy: "(nothing — withheld; the listing's unit is unresolved)",
            describes: "how big one recording on the shelf is, before it has been fetched",
            // THIS FIGURE USED TO BE PRINTED, AND THE SUPPORT ABOVE IT USED TO SAY "the
            // listing states kilobytes per file". THAT IS REFUTED. Two files pulled on
            // 2026-08-18 announced 19,770 bytes against a listing of 4, and 185,078 bytes
            // against a listing of 46 — off by 4,943x then 4,023x read as bytes, 4.83x then
            // 3.93x read as kibibytes. A unit that is off by a VARYING factor is not a unit.
            support: .planningGuess(
                because: """
                    The fifth field of MCU&F&<date>&<stamp>&<n> is not bytes and is not \
                    kilobytes. Measured on PKT01_BLUE_26079bc5 fw1.6: listing 4 announced \
                    19,770 bytes and listing 46 announced 185,078 bytes, which is 4,943x then \
                    4,023x as bytes, and 4.83x then 3.93x as kibibytes. Both readings shipped \
                    at different times; a row printed "4 KB" for a 19,770-byte recording. A \
                    unit off by a varying factor is not a unit, so no size, ceiling, buffer, \
                    progress bar or duration may derive from this number.
                    """,
                closedBy: """
                    Pull a THIRD file from a different size band off PKT01_BLUE_26079bc5 and \
                    compare its listing number with its MCU&U& announcement. Two points fit \
                    many rules; the leading one is that the number is the DURATION IN SECONDS, \
                    since floor(19770/4000)=4 and floor(185078/4000)=46 both land exactly. \
                    Tracked upstream as O-LISTING-UNIT.
                    """)),

        PocketFigure(
            id: Id.recordingDuration,
            renderedBy: "PocketRecordingExtentPresentation.line",
            describes: "how long one recording lasts, once its true byte count is known",
            // MEASURED, AND ONLY FROM A REAL BYTE COUNT. `MCU&U&19770` is the size the
            // recorder announced for 2026-08-07/20260807142852, and 19,770 bytes arrived. The
            // file decodes as MPEG-2 Layer III, 32 kbps, 16 kHz, mono — frame header
            // 0xFFF348C4 — and 32 kbps CBR is exactly 4,000 bytes per second.
            //
            // THE DIVISOR IS THE SAME 4,000 THAT USED TO BE A FABRICATION. What changed is
            // what it divides: a byte count a recorder announced, or a file this phone holds,
            // instead of a listing number in an unresolved unit.
            support: .recorderSaidSo(artifact: firstDownloadArtifact, frame: "MCU&U&19770")),

        PocketFigure(
            id: Id.fastSyncSpeed,
            renderedBy: "(nothing — no surface prints a rate)",
            describes: "how fast a recording comes over Bluetooth",
            // MEASURED 2026-08-21, having been an open planning guess since the 2026-08-16
            // bench. Two downloads of different lengths through the reference client, wall-clock
            // timed, so rate and fixed session setup could be separated.
            //
            //     rate  = (185,078 - 19,770) / (11.308 - 4.281) = 23,524 B/s
            //     setup =  4.281 - 19,770 / 23,524              =  3.44 s
            //
            // A CORRECTION THAT MATTERS MORE THAN THE NUMBER. An earlier version of this comment
            // carried a third line calling `3.44 + 185,078/23,524 = 11.31s vs 11.31s measured` a
            // CHECK against a point the model did not come from. IT WAS CIRCULAR: a two-parameter
            // line fitted from two observations must reproduce both exactly, so that line could
            // not have failed. It is the defect family this file exists to police — a decision
            // derived from a check whose failure is impossible — written into the register
            // itself. A THIRD independently timed transfer is owed and is the only thing that
            // tests linearity; until it exists the linear model is an assumption.
            //
            // WHAT IT SUPPORTS: Pocket audio is 32 kbps CBR = 4,000 B/s of wall-clock recording,
            // so the link ran at 5.9x realtime OVER TWO SHORT TRANSFERS TOTALLING 205 KB. That is
            // enough to say the link is not obviously too slow to build a drain on. It is NOT
            // evidence that a drain keeps up in practice: nothing here tested sustained transfer,
            // degradation, throttling, retry, battery, distance or interference.
            //
            // AND IT REFUTES NEITHER PRIOR FIGURE, though an earlier version claimed both. The
            // "~3-4 KB/s" from a laptop session could be an honest observation under different
            // conditions rather than an error. The "18-36 KB/s" was about the WIFI leg and 23.5
            // lies INSIDE it — inapplicable as Bluetooth evidence and unvalidated, not refuted.
            support: .locallyMeasuredButWithheld(
                artifact: bleThroughputArtifact,
                method: """
                    Two complete downloads of different lengths over Bluetooth through the \
                    reference client, wall-clock timed around connect, bond, authenticate, \
                    select and transfer; rate and setup solved separately and the linear model \
                    checked against the point it was not derived from.
                    """)),

        PocketFigure(
            id: Id.deleteSpaceReclaimed,
            renderedBy: "(nothing — withheld before a surface could ask for it)",
            describes: "how much room deleting a recording gives back",
            support: .planningGuess(
                because: """
                    Probe P3 never ran. The 2026-08-16 bench issued only a sentinel delete that \
                    could not succeed (APP&D&1970-01-01&19700101000000 -> MCU&D&ERR), so nothing \
                    establishes whether APP&D reclaims space or merely unlinks. Delete may be \
                    offered as removing a recording; it may not be offered as freeing anything.
                    """,
                closedBy: """
                    Record a throwaway clip, take APP&SPACE, delete it, take APP&SPACE again, \
                    and record the delta.
                    """)),
    ]

    public static func figure(_ id: String) -> PocketFigure? {
        all.first { $0.id == id }
    }

    /// The figures a person may actually be shown. The paired-existence half of every
    /// prohibition over this register: "nothing unmeasured is printed" passes vacuously if
    /// nothing is printed at all.
    public static var printed: [PocketFigure] { all.filter(\.isPrinted) }

    /// The figures that are withheld, each still carrying why.
    public static var withheld: [PocketFigure] { all.filter { !$0.isPrinted } }

    // MARK: - What production asks

    /// May a surface say how long a recording lasts, GIVEN A REAL BYTE COUNT?
    ///
    /// Asked by `PocketRecordingExtentPresentation.line` on every extent it renders. The byte
    /// count is `MCU&U&<n>` or the length of the file this phone holds; the divisor is the
    /// measured 4,000 B/s. Nothing here permits a length derived from anything else.
    public static var mayStateLengthFromAMeasuredByteCount: Bool {
        figure(Id.recordingDuration)?.isPrinted ?? false
    }

    /// May ANY surface put a magnitude in front of a person that came out of the listing?
    ///
    /// This is the question the old `shelfRowMayStateDuration` should have been asking. A row
    /// used to answer "no duration" and then print "4 KB" — a different magnitude out of the
    /// same unresolved number, which is the same defect with a different unit stapled on. The
    /// register refuses the NUMBER, not one rendering of it.
    public static var mayStateAnExtentFromTheListing: Bool {
        figure(Id.recordingSize)?.isPrinted ?? false
    }

    /// May the readings strip say how full the recorder is? Asked by
    /// `RecordingDeviceReadingPresentation.storageFullness` every time it renders.
    public static var mayStateHowFullTheRecorderIs: Bool {
        figure(Id.freeSpace)?.isPrinted ?? false
    }

    /// May the storage line state an AMOUNT — kilobytes, megabytes, anything with a unit?
    /// The ratio is separately entitled by `Id.freeSpace`; this is the amount, and it is not.
    public static var storageMayStateAnAmount: Bool {
        figure(Id.storageAmount)?.isPrinted ?? false
    }

    /// May the fast-sync offer claim it is quicker — in a number or in words?
    public static var fastSyncOfferMayClaimSpeed: Bool {
        figure(Id.fastSyncSpeed)?.isPrinted ?? false
    }

    /// May any surface say that deleting a recording gives room back?
    public static var deleteMayClaimReclaimedSpace: Bool {
        figure(Id.deleteSpaceReclaimed)?.isPrinted ?? false
    }
}
