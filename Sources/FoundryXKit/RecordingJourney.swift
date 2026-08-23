// RecordingJourney — WHERE A RECORDING IS, SAID IN WORDS, AND NEVER AS A NUMBER
// NOBODY MEASURED.
//
// WHAT NICK ASKED FOR, in his words: "it would be good to be able to see status of loading to
// cell as well as how long it will be until it's transcribed? or if any ambient intelligence
// came from it? - some of this shows up on the capture page really nicely (progress for
// transcribing would be nice) and progress towards summary would be nice as well".
//
// THE CAPTURE PAGE ALREADY SHOWS POCKET RECORDINGS. The 2026-08-18 screenshot has the row —
// "Voice note", the chip `PKT01_BLUE_26079bc5`, Summary / Actions / Transcript, a "Check again"
// button. An earlier claim in this program that the Pocket-via-cell path "has no surface" was
// WRONG and was corrected. This file adds stages to a surface that exists; it does not build a
// second one.
//
// THE RULE THAT SHAPES EVERY TYPE BELOW, and it is not a caveat. THIS SURFACE HAS PRINTED AN
// INVENTED NUMBER THREE TIMES: 44-minute rows from an unmeasured divisor; kilobytes stored and
// read back as bytes; a "4 KB" label on a file of 19,770 bytes. Each time the number was
// arithmetically fine and the denominator was a guess. So a percentage is not a value this
// module can hold:
//
//   * `RecordingJourneyMeasure` HAS NO PERCENT CASE. A fraction can only be READ OFF
//     `.counted(done, of: total)`, and there is exactly one way to build that case —
//     `progress(done:total:)` — which refuses every total it is not given.
//   * A stage with no countable denominator therefore cannot render a bar. Not "should not":
//     cannot. The type does not spell it.
//
// WHY IT IS ALL HERE AND NOT IN A SWIFTUI BODY. `swift test` compiles the SPM package only; it
// cannot compile `App/`. A stage decided inside a view is a decision nothing in this repository
// can execute, which is exactly how the refuted privacy guards got where they were.

import Foundation

// MARK: - What may be drawn beside a stage

/// THE ONLY THREE THINGS THIS SURFACE MAY SAY ABOUT QUANTITY.
///
/// `.none` — a label and nothing else. `.tally(n)` — a count, which is a FACT: "79 parts sent"
/// is true whether or not anybody knows how many there will be. `.counted(done, of: total)` —
/// the only case a bar or a percentage may be drawn from, and the only one with a denominator
/// somebody measured.
///
/// THE ABSENT FOURTH CASE IS THE DESIGN. There is no `.percent(Double)` and no
/// `.indeterminate`, so "render a percentage from the received set alone" is not a mutation
/// this file can express — it has to go through `progress(done:total:)` and be refused there.
public enum RecordingJourneyMeasure: Sendable, Equatable {
    /// Nothing countable. Draw the sentence and stop.
    case none
    /// A count with NO total. Render it as a count. Never as a share of anything.
    case tally(Int)
    /// `done` of `total`, both measured. The only bar-bearing case.
    case counted(Int, of: Int)

    /// THE ONE DOOR INTO `.counted`, and the place every "no denominator" decision is made.
    ///
    /// WHAT THIS REFUSES, and why each refusal has a name in the ledger:
    ///   * `total == nil` — the door's `CaptureManifest`
    ///     (`crates/foundry-foundryx-surface/src/capture.rs:78-101`) carries `segments_received`,
    ///     `first_seq`, `last_seq` and `segment_seqs` and NO EXPECTED TOTAL, and `/segments`
    ///     (`gateway.rs:1950`) serves only what is stored. A percentage built there can read
    ///     100 % with segments still missing. That is the false-completion this refusal exists
    ///     for.
    ///   * `total <= 0` — "0 of 0" is not "we have not started", it is a division nobody should
    ///     make. An absent progress object and `{0, 0}` are different facts and must render
    ///     differently.
    ///   * `done > total` — the numerator and the denominator came from different places and at
    ///     least one of them is wrong. A bar past its end is a lie with a shape.
    ///
    /// In every refused case the answer is a TALLY: the numerator alone is still true.
    public static func progress(done: Int, total: Int?) -> RecordingJourneyMeasure {
        guard done >= 0 else { return .none }
        guard let total, total > 0, done <= total else { return .tally(done) }
        return .counted(done, of: total)
    }

