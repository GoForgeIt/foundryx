// CaptureJourney — WHAT IS HAPPENING TO THIS RECORDING, AND WHICH NUMBERS ARE ALLOWED TO SAY SO.
//
// WHAT NICK ASKED FOR, in his words: "it would be good to be able to see status of loading to
// cell as well as how long it will be until it's transcribed? or if any ambient intelligence
// came from it? — some of this shows up on the capture page really nicely (progress for
// transcribing would be nice) and progress towards summary would be nice as well".
//
// WHAT HE WAS SHOWN INSTEAD, measured on the live system on 2026-08-18. His recording came off
// PKT01_BLUE_26079bc5, 237 segments were written to the WAL, the cell ACK'd them, and the cell
// transcribed it — and the phone's own detail page had no line anywhere on it that said any of
// that had happened. The Summary face said "Nothing to summarize yet", the Actions face said
// "Nothing surfaced from this voice note yet", and neither sentence could tell him whether the
// work had not happened or had happened and found nothing.
//
// THE NUMBERS ARE GOVERNED, AND THAT IS MOST OF THIS FILE.
//
//   This surface has printed an invented figure three times: 44-minute shelf rows from a divisor
//   no recorder ever stated; the recorder's kilobytes rendered through a formatter that was
//   handed bytes; and a "4 KB" label on a 19,770-byte file. Each was a number a person could
//   read and nobody could defend.
//
//   So a BAR and a PERCENTAGE are treated here as what they actually are — a claim that a
//   denominator exists AND has stopped moving. `JourneyFigure` is a struct with a private
//   initialiser precisely so that claim cannot be made by writing a case out longhand at a call
//   site: every route in degrades to a COUNT when the denominator is absent, is zero, is smaller
//   than the numerator, or is still growing.
//
//   A recording that is still being written to has a growing denominator. "12 of 12 segments
//   (100%)" on a live recording is true of the twelve segments that exist and reads as "the
//   upload is finished", which is the same lie the self-issued ACKs told. It gets "12 segments".
//
//   Transcription and summarizing have NO denominator on this seam at any time — the door
//   reports a stage and a boolean, never a fraction of a job — so they are LABELS. There is
//   deliberately no route in this file by which either can acquire a bar.
//
// AND THE ONE THING THAT IS UNKNOWABLE IS LEFT UNSAID. An empty `segments` array on the door's
// reply is ambiguous between "this capture was never diarized" and "the door has not forwarded
// the diarization yet" — there is no `diarized` field to tell them apart. So a journey states a
// speaker count ONLY when speakers were actually returned, and says NOTHING about speakers when
// the list is empty. A surface that reported "1 speaker" for an empty list would be inventing
// the commoner of the two readings.
//
// EVERY DECISION AND EVERY STRING IS HERE rather than in a SwiftUI body, for the reason this
// repository keeps re-learning: `swift test` cannot compile `App/`, so a rule written in a body
// is a rule nothing in this repository can execute.

import Foundation

// MARK: - The only numbers allowed in front of a person

/// A figure on the journey, and the evidence that entitles it to be drawn as one.
///
/// THE INVARIANT, ENFORCED BY CONSTRUCTION: `fraction`, `percentText` and `showsBar` are non-nil
/// / true together or not at all, and only a `settled` denominator can produce them. The
/// initialiser is private and every factory funnels through the same degradation, so there is no
/// spelling of a call site that yields a percentage over a denominator that could still move.
public struct JourneyFigure: Sendable, Equatable {

    /// What the figure is counting. `bytes` renders through the size formatter; `items` renders
    /// as a plain count with its noun.
    public enum Unit: Sendable, Equatable { case items, bytes }

    /// Nothing to count — the step is a label. Transcription and summarizing are always this.
    public static let silent = JourneyFigure(done: 0, total: nil, noun: "", unit: .items,
                                             isSilent: true)

    /// How much has happened.
    public let done: Int
    /// What it is out of — NON-NIL ONLY when a settled denominator was proved. This is the whole
    /// gate: every renderable claim below reads it and nothing else.
    public let total: Int?
    public let noun: String
    public let unit: Unit
    private let isSilent: Bool

