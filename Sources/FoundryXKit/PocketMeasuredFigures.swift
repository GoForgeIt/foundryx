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
        if case .planningGuess(let because, let closedBy) = support {
            return "\(because) Closed by: \(closedBy)"
        }
        return nil
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

    public enum Id {
        public static let battery = "recorder.battery"
        public static let firmware = "recorder.firmware"
        public static let freeSpace = "recorder.freeSpace"
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
            renderedBy: "RecordingDeviceReadingPresentation.freeSpace",
            describes: "how full the recorder is",
            // USED AND TOTAL, BOTH FROM THE DEVICE. Free is their difference; the capacity is
            // the recorder's own, never a size this app decided a Pocket has.
            support: .recorderSaidSo(artifact: verbProbeArtifact,
                                     frame: "MCU&SPA&058767&058992")),

        PocketFigure(
            id: Id.recordingSize,
            renderedBy: "StoredFileDevicePresentation.manifest",
            describes: "how big one recording on the shelf is",
            // The listing states kilobytes per file. That is the number, and it is the ONLY
            // number about a recording's extent that a Pocket has ever given us.
            support: .recorderSaidSo(artifact: verbProbeArtifact,
                                     frame: "MCU&F&2026-08-07&20260807153240&2648")),

        PocketFigure(
            id: Id.recordingDuration,
            renderedBy: "StoredFileDevicePresentation.manifest",
            describes: "how long one recording lasts",
            support: .planningGuess(
                because: """
                    A duration is not stated by any recorder. It was derived by dividing the \
                    stated kilobytes by 4,000 bytes/second — a constant that descends from a \
                    third-party decode of firmware 1.3.3 and from a fixture this repo encoded \
                    itself (ffmpeg + lame) to match that belief. No audio has ever been \
                    transferred off a Pocket: APP&U was refused at the 2026-08-16 bench because \
                    it ties up the owner's radio for minutes to hours.
                    """,
                closedBy: """
                    Pull one recording off PKT01_BLUE_26079bc5, decode it, and record the \
                    stated kilobytes against the decoded seconds.
                    """)),

        PocketFigure(
            id: Id.fastSyncSpeed,
            renderedBy: "PocketFastSyncPresentation.setup",
            describes: "how much quicker fast sync is",
            support: .planningGuess(
                because: """
                    Never timed, on either leg. BLE throughput was not measured at the \
                    2026-08-16 bench — no file was transferred and no MTU, connection interval \
                    or PHY was recorded — and the WiFi transfer was never performed at all, \
                    because the HTTP endpoint the device serves files from is recorded as \
                    UNCONFIRMED by pocket-libre upstream. The "~150x" figure behind the words \
                    is a flagged guess and always was.
                    """,
                closedBy: """
                    Time one identical recording over each leg on the same recorder and record \
                    bytes against elapsed seconds for both. E-WIFI-ENDPOINT closes first.
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

    /// May a shelf row say how long a recording lasts?
    ///
    /// Asked by `StoredFileDevicePresentation.manifest` on every row it draws, so re-admitting
    /// the figure is a one-line change HERE — where the reason it was withheld is written
    /// down — and never a quiet edit in a view.
    public static var shelfRowMayStateDuration: Bool {
        figure(Id.recordingDuration)?.isPrinted ?? false
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