    /// The share complete, or `nil` when there is nothing honest to compute. **A bar may be
    /// drawn if and only if this is non-nil.**
    public var fraction: Double? {
        guard case .counted(let done, let total) = self, total > 0, done >= 0, done <= total else {
            return nil
        }
        return Double(done) / Double(total)
    }

    /// Whether a progress bar may be drawn. One predicate, asked by every surface, so no view
    /// invents a second answer.
    public var drawsABar: Bool { fraction != nil }
}

// MARK: - The readings a stage can be built from

/// COMING OFF THE RECORDER. The announcement is the only honest denominator that exists on
/// this leg: `MCU&U&<bytes>` is the recorder's own count of what it is about to send. The
/// listing number is NOT bytes — two measured hardware pairs, listing `4` → 19,770 B and
/// listing `46` → 185,078 B — so nothing here may be sized from it.
public struct RecorderTransferReading: Sendable, Equatable {
    /// Bytes received from the recorder so far.
    public let bytesDelivered: Int
    /// Bytes the recorder ANNOUNCED it would send, or `nil` when no announcement was read.
    public let bytesAnnounced: Int?

    public init(bytesDelivered: Int, bytesAnnounced: Int?) {
        self.bytesDelivered = bytesDelivered
        self.bytesAnnounced = bytesAnnounced
    }
}

/// REACHING THE VAULT. `segmentsExpected` is what the PHONE holds for this capture — it is the
/// only party that knows both halves — and it must come from the per-destination confirmations
/// map, never from the global upload watermark, which was measured advancing on a self-ACK
/// (`CaptureWAL.swift:532`/`:718`). It is `nil` whenever that total is not available, and a
/// `nil` here is the reason this surface shows a count rather than a percentage.
public struct VaultUploadReading: Sendable, Equatable {
    /// Segments the destination has CONFIRMED. Not "sent"; confirmed.
    public let segmentsConfirmed: Int
    /// How many there are in total, from whoever actually knows. `nil` ⇒ count, no bar.
    public let segmentsExpected: Int?

    public init(segmentsConfirmed: Int, segmentsExpected: Int?) {
        self.segmentsConfirmed = segmentsConfirmed
        self.segmentsExpected = segmentsExpected
    }
}

/// TRANSCRIPTION, IN WINDOWS. One durable `transcribe_chunk` row per window the moment that
/// window succeeds (`migrations/052` + `068`; `audio_chunk.rs:42-46` — threshold 600 s, window
/// 180 s, so a ~60-minute recording is 20 countable windows).
///
/// **This reading is OPTIONAL wherever it appears, and the absence is the point.** A capture
/// with no rows must report NO progress object — not `{0, 0}` — or "we have not started" gets
/// drawn as "0 % of something".
public struct TranscribeWindowsReading: Sendable, Equatable {
    public let windowsDone: Int
    public let windowCount: Int

    public init(windowsDone: Int, windowCount: Int) {
        self.windowsDone = windowsDone
        self.windowCount = windowCount
    }
}

/// WHETHER THE SPEAKERS WERE TOLD APART, as FOUR states rather than a Bool or a spinner.
///
/// `.unavailable` IS NOT `.pending`, and conflating them is the specific failure this enum
/// exists to prevent. On a cloud-only Vault it will never happen at all: `kiln.rs:1068-1072`
/// requires per-speaker embeddings and `kiln.rs:850-852` records that cloud STT has none, and
/// the cell config declares no local target. A `pending` there is a bar that can never finish —
/// the same class of lie as "Transcribing locally" on a cell.
///
/// `.notEstablished` is the fourth, and it is the honest state for a reply that says nothing on
/// this seam: an empty `segments` array is ambiguous between "never diarized" and "not yet
/// forwarded", and there is no diarized field. A surface must be able to say NOTHING.
public enum SpeakerSeparation: String, Sendable, Equatable, CaseIterable {
    case notEstablished
    case unavailable
    case pending
    case done
}