    private init(done: Int, total: Int?, noun: String, unit: Unit, isSilent: Bool) {
        self.done = done
        self.total = total
        self.noun = noun
        self.unit = unit
        self.isSilent = isSilent
    }

    /// A COUNT. No denominator is claimed, so no bar and no percentage can be derived from it.
    public static func counting(_ done: Int, noun: String) -> JourneyFigure {
        JourneyFigure(done: max(0, done), total: nil, noun: noun, unit: .items, isSilent: false)
    }

    /// A count of BYTES with no announced total — the transfer is moving and nobody said how far.
    public static func countingBytes(_ done: Int) -> JourneyFigure {
        JourneyFigure(done: max(0, done), total: nil, noun: "", unit: .bytes, isSilent: false)
    }

    /// A FRACTION, if and only if the denominator is real and has stopped moving.
    ///
    /// `settled` is the caller's evidence that the denominator cannot grow — a recording that has
    /// stopped being written to, a transfer whose length the recorder announced up front. It is a
    /// required argument with no default, for the same reason `PocketCaptureDurability` makes its
    /// brain required: a default here is a decision about whether a percentage is honest, made by
    /// whoever forgot to pass it.
    ///
    /// FOUR WAYS IN AND ALL FOUR DEGRADE. No denominator, a zero-or-negative denominator, a
    /// numerator past the denominator (a recorder that announced 1,000 bytes and sent 4,000 — a
    /// real bound `PocketBLEClient.download` exists to catch), or a denominator still growing.
    public static func outOf(_ done: Int, of total: Int, noun: String,
                             settled: Bool) -> JourneyFigure {
        let done = max(0, done)
        guard settled, total > 0, done <= total else { return counting(done, noun: noun) }
        return JourneyFigure(done: done, total: total, noun: noun, unit: .items, isSilent: false)
    }

    /// BYTES OFF A RECORDER. The recorder announces the length in `MCU&U&<n>` before it sends a
    /// byte, so — unlike a live recording's segment count — the denominator is settled the moment
    /// the transfer starts. An absent, zero or overrun announcement degrades to a byte count.
    public static func bytes(delivered: Int, announced: Int?) -> JourneyFigure {
        let delivered = max(0, delivered)
        guard let announced, announced > 0, delivered <= announced else {
            return countingBytes(delivered)
        }
        return JourneyFigure(done: delivered, total: announced, noun: "", unit: .bytes,
                             isSilent: false)
    }

    // MARK: what may be drawn

    /// How far along, 0…1 — NIL unless a settled denominator was proved. The bar binds to this
    /// and to nothing else.
    public var fraction: Double? {
        guard !isSilent, let total, total > 0 else { return nil }
        return min(1.0, Double(done) / Double(total))
    }

    /// Whether a progress bar may be drawn at all.
    public var showsBar: Bool { fraction != nil }

    /// The percentage, or nil. Rounded DOWN so a transfer one byte short of finished cannot read
    /// "100%" — the one rounding error that turns a progress figure into a false completion.
    public var percentText: String? {
        guard let fraction else { return nil }
        if done == total { return "100%" }
        return "\(min(99, Int((fraction * 100).rounded(.down))))%"
    }

    /// Whether this figure renders no number at all (a label-only step).
    public var isLabelOnly: Bool { isSilent }

    /// The line as a person reads it.
    ///
    /// THE PERCENTAGE IS PART OF THE LINE ON PURPOSE, so the claim "no percentage without a
    /// settled denominator" can be held over the RENDERED TEXT rather than over a property a
    /// view might route around.
    public var line: String {
        if isSilent { return "" }
        let amount = amountText(done)
        guard let total, let percentText else {
            return noun.isEmpty ? amount : "\(amount) \(noun)"
        }
        let whole = amountText(total)
        let both = noun.isEmpty ? "\(amount) of \(whole)" : "\(amount) of \(whole) \(noun)"
        return "\(both) · \(percentText)"
    }

    private func amountText(_ n: Int) -> String {
        switch unit {
        case .items: return "\(n)"
        case .bytes: return JourneyFigure.size(bytes: n)
        }
    }