/// WHETHER A NAME IS BEING MADE, from evidence rather than from the ABSENCE of a name.
///
/// As shipped, the door's `summarizing` is `transcribed && title.is_none()`
/// (`gateway.rs:2055-2064`) — the absence of a title, not work in flight. It read `true` for
/// four days on a capture that could never be titled. A capture that cannot be titled must not
/// report work in flight, so "no title yet" and "titling is running" are different cases here.
public enum NamingState: String, Sendable, Equatable, CaseIterable {
    /// The seam reports nothing. Say nothing.
    case notEstablished
    /// There is no transcript yet, so there is nothing to name from.
    case waitingForTranscript
    /// A titling run is claimed/running — evidence, not an inference from a NULL.
    case inFlight
    /// A name exists.
    case done
}

/// WHETHER ANYTHING CAME OUT OF IT — Nick's "if any ambient intelligence came from it".
///
/// FOUR CASES AND THEY ARE NOT INTERCHANGEABLE. "Never read" and "read, found nothing" are
/// different facts about a recording and telling a person the second when the first is true is
/// a claim the system did work it never did. `.notEstablished` is the honest state today:
/// `conversation_processing` fires at drainer-complete, is marker-guarded, and swallows its
/// failures to stderr — nothing exposes per-capture run state, so the surface shows NOTHING
/// rather than a reassuring zero.
public enum RecordingIntelligence: Sendable, Equatable {
    case notEstablished
    case neverRun
    case ranFoundNothing
    case ranFound(Int)

    /// THE NAMED TOKEN, asserted before any sentence is.
    ///
    /// Distinctness of two strings proves they differ; it does not stop them being SWAPPED,
    /// which would tell a person a recording was read and found nothing when it was never read
    /// at all. The token is what a test pins so a swap is caught by identity rather than by
    /// inequality.
    public var token: String {
        switch self {
        case .notEstablished: return "notEstablished"
        case .neverRun: return "neverRun"
        case .ranFoundNothing: return "ranFoundNothing"
        case .ranFound: return "ranFoundN"
        }
    }

    /// THE POPULATION, so a claim about this behaviour is held over every case rather than over
    /// whichever two an author remembered.
    public static var everyState: [RecordingIntelligence] {
        [.notEstablished, .neverRun, .ranFoundNothing, .ranFound(3)]
    }
}

/// HOW FAR THE TRANSCRIPT ITSELF IS. `.inProgress` carries the window reading OPTIONALLY,
/// because a transcription with no countable windows is the ordinary case for a recording under
/// the 600 s threshold — it is transcribed whole, and there is nothing to count.
public enum TranscriptReadiness: Sendable, Equatable {
    case notStarted
    case inProgress(TranscribeWindowsReading?)
    case done
    /// Terminal failure, with Lore's drop reason when it gave one.
    case failed(String?)
}

// MARK: - The reading

/// EVERYTHING THIS SURFACE KNOWS ABOUT ONE RECORDING'S JOURNEY, with every unmeasured thing
/// spelled as an absence rather than as a zero.
public struct RecordingJourneyReading: Sendable, Equatable {
    /// Still coming off the recorder. `nil` once it is off, or when it never came off one.
    public var offTheRecorder: RecorderTransferReading?
    /// On its way to the Vault. `nil` when the phone has nothing to say about the upload.
    public var toTheVault: VaultUploadReading?
    public var transcript: TranscriptReadiness
    public var speakers: SpeakerSeparation
    public var naming: NamingState
    public var intelligence: RecordingIntelligence

    public init(offTheRecorder: RecorderTransferReading? = nil,
                toTheVault: VaultUploadReading? = nil,
                transcript: TranscriptReadiness = .notStarted,
                speakers: SpeakerSeparation = .notEstablished,
                naming: NamingState = .notEstablished,
                intelligence: RecordingIntelligence = .notEstablished) {
        self.offTheRecorder = offTheRecorder
        self.toTheVault = toTheVault
        self.transcript = transcript
        self.speakers = speakers
        self.naming = naming
        self.intelligence = intelligence
    }

    /// THE READING THE DOOR'S OWN `/status` REPLY SUPPORTS **TODAY**, and it is deliberately
    /// thin.
    ///
    /// `CaptureStatusResponse` (`DoorClient.swift:203`) carries `stage`, `lore_capture_id`,
    /// `transcribed`, `title`, `summary` and `droppedReason`. It carries NO window progress, NO
    /// diarization state and NO per-capture intelligence run — so this function returns
    /// `.notEstablished` for all three, and the ladder says nothing about them. When the door
    /// grows those fields, THIS function changes and every rendering follows; a view that had
    /// guessed would not have.
    ///
    /// `naming` is derived from evidence available here and NOT from `summarizing`: a title that
    /// exists is `.done`; no transcript yet is `.waitingForTranscript`; a transcript with no
    /// title is `.notEstablished` — **not** `.inFlight`, because the absence of a title is not
    /// evidence that anything is running. That is the four-day `summarizing: true` defect, and
    /// refusing to reproduce it is the whole point of the state being named rather than inferred.
    public static func fromStatus(_ status: CaptureStatusResponse,
                                  vault: VaultUploadReading? = nil,
                                  offTheRecorder: RecorderTransferReading? = nil) -> Self {
        // ⚠ THIS DELEGATES, AND IT DID NOT USED TO. READ THIS BEFORE RE-INLINING IT.
        //
        // There were TWO derivations of a reading from a `/status` response, and they were not the
        // same function:
        //
        //   * `CaptureStatusPoller.journey(…)` — what the PHONE runs (`CaptureStatusPoller:480`).
        //   * this one — **zero production callers**, and the one `RecordingJourneyFeatureTests`
        //     grades.
        //
        // MEASURED 2026-08-23 over 252 status shapes: they disagreed on **186** of them — 108 on
        // `naming`, 78 on `transcript` — across EVERY stage. So this track's headline assertions,
        // including "a transcribed untitled capture does not claim naming is running", were being
        // proven about a function the phone never calls.
        //
        // One disagreement was a real lie, and it lived HERE: on a FAILED capture this function
        // returned `naming = .waitingForTranscript` — telling a person the name is pending on a
        // recording that was dropped and will never have one. The poller returns
        // `.notEstablished`, which is right.
        //
        // Rather than fix the copy and leave two copies, the shared fields now come from the ONE
        // function the phone runs. Drift is no longer something a test must notice; it is
        // impossible by construction. What remains here is the part `journey` does not model — the
        // vault and recorder readings, which no production caller supplies today (see this track's
        // AC8 blocker).
        let shared = CaptureStatusPoller.journey(
            stage: CaptureLifecycleStage(wire: status.stage),
            transcribed: status.transcribed,
            title: status.title,
            droppedReason: status.droppedReason,
            transcribeWindows: status.transcribeWindows)

        return Self(offTheRecorder: offTheRecorder,
                    toTheVault: vault,
                    transcript: shared.transcript,
                    speakers: shared.speakers,
                    naming: shared.naming,
                    intelligence: shared.intelligence)
    }
}

// MARK: - The ladder

/// THE STAGES, IN ORDER. `CaseIterable` so a claim about "every stage" is held over the whole
/// set, and every `switch` over it below is written WITHOUT a `default`, so a stage added here
/// without a rendering is a COMPILE FAILURE rather than a blank line on somebody's screen.
public enum RecordingJourneyStage: String, Sendable, Equatable, CaseIterable {
    case comingOffTheRecorder
    case reachingTheVault
    case transcribing
    case separatingSpeakers
    case naming
    case readingForActions
}

/// HOW A STAGE STANDS. `.cannotHappen` is the case a three-state ladder does not have, and it
/// is the one the cloud-only Vault needs: a thing that will never occur is not pending.
public enum RecordingJourneyState: String, Sendable, Equatable, CaseIterable {
    case waiting
    case working
    case done
    case cannotHappen
    case failed
}