    /// BYTES, RENDERED AS BYTES.
    ///
    /// `RecordingDeviceReadingPresentation.size(kilobytes:)` takes KILOBYTES, and handing it a
    /// byte count is exactly the defect that put "19,770 KB" where 19 KB belonged. Below a
    /// kilobyte it says bytes rather than rounding a real 800-byte figure to a fictional 0 KB.
    public static func size(bytes: Int) -> String {
        let bytes = max(0, bytes)
        if bytes < 1_024 { return "\(bytes) bytes" }
        return RecordingDeviceReadingPresentation.size(kilobytes: bytes / 1_024)
    }
}

// MARK: - Did anything come out of it?

/// WHETHER AMBIENT INTELLIGENCE CAME OUT OF THIS RECORDING — and the difference between the four
/// ways of having nothing, which the one sentence on the Actions face could not express.
///
/// "Nothing surfaced from this voice note yet." was the whole vocabulary. It was shown to a
/// recording with no transcript (nothing COULD have been read), to a recording the gate read and
/// found nothing actionable in (a finished, correct answer, and the "yet" makes it read as
/// unfinished), and to a recording whose gate was unavailable and never ran (a failure reported
/// as an absence). Nick asked "if any ambient intelligence came from it?" — that sentence cannot
/// answer him for three of its four meanings.
///
/// The evidence is real and already on disk: the lane writes one `AmbientDecision` per evaluated
/// window with `gatedNo`, `candidate` or `skipped`. A read is a `gatedNo`. A failure is a
/// `skipped` with a reason. No line at all is no read.
public enum AmbientReading: Sendable, Equatable {
    /// There is no transcript, so nothing could have been read. More may still happen.
    case noTranscriptYet
    /// A transcript exists and the gate has recorded nothing about it. More may still happen.
    case notReadYet
    /// Every window the gate saw, it failed on. `reason` is the lane's own `skipReason`.
    case couldNotRead(String?)
    /// The gate read it and found nothing to act on. This is FINISHED, and correct.
    case readAndFoundNothing
    /// Items surfaced. `count` is what the Actions face is actually rendering.
    case surfaced(Int)

    /// THE JOIN, done once, here.
    ///
    /// Order matters and is the honest order: anything actually surfaced outranks every reading
    /// of the log (a user-added action is a real item even where no gate ever ran); then the
    /// absence of a transcript, which is the only state in which "nothing has been read" is a
    /// statement about the pipeline rather than about the recording.
    public static func reading(hasTranscript: Bool,
                               decisions: [AmbientDecision],
                               surfaced: Int) -> AmbientReading {
        if surfaced > 0 { return .surfaced(surfaced) }
        if !hasTranscript { return .noTranscriptYet }
        if decisions.isEmpty { return .notReadYet }
        if decisions.allSatisfy({ $0.outcome == .skipped }) {
            return .couldNotRead(decisions.compactMap(\.skipReason).first)
        }
        return .readAndFoundNothing
    }

    /// Whether this reading is FINISHED — the gate has said its piece.
    public var isSettled: Bool {
        switch self {
        case .readAndFoundNothing, .surfaced: return true
        case .noTranscriptYet, .notReadYet, .couldNotRead: return false
        }
    }

    /// Whether more may still happen. The ONLY readings entitled to the word "yet".
    public var moreMayHappen: Bool {
        switch self {
        case .noTranscriptYet, .notReadYet: return true
        case .couldNotRead, .readAndFoundNothing, .surfaced: return false
        }
    }

    /// The sentence the Actions face shows in place of the old one-size-fits-four line.
    public var line: String {
        switch self {
        // "VOICE NOTE", NOT "RECORDING". features/voice-notes-language.feature retired the old
        // word, and these sentences render on the voice-note detail. The gate behind that
        // feature scans `App/` only, so kit copy that reaches a person is held by
        // `CaptureJourneyCopyTests` instead — an unscanned string is not an exempt one.
        case .noTranscriptYet:
            return "Nothing has been read from this voice note yet — it is still being transcribed."
        case .notReadYet:
            return "This voice note hasn’t been read for actions yet."
        case .couldNotRead(let reason):
            // A WIRE TOKEN IS NOT A SENTENCE. The lane writes `gate_unavailable` /
            // `gate_error`; printing either verbatim in front of a person is the same habit
            // that put a raw drop reason on a card. A reason this file does not recognise adds
            // NOTHING rather than leaking the token — saying less is not the same as guessing.
            switch reason {
            case "gate_unavailable":
                return "Solleva couldn’t read this voice note for actions — the on-device "
                    + "model wasn’t available."
            case "gate_error":
                return "Solleva couldn’t read this voice note for actions — the on-device "
                    + "model failed."
            default:
                return "Solleva couldn’t read this voice note for actions."
            }
        case .readAndFoundNothing:
            return "Solleva read this voice note and found nothing to act on."
        case .surfaced(let n):
            return n == 1 ? "1 item came out of this voice note."
                          : "\(n) items came out of this voice note."
        }
    }