/// ONE LINE OF THE LADDER.
public struct RecordingJourneyRow: Sendable, Equatable {
    public let stage: RecordingJourneyStage
    public let state: RecordingJourneyState
    public let line: String
    public let measure: RecordingJourneyMeasure

    public init(stage: RecordingJourneyStage,
                state: RecordingJourneyState,
                line: String,
                measure: RecordingJourneyMeasure) {
        self.stage = stage
        self.state = state
        self.line = line
        self.measure = measure
    }

    /// A bar may be drawn on this row if and only if this is true. Asked once, here.
    public var drawsABar: Bool { measure.drawsABar }
}

/// Every string and every decision this ladder renders.
public enum RecordingJourneyPresentation {

    /// THE ROWS WORTH DRAWING, in stage order. A stage the reading says NOTHING about produces
    /// no row at all — Nick asked to know whether ambient intelligence came out of a recording,
    /// and the honest answers are "N actions", "none found" and "not read"; a fourth answer,
    /// "nobody has wired this up yet", is not a row, it is silence.
    public static func ladder(_ reading: RecordingJourneyReading) -> [RecordingJourneyRow] {
        RecordingJourneyStage.allCases.compactMap { row(for: $0, reading: reading) }
    }

    /// ONE STAGE, ASKED OF ONE READING. `nil` means "this reading says nothing here".
    ///
    /// The `switch` has no `default` on purpose: adding a stage without answering for it does
    /// not compile.
    public static func row(for stage: RecordingJourneyStage,
                           reading: RecordingJourneyReading) -> RecordingJourneyRow? {
        switch stage {
        case .comingOffTheRecorder:
            guard let transfer = reading.offTheRecorder else { return nil }
            return RecordingJourneyRow(
                stage: stage,
                state: .working,
                line: comingOffTheRecorderLine,
                measure: .progress(done: transfer.bytesDelivered,
                                   total: transfer.bytesAnnounced))
        case .reachingTheVault:
            guard let upload = reading.toTheVault else { return nil }
            let measure = RecordingJourneyMeasure.progress(done: upload.segmentsConfirmed,
                                                           total: upload.segmentsExpected)
            let finished = upload.segmentsExpected.map { upload.segmentsConfirmed >= $0 } ?? false
            return RecordingJourneyRow(
                stage: stage,
                state: finished ? .done : .working,
                line: finished ? reachedTheVaultLine : reachingTheVaultLine,
                measure: finished ? .none : measure)
        case .transcribing:
            switch reading.transcript {
            case .notStarted:
                return RecordingJourneyRow(stage: stage, state: .waiting,
                                           line: transcriptNotStartedLine, measure: .none)
            case .inProgress(let windows):
                guard let windows else {
                    return RecordingJourneyRow(stage: stage, state: .working,
                                               line: transcribingLine, measure: .none)
                }
                return RecordingJourneyRow(
                    stage: stage, state: .working,
                    line: transcribingInPartsLine(done: windows.windowsDone,
                                                  total: windows.windowCount),
                    measure: .progress(done: windows.windowsDone, total: windows.windowCount))
            case .done:
                return RecordingJourneyRow(stage: stage, state: .done,
                                           line: transcribedLine, measure: .none)
            case .failed(let reason):
                return RecordingJourneyRow(stage: stage, state: .failed,
                                           line: transcriptFailedLine(reason: reason),
                                           measure: .none)
            }
        case .separatingSpeakers:
            switch reading.speakers {
            case .notEstablished: return nil
            case .unavailable:
                return RecordingJourneyRow(stage: stage, state: .cannotHappen,
                                           line: speakersNotSeparatedLine, measure: .none)
            case .pending:
                return RecordingJourneyRow(stage: stage, state: .working,
                                           line: separatingSpeakersLine, measure: .none)
            case .done:
                return RecordingJourneyRow(stage: stage, state: .done,
                                           line: speakersSeparatedLine, measure: .none)
            }
        case .naming:
            switch reading.naming {
            case .notEstablished: return nil
            case .waitingForTranscript:
                return RecordingJourneyRow(stage: stage, state: .waiting,
                                           line: namingWaitsForTranscriptLine, measure: .none)
            case .inFlight:
                return RecordingJourneyRow(stage: stage, state: .working,
                                           line: namingInFlightLine, measure: .none)
            case .done:
                return RecordingJourneyRow(stage: stage, state: .done,
                                           line: namedLine, measure: .none)
            }
        case .readingForActions:
            switch reading.intelligence {
            case .notEstablished: return nil
            case .neverRun:
                return RecordingJourneyRow(stage: stage, state: .waiting,
                                           line: neverReadForActionsLine, measure: .none)
            case .ranFoundNothing:
                return RecordingJourneyRow(stage: stage, state: .done,
                                           line: readAndFoundNothingLine, measure: .none)
            case .ranFound(let count):
                return RecordingJourneyRow(stage: stage, state: .done,
                                           line: readAndFoundLine(count: count), measure: .none)
            }
        }
    }