    /// THE POPULATION. Every reading this type can hold, so a claim about its sentences is held
    /// over the whole set rather than over whichever case a test author remembered.
    public static var everyReading: [AmbientReading] {
        [.noTranscriptYet, .notReadYet, .couldNotRead("gate_unavailable"),
         .readAndFoundNothing, .surfaced(2)]
    }
}

// MARK: - The reading a journey is built from

/// WHAT THIS JOURNEY KNOWS ABOUT THE TRANSFER OFF A RECORDER.
///
/// IT IS AN ENUM BECAUSE THE BOOL-AND-OPTIONAL SPELLING OF IT SHIPPED A FALSEHOOD IN THIS VERY
/// FILE. The first draft took `cameOffARecorder: Bool` and `pull: PullReading?`, and the detail
/// view — which knows a recorder's file is on this phone and knows nothing about the transfer
/// that put it there, because nothing measures it — passed `true` and `nil`. That pair has two
/// meanings ("in flight, unmeasured" and "finished, unmeasured") and the step read the first, so
/// every recording that had ALREADY come over rendered "Off the recorder" as still waiting,
/// forever, at the top of its own page. Three states, crushed into a bool and an optional: the
/// same shape as the tier defect this whole wave is about.
public enum RecorderTransfer: Sendable, Equatable {
    /// This phone recorded it itself. There is no transfer step at all.
    case none
    /// A transfer with a live reading — in flight, or finished with its numbers.
    case measured(PullReading)
    /// The recorder's file is on this phone and nobody measured the transfer that brought it.
    /// Being able to open the file IS the completion evidence; there is no figure, because
    /// inventing one after the fact is exactly what this file exists to prevent.
    case arrived
}

/// The bytes coming off a recorder, as the transfer itself reports them.
public struct PullReading: Sendable, Equatable {
    /// Bytes handed to the phone's sink so far.
    public let delivered: Int
    /// The recorder's OWN `MCU&U&<n>` announcement, or nil when the transfer has not got that far.
    public let announced: Int?
    /// Whether the transfer completed.
    public let finished: Bool

    public init(delivered: Int, announced: Int?, finished: Bool) {
        self.delivered = delivered
        self.announced = announced
        self.finished = finished
    }
}

/// Every signal a journey is built from, and every one of them is something the phone measured.
///
/// There is deliberately no field on this struct that a caller could fill with an estimate: no
/// expected duration, no expected segment count, no "typically takes about". A field that does
/// not exist cannot be printed.
public struct CaptureJourneyReading: Sendable, Equatable {
    /// What is known about the transfer off a recorder — including that there was none.
    public var transfer: RecorderTransfer
    /// The local WAL's own stage.
    public var wal: CaptureStage
    /// Whether audio is still arriving — the evidence that the segment denominator can still grow.
    public var streaming: Bool
    public var totalSegments: Int
    public var syncedSegments: Int
    /// Where THIS ACCOUNT actually saves, resolved from the brain the root gate resolved to.
    public var destination: CaptureDestination
    public var door: CaptureLifecycleStage
    public var transcribed: Bool
    public var hasTranscript: Bool
    /// Speakers the door ACTUALLY returned. Zero means "the reply carried none", which is
    /// ambiguous, and the journey therefore says nothing at all about speakers.
    public var separatedSpeakers: Int
    public var summarizing: Bool
    public var hasSummary: Bool
    public var ambient: AmbientReading
    public var droppedReason: String?