    // MARK: - the words

    public static let comingOffTheRecorderLine = "Coming off the recorder"
    public static let reachingTheVaultLine = "On its way to your Vault"
    public static let reachedTheVaultLine = "In your Vault"
    public static let transcriptNotStartedLine = "Not transcribed yet"
    public static let transcribingLine = "Being transcribed"
    public static let transcribedLine = "Transcribed"

    /// **THE PARTS ARE PARTS, NOT MINUTES.** Nick asked "how long will it be until it's
    /// transcribed"; the durable unit is a 180-second window, and the number of windows left
    /// says how much AUDIO remains, not how much TIME. Turning windows into a clock needs a
    /// rate nobody measures, which is the same unmeasured divisor that put 44-minute rows on
    /// this surface. So the sentence counts parts and promises no minutes.
    public static func transcribingInPartsLine(done: Int, total: Int) -> String {
        "Being transcribed — \(done) of \(total) parts done"
    }

    public static func transcriptFailedLine(reason: String?) -> String {
        ConversationProgress.failureMessage(droppedReason: reason)
            ?? "Couldn't be transcribed"
    }

    /// THE SENTENCE AC3 IS ABOUT. It is a statement of fact in the past tense, because on a
    /// cloud-only Vault this is over — there is nothing to wait for and nothing to draw.
    public static let speakersNotSeparatedLine = "Speakers weren't separated"
    public static let separatingSpeakersLine = "Telling the speakers apart"
    public static let speakersSeparatedLine = "Speakers told apart"

    public static let namingWaitsForTranscriptLine = "Waiting for the transcript before naming it"
    public static let namingInFlightLine = "Working out what to call it"
    public static let namedLine = "Named and summarised"

    /// "Never read" and "read, found nothing" — the two sentences AC5 forbids collapsing OR
    /// swapping. They are asserted by TOKEN first (`RecordingIntelligence.token`) so a swap is
    /// caught by identity; distinctness alone would pass a swap.
    public static let neverReadForActionsLine = "Not read for actions yet"
    public static let readAndFoundNothingLine = "Read for actions — none found"

    public static func readAndFoundLine(count: Int) -> String {
        count == 1 ? "1 action found" : "\(count) actions found"
    }

    /// THE POPULATION OF EVERY LINE THIS LADDER CAN RENDER. A claim about this copy — that no
    /// SwiftUI body spells any of it, that none of it says "locally" on a Vault — is held over
    /// the whole set rather than over whichever string a test author remembered.
    public static var everyLine: [String] {
        [comingOffTheRecorderLine, reachingTheVaultLine, reachedTheVaultLine,
         transcriptNotStartedLine, transcribingLine, transcribedLine,
         transcribingInPartsLine(done: 2, total: 20),
         transcriptFailedLine(reason: nil),
         speakersNotSeparatedLine, separatingSpeakersLine, speakersSeparatedLine,
         namingWaitsForTranscriptLine, namingInFlightLine, namedLine,
         neverReadForActionsLine, readAndFoundNothingLine,
         readAndFoundLine(count: 1), readAndFoundLine(count: 3)]
    }
}