    public init(transfer: RecorderTransfer = .none,
                wal: CaptureStage = .savedOnPhone,
                streaming: Bool = false,
                totalSegments: Int = 0,
                syncedSegments: Int = 0,
                destination: CaptureDestination,
                door: CaptureLifecycleStage = .stored,
                transcribed: Bool = false,
                hasTranscript: Bool = false,
                separatedSpeakers: Int = 0,
                summarizing: Bool = false,
                hasSummary: Bool = false,
                ambient: AmbientReading = .noTranscriptYet,
                droppedReason: String? = nil) {
        self.transfer = transfer
        self.wal = wal
        self.streaming = streaming
        self.totalSegments = totalSegments
        self.syncedSegments = syncedSegments
        self.destination = destination
        self.door = door
        self.transcribed = transcribed
        self.hasTranscript = hasTranscript
        self.separatedSpeakers = separatedSpeakers
        self.summarizing = summarizing
        self.hasSummary = hasSummary
        self.ambient = ambient
        self.droppedReason = droppedReason
    }
}

// MARK: - The journey

public struct CaptureJourney: Sendable, Equatable {

    /// The phases a recording can pass through. Which of them EXIST for a given recording is
    /// decided by the reading — a recording this phone made itself has no transfer step, and the
    /// phone-only tier has no second place, so neither is drawn as a permanently-pending row that
    /// will never complete.
    public enum Phase: String, Sendable, Equatable, CaseIterable {
        /// Bytes coming off the recorder over Bluetooth.
        case offTheRecorder
        /// Durable in this phone's write-ahead log.
        case onThisPhone
        /// Acknowledged by the place this account saves to.
        case secondPlace
        /// A transcript exists.
        case transcript
        /// A summary exists.
        case summary
        /// Whether anything came out of it.
        case surfaced
    }

    public enum State: String, Sendable, Equatable {
        case done, working, waiting, failed
    }

    public struct Step: Sendable, Equatable, Identifiable {
        public let phase: Phase
        public let title: String
        public let state: State
        public let figure: JourneyFigure
        /// A sentence under the title, or nil. Never a number a `JourneyFigure` should have held.
        public let detail: String?

        public var id: String { phase.rawValue }

        public init(phase: Phase, title: String, state: State,
                    figure: JourneyFigure = .silent, detail: String? = nil) {
            self.phase = phase
            self.title = title
            self.state = state
            self.figure = figure
            self.detail = detail
        }
    }

    public let steps: [Step]

    public init(steps: [Step]) { self.steps = steps }

    public func step(_ phase: Phase) -> Step? { steps.first { $0.phase == phase } }

    /// The step a person is waiting on — the first that is not finished. Nil once everything that
    /// can finish has.
    public var current: Step? { steps.first { $0.state != .done } }

    /// The one line a row shows when there is no room for the whole ladder.
    public var headline: String {
        guard let current else { return "Everything is done." }
        if current.state == .failed { return current.detail ?? current.title }
        let figure = current.figure.line
        return figure.isEmpty ? current.title : "\(current.title) — \(figure)"
    }

    // MARK: - the build

    public static func build(_ r: CaptureJourneyReading) -> CaptureJourney {
        var steps: [Step] = []

        if let transfer = transferStep(r) { steps.append(transfer) }
        steps.append(phoneStep(r))
        if let second = secondPlaceStep(r) { steps.append(second) }
        steps.append(transcriptStep(r))
        steps.append(summaryStep(r))
        steps.append(surfacedStep(r))

        return CaptureJourney(steps: steps)
    }

    private static func transferStep(_ r: CaptureJourneyReading) -> Step? {
        let title = "Off the recorder"
        switch r.transfer {
        case .none:
            return nil
        case .arrived:
            // NO FIGURE. Nobody counted the bytes as they came, and a number produced now
            // would be a number about a past event nothing observed.
            return Step(phase: .offTheRecorder, title: title, state: .done)
        case .measured(let pull):
            let figure = JourneyFigure.bytes(delivered: pull.delivered, announced: pull.announced)
            return Step(phase: .offTheRecorder, title: title,
                        state: pull.finished ? .done : .working, figure: figure)
        }
    }

    private static func phoneStep(_ r: CaptureJourneyReading) -> Step {
        // THE SEGMENT COUNT IS A COUNT AND NEVER A FRACTION. This phone does not know, and cannot
        // know, how many segments a recording that is still arriving will end up with.
        let figure = JourneyFigure.counting(r.totalSegments, noun: r.totalSegments == 1
                                            ? "segment" : "segments")
        let state: State
        if r.totalSegments <= 0 {
            state = .waiting
        } else if r.streaming {
            // STILL ARRIVING. The segments already written ARE durable, but calling the step
            // done while audio is still coming in reads as "all of it is safe", and the count
            // beside it is about to change — which is the same overclaim as a percentage over a
            // denominator that is still growing. A dead capture that stopped streaming without
            // finalising is `.done`, deliberately: its segments are all it will ever have.
            state = .working
        } else {
            state = .done
        }
        return Step(phase: .onThisPhone, title: "Saved on this phone", state: state,
                    figure: figure)
    }

    /// THE SECOND PLACE, NAMED FROM THE RESOLVED BRAIN AND NOT FROM A BOOLEAN.
    ///
    /// The phone-only tier returns nil rather than a step: it has no second place, and drawing a
    /// forever-pending "Saved to…" row would be the same claim the settled sync line was fixed for
    /// making. `.vault` says Vault; `.computer` says computer; neither can be reached from the
    /// other, because `CaptureDestination` has no value that names a place the user is not on.
    private static func secondPlaceStep(_ r: CaptureJourneyReading) -> Step? {
        let title: String
        switch r.destination {
        case .phone: return nil
        case .computer: title = "Saved to your computer"
        case .vault: title = "Saved to your Vault"
        }
        // SETTLED means the numerator cannot outrun a denominator that is still growing. A live
        // recording's total is still being written; a finished one's is not.
        let settled = !(r.streaming || r.wal == .recording)
        let figure = JourneyFigure.outOf(r.syncedSegments, of: r.totalSegments,
                                         noun: r.totalSegments == 1 ? "segment" : "segments",
                                         settled: settled)
        let state: State
        if r.totalSegments > 0 && r.syncedSegments >= r.totalSegments && settled {
            state = .done
        } else if r.syncedSegments > 0 {
            state = .working
        } else {
            state = .waiting
        }
        return Step(phase: .secondPlace, title: title, state: state, figure: figure)
    }

    /// TRANSCRIPTION IS A LABEL. There is no route in this function that can produce a figure with
    /// a denominator: the door reports a stage and a boolean, and a fraction of a transcription is
    /// a number nobody on this seam has ever measured.
    private static func transcriptStep(_ r: CaptureJourneyReading) -> Step {
        let title = "Transcribed"
        if r.door == .failed {
            let why = ConversationProgress.failureMessage(droppedReason: r.droppedReason)
                ?? "Transcription failed."
            return Step(phase: .transcript, title: title, state: .failed, detail: why)
        }
        if r.hasTranscript || r.transcribed {
            return Step(phase: .transcript, title: title, state: .done,
                        detail: speakerDetail(r))
        }
        let working = r.door == .transcribing
            || (r.door == .inLore && !r.transcribed)
            || (r.wal == .savedToComputer && r.door == .stored)
        return Step(phase: .transcript, title: title, state: working ? .working : .waiting)
    }

    /// WHAT IS SAID ABOUT SPEAKERS, AND WHAT IS NOT.
    ///
    /// Zero returned speakers is ambiguous — never diarized, or diarized and not yet forwarded —
    /// and there is no field on the reply that separates them. So zero produces NO SENTENCE. The
    /// alternative, reporting the commoner reading as fact, is how "1 speaker" would end up under
    /// a two-person conversation.
    private static func speakerDetail(_ r: CaptureJourneyReading) -> String? {
        guard r.separatedSpeakers > 0 else { return nil }
        return r.separatedSpeakers == 1
            ? "1 speaker separated"
            : "\(r.separatedSpeakers) speakers separated"
    }

    /// SUMMARIZING IS A LABEL, for the same reason transcription is.
    private static func summaryStep(_ r: CaptureJourneyReading) -> Step {
        let title = "Summarized"
        if r.hasSummary { return Step(phase: .summary, title: title, state: .done) }
        if r.summarizing { return Step(phase: .summary, title: title, state: .working) }
        return Step(phase: .summary, title: title, state: .waiting)
    }

    private static func surfacedStep(_ r: CaptureJourneyReading) -> Step {
        let title = "Read for actions"
        let figure: JourneyFigure
        if case .surfaced(let n) = r.ambient {
            figure = .counting(n, noun: n == 1 ? "item" : "items")
        } else {
            figure = .silent
        }
        let state: State
        switch r.ambient {
        case .surfaced, .readAndFoundNothing: state = .done
        case .couldNotRead: state = .failed
        case .noTranscriptYet, .notReadYet: state = .waiting
        }
        return Step(phase: .surfaced, title: title, state: state, figure: figure,
                    detail: r.ambient.line)
    }
}

// MARK: - Where a brain actually saves

public extension BrainChoice {

    /// THE PLACE THIS BRAIN SAVES TO, as a three-valued fact.
    ///
    /// It exists because the two-valued spelling of this question has already shipped a false
    /// sentence twice. `SyncStripCopy.allSaved` read a Bool and told a Vault owner with no
    /// computer "All voice notes saved to computer"; `WaitCopy.make(for:onDevice:)` read one
    /// and told the same owner his audio was transcribed "on your own Mac" (now
    /// `make(for:destination:)`, exhaustive over `CaptureDestination`). Both were the same
    /// crush: three brains, one bit, and the cell inheriting the computer's words
    /// byte-identically.
    ///
    /// `CaptureDestination` has no value that can name a place the user is not on, so a journey
    /// built through here cannot acquire the defect by being wired up carelessly.
    var captureDestination: CaptureDestination {
        switch self {
        case .justMyPhone:  return .phone
        case .myComputer:   return .computer
        case .foundryCloud: return .vault
        }
    }
}

// MARK: - The join the detail view performs

public extension CaptureJourneyReading {

    /// EVERY SIGNAL THE CONVERSATION DETAIL HOLDS, JOINED ONCE, HERE.
    ///
    /// The view's job is then to call this and draw the result. The join is in the kit because
    /// `swift test` cannot compile `App/` — a join written in a SwiftUI body is a join no test in
    /// this repository can execute, which is precisely how the refuted guards got there.
    ///
    /// `cardStage` is the durable tombstone's advisory stage string; an unrecognised one degrades
    /// to `.stored` (`CaptureLifecycleStage.init(wire:)`), never to a crash and never to a stage
    /// that claims more than the wire said.
    static func detail(status: CaptureStatus?,
                       brain: BrainChoice,
                       transfer: RecorderTransfer,
                       cardStage: String?,
                       content: CaptureContent?,
                       hasTranscript: Bool,
                       separatedSpeakers: Int,
                       hasSummary: Bool,
                       synthesizingSummary: Bool,
                       decisions: [AmbientDecision],
                       surfaced: Int) -> CaptureJourneyReading {
        let door: CaptureLifecycleStage = {
            if let wire = cardStage, !wire.isEmpty { return CaptureLifecycleStage(wire: wire) }
            return hasTranscript ? .transcribed : .stored
        }()
        return CaptureJourneyReading(
            transfer: transfer,
            wal: status?.stage ?? (hasTranscript ? .savedToComputer : .savedOnPhone),
            streaming: status?.streaming ?? false,
            totalSegments: status?.totalSegments ?? 0,
            syncedSegments: status?.syncedSegments ?? 0,
            destination: brain.captureDestination,
            door: door,
            transcribed: hasTranscript,
            hasTranscript: hasTranscript,
            separatedSpeakers: separatedSpeakers,
            // THE DOOR'S OWN FLAG WINS over the phone's local synth: when the door says it is
            // summarizing, saying so is a fact about the pipeline; the local synth is a fallback
            // and relabelling desktop work as on-device work would be the same tier lie again.
            summarizing: (content?.summarizing ?? false) || synthesizingSummary,
            hasSummary: hasSummary,
            ambient: AmbientReading.reading(hasTranscript: hasTranscript,
                                            decisions: decisions,
                                            surfaced: surfaced),
            droppedReason: nil)
    }
}
