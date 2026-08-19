// PocketTransferJob.swift — THE BRING-OVER AS A JOB, NOT AS A FIELD ON A SCREEN.
//
// WHAT WAS THERE BEFORE, MEASURED IN THE SOURCE. A bring-over was one `Task` stored in a slot
// on a SwiftUI `@StateObject` whose lifetime IS the recorder page; `.onDisappear` cancelled it
// deliberately, so leaving the page — the thing a person DOES during a transfer measured at
// 18-36 KB/s — killed the work. The recorder's own progress numbers (`MCU&U&` announced,
// bytes delivered) were computed inside the protocol client and thrown away. There was no
// queue: `PocketBringOver`'s header says "IT BRINGS ONE FILE", and the one backlog actor ever
// written (`PocketDurableSync`) has no production caller. There was no reconnect at any layer.
//
// WHAT THIS IS. One actor that owns a SEQUENTIAL queue of bring-overs, the attachment and task
// driving the current one, and a per-recording phase anybody can watch. It lives in
// `FoundryXKit` — not `App/` — for the reason this repository states everywhere: `swift test`
// cannot compile `App/`, so a rule written in a SwiftUI body is a rule nothing can execute.
// A page that wants to show the queue SUBSCRIBES to it; the page departing tells it nothing.
//
// THE SHAPE IS FORCED BY A MEASURED FACT: THE WIRE CANNOT RESUME. The download verb takes two
// fields — `APP&U&<date>&<stamp>` — and admits no offset (hardware verb table, fw 1.6; the
// reference implementation's own recovery re-pulls the WHOLE file). Custody independently
// forbids resumption: `beginKeeping` deletes any pre-existing `.partial`. So every retry here
// STARTS FROM ZERO, and every sentence this file renders about a retry says so instead of
// implying a resume that cannot happen.
//
// ONE SESSION, N FILES — measured-possible, not hoped-for: two downloads came over one
// authenticated session with no re-auth on `PKT01_BLUE_26079bc5` (fw 1.6, 2026-08-18). That is
// what the `MCU&OFF` drain unblocked, and it is why the loop below re-authenticates only when
// a session actually died — a stop, a stall or a link drop retires the client by construction
// (`protected(_:)` and `teardown()` are permanent), so those paths build a FRESH attachment.

import Foundation

/// HOW A TRANSFER WAS CUT SHORT — three different facts that used to be one sentence.
///
/// `PocketBringOver` folds `.timeout, .stall, .disconnected, .transportFailure, .cancelled`
/// into `.transferIncomplete`, which is the right honesty for a single tap and useless for a
/// queue: a stall wants an immediate re-ask, a link drop wants backoff, and an owner's stop
/// wants NOTHING to happen next. This enum is the queue's reason to know which.
public enum PocketTransferInterruption: Sendable, Equatable {
    /// The link is up and the recorder went quiet past the idle-gap deadline.
    case stalled
    /// The device left — out of range, off, or claimed by another phone.
    case linkDropped
    /// Somebody stopped it. Never a failure of the recorder.
    case stopped
    /// The transport failed in a way the radio could not name.
    case transport
}

/// One per-session bring-over's result: the outcome every caller already speaks, plus the
/// interruption when the transfer was cut short. `interruption` is non-nil ONLY alongside
/// `.transferIncomplete` from a cut-short radio read.
public struct PocketBringOverAttempt: Sendable {
    public let outcome: PocketBringOverOutcome
    public let interruption: PocketTransferInterruption?
    public init(outcome: PocketBringOverOutcome, interruption: PocketTransferInterruption?) {
        self.outcome = outcome
        self.interruption = interruption
    }
}

/// THE ONE HONEST READING OF A TRANSFER, accumulated under a lock so the announce and the
/// chunk callbacks — which both run on the radio path — cannot shear it. Two facts only:
/// bytes the recorder announced (`MCU&U&`) and bytes actually handed to disk.
final class PocketTransferMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var delivered = 0
    private var announced = 0

    func announce(_ total: Int) {
        lock.withLock { announced = total }
    }

    func deliver(_ count: Int) -> (delivered: Int, announced: Int) {
        lock.withLock {
            delivered += count
            return (delivered, announced)
        }
    }
}

/// WHERE ONE QUEUED RECORDING IS, stated so a row can draw it without inventing a number.
public enum PocketTransferPhase: Sendable, Equatable {
    /// Waiting its turn.
    case queued
    /// The session is asking for it and the recorder has not yet announced a size. THERE IS NO
    /// PERCENTAGE HERE ON PURPOSE: before `MCU&U&` arrives there is no denominator, and a 0%
    /// invented from the listing would be a number nobody measured.
    case starting
    /// Bytes are landing. `announcedBytes` is the recorder's OWN `MCU&U&` total — never the
    /// listed size, which is a different unit (measured: listing 4 -> 19,770 announced bytes).
    case transferring(deliveredBytes: Int, announcedBytes: Int)
    /// The transfer was cut short and will be asked for again after this wait — FROM THE
    /// BEGINNING. The wire cannot express a resumable read and custody keeps no partial, so
    /// pretending otherwise would be a progress bar that lies about what a retry costs.
    case waitingToRetry(afterSeconds: TimeInterval, attempt: Int)
    /// In Solleva, and a conversation.
    case broughtOver(captureID: String)
    /// It was already here; the recorder was not asked again.
    case alreadyHeld(captureID: String)
    /// The owner stopped it. Nothing was kept; the recording is still on the recorder.
    case stopped
    /// Given up, with the sentence that says why.
    case failed(String)

    /// The honest fraction, and ONLY when there is a denominator: no announcement, no
    /// percentage, no bar. Clamped so a recorder that sends more than it said it would cannot
    /// draw a bar past its own end.
    public var fraction: Double? {
        guard case .transferring(let delivered, let announced) = self, announced > 0 else {
            return nil
        }
        return Double(min(delivered, announced)) / Double(announced)
    }

    /// Whether this recording's queue journey is over.
    public var isFinished: Bool {
        switch self {
        case .broughtOver, .alreadyHeld, .stopped, .failed: return true
        case .queued, .starting, .transferring, .waitingToRetry: return false
        }
    }
}

/// One recording in the queue, with where it is.
public struct PocketTransferItem: Sendable, Equatable {
    public let recording: PocketRecording
    public var phase: PocketTransferPhase
    public init(recording: PocketRecording, phase: PocketTransferPhase = .queued) {
        self.recording = recording
        self.phase = phase
    }
}

/// Every sentence the queue renders, in the kit, for the same reason every other device string
/// is: `swift test` cannot compile `App/`.
public enum PocketTransferQueuePresentation {
    /// Before the recorder has announced a size. A WORD, NOT A NUMBER — 0% would be a claim
    /// about a total nothing has stated yet.
    public static let startingLine = "Starting…"

    /// THE HONESTY BOUND, IN ONE SENTENCE. Rendered for every `.waitingToRetry`, whatever cut
    /// the transfer short: the wire admits no offset and custody keeps no partial, so a retry
    /// is the whole file again, and the person watching a long transfer restart deserves to be
    /// told rather than shown a bar that quietly returns to zero.
    public static let restartsFromTheBeginningLine =
        "A transfer can't pick up partway, so this recording will start again from the beginning."

    /// The recorder went quiet with the link still up. Retried on a fresh session.
    public static let stalledLine =
        "The recorder went quiet, so Solleva will ask for this recording again. "
        + restartsFromTheBeginningLine

    /// The device left. Retried on the backoff schedule, and the wait is NAMED — "retrying"
    /// with no interval is a spinner, not a sentence.
    public static func outOfReachLine(afterSeconds: TimeInterval) -> String {
        "The recorder is out of reach. Solleva will try again in "
            + waitText(afterSeconds) + ". " + restartsFromTheBeginningLine
    }

    /// The owner stopped this one. Says what was kept — nothing — and where the recording
    /// still is, the same two facts every stopped-transfer line in this app states.
    public static let stoppedLine =
        "Stopped. Nothing was kept — the recording is still on the recorder."

    /// Out of attempts. The recording is not gone; it is where it always was.
    public static let gaveUpLine =
        "Solleva couldn't finish bringing this recording over. Nothing was kept — it's still "
        + "on the recorder."

    /// The line a phase earns. The retry lines carry the restart-from-zero sentence because
    /// the retry IS from zero; a UI that dropped that clause would be implying a resume the
    /// hardware cannot perform.
    public static func line(for phase: PocketTransferPhase) -> String? {
        switch phase {
        case .queued: return nil
        case .starting: return startingLine
        case .transferring: return PocketBringOverPresentation.inProgressLine
        case .waitingToRetry(let seconds, _):
            return seconds <= 0 ? stalledLine : outOfReachLine(afterSeconds: seconds)
        case .broughtOver: return PocketBringOverPresentation.broughtOverLine
        case .alreadyHeld: return PocketBringOverPresentation.alreadyHeldLine
        case .stopped: return stoppedLine
        case .failed(let line): return line
        }
    }

    private static func waitText(_ seconds: TimeInterval) -> String {
        seconds >= 60
            ? "\(Int((seconds / 60).rounded())) min"
            : "\(Int(seconds.rounded())) sec"
    }
}

#if canImport(CoreBluetooth)

/// THE SEQUENTIAL QUEUE, ON ONE RADIO, OWNED BY NO SCREEN.
///
/// One instance is meant to be owned by the app (not a page), handed a derived backlog, and
/// left to drain it. The queue is DERIVED, not stored: (shelf listing) minus (custody) is
/// recomputable from disk at any time — `derivedBacklog` below — so a killed app resumes the
/// QUEUE for free even though it can never resume a FILE. The only state this actor adds is
/// the owner's stops, which survive re-derivation so "stop this one" is not a button the next
/// re-derivation silently un-presses.
public actor PocketTransferQueue {

    /// Builds a FRESH attachment per session. Not an optimisation to remove: `teardown()`
    /// retires an attachment permanently, so every re-attach after a stop, a stall or a drop
    /// MUST construct a new one — reusing one is the flap shape.
    public typealias AttachmentFactory = @Sendable () -> RecordingDeviceAttachment
    /// The wait between retries, injected so a suite can hold the SCHEDULE — 60/120/240/300 —
    /// without sitting through it. Production passes a real sleep.
    public typealias Sleeper = @Sendable (TimeInterval) async -> Void
    /// Every phase change, including per-chunk `.transferring` readings, in arrival order.
    /// Called synchronously from wherever the change happens — coalescing for a UI belongs
    /// above this seam, not inside the radio path.
    public typealias PhaseSink = @Sendable (PocketRecordingRequest, PocketTransferPhase) -> Void

    public struct Configuration: Sendable {
        /// How many times one recording is ASKED FOR before the queue gives up on it. The
        /// reference implementation's own recovery shape (`download_with_retry`: fresh
        /// connection, whole file again, bounded attempts) — never unbounded, because every
        /// attempt restarts from zero and a 27-minute file is not free.
        public var attemptsPerRecording: Int
        /// How many CONSECUTIVE failures to open a session at all before the remaining queue
        /// is reported failed rather than silently hammered forever.
        public var sessionAttempts: Int
        public init(attemptsPerRecording: Int = 4, sessionAttempts: Int = 3) {
            self.attemptsPerRecording = attemptsPerRecording
            self.sessionAttempts = sessionAttempts
        }
    }

    private let peripheralIdentifier: UUID
    private let advertisedName: String
    private let custody: any PocketRecorderFileCustody
    private let destination: PocketBringOver.Destination
    private let makeAttachment: AttachmentFactory
    private let sleeper: Sleeper
    private let configuration: Configuration

    private var items: [PocketTransferItem] = []
    /// THE OWNER'S STOPS, DURABLY SUPPRESSED. The queue is re-derivable from the shelf, and a
    /// stop that lived only in the current list would be re-offered by the next re-derivation —
    /// which turns "stop this one" into a button that un-presses itself. `enqueue` refuses
    /// these keys until `allowAgain` is called for one.
    private var stoppedRequests: Set<PocketRecordingRequest> = []
    private var attemptsByRequest: [PocketRecordingRequest: Int] = [:]
    /// The shipped presence schedule — 60/120/240/300 s — finally wired to a caller.
    private var backoff = PocketPresenceBackoff()
    private var consecutiveSessionFailures = 0
    private var stopEverything = false
    private var running = false
    private var currentRequest: PocketRecordingRequest?
    private var currentAttachment: RecordingDeviceAttachment?
    private var currentWork: Task<PocketBringOverAttempt, Never>?
    private var phaseSink: PhaseSink?

    public init(peripheralIdentifier: UUID,
                advertisedName: String,
                custody: any PocketRecorderFileCustody = PocketRecorderFileStore(),
                destination: PocketBringOver.Destination = .init(),
                makeAttachment: @escaping AttachmentFactory = { RecordingDeviceAttachment() },
                sleeper: @escaping Sleeper = { seconds in
                    try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
                },
                configuration: Configuration = .init()) {
        self.peripheralIdentifier = peripheralIdentifier
        self.advertisedName = advertisedName
        self.custody = custody
        self.destination = destination
        self.makeAttachment = makeAttachment
        self.sleeper = sleeper
        self.configuration = configuration
    }

    // MARK: - The derived queue

    /// (SHELF LISTING) MINUS (CUSTODY), in the shipped order — newest day, smallest file
    /// first. This is the whole queue, recomputable from disk, which is what makes the job
    /// durable without inventing a queue file. A recording whose bytes are held but which has
    /// not become a conversation is still excluded here: re-pulling it would cost radio time
    /// for bytes already on the phone, and the import retries off the held file the next time
    /// the item is asked for.
    public static func derivedBacklog(from recordings: [PocketRecording],
                                      custody: any PocketRecorderFileCustody,
                                      identity: RecordingDeviceIdentity) async -> [PocketRecording] {
        var held: Set<PocketRecordingRequest> = []
        for recording in recordings {
            let key = PocketRecorderFileKey(identity: identity,
                                            date: recording.date,
                                            timestamp: recording.timestamp)
            if await custody.alreadyHeld(key) { held.insert(recording.request) }
        }
        let ordering = RecordingDeviceIdentity(shape: .filePull, hardwareToken: "ordering")
        let candidates = recordings
            .filter { !held.contains($0.request) }
            .map {
                PocketInventoryCandidate(
                    key: PocketRecorderFileKey(identity: ordering, date: $0.date,
                                               timestamp: $0.timestamp),
                    announcedSize: $0.sizeBytes,
                    closureEvidence: true)
            }
        return PocketDurableSync.ordered(candidates).compactMap { candidate in
            recordings.first {
                $0.date == candidate.key.date && $0.timestamp == candidate.key.timestamp
            }
        }
    }

    // MARK: - What the outside may ask

    /// The queue as it stands, in order.
    public var snapshot: [PocketTransferItem] { items }

    /// Observe every phase change. Replaces any previous observer.
    public func observePhases(_ sink: PhaseSink?) { phaseSink = sink }

    /// Add recordings to the back of the queue. A recording already queued is not queued
    /// twice, and A RECORDING THE OWNER STOPPED IS NOT RE-OFFERED — that suppression is the
    /// difference between a stop button and a decoration.
    public func enqueue(_ recordings: [PocketRecording]) {
        for recording in recordings {
            guard !stoppedRequests.contains(recording.request),
                  !items.contains(where: { $0.recording.request == recording.request })
            else { continue }
            items.append(.init(recording: recording, phase: .queued))
        }
    }

    /// The owner un-stops one recording — the ONLY door back in after `stop`.
    public func allowAgain(_ request: PocketRecordingRequest) {
        stoppedRequests.remove(request)
    }

    /// STOP THIS ONE. Mid-download: the work task is cancelled FIRST, then the session torn
    /// down — in that order, because the parked transport read has no cancellation handler and
    /// only the teardown wakes it; waking it first would report a link drop that never
    /// happened. Custody's `.cancelled` path discards the `.partial`, so nothing half-written
    /// remains. Mid-queue: the item is marked stopped and the rest CONTINUES.
    public func stop(_ request: PocketRecordingRequest) {
        stoppedRequests.insert(request)
        if currentRequest == request {
            cancelCurrent()
        } else if let index = items.firstIndex(where: { $0.recording.request == request }),
                  !items[index].phase.isFinished {
            setPhase(request, .stopped)
        }
    }

    /// STOP EVERYTHING. Clears the intent — without this the derived queue would immediately
    /// re-offer itself, which is the false-button shape `stop(_:)`'s suppression exists for.
    public func stopAll() {
        stopEverything = true
        for item in items where !item.phase.isFinished {
            stoppedRequests.insert(item.recording.request)
            if item.recording.request != currentRequest {
                setPhase(item.recording.request, .stopped)
            }
        }
        cancelCurrent()
    }

    // MARK: - The drain

    /// What one session's drain tells the loop above it.
    private enum Directive: Sendable {
        /// No runnable items remain (or everything was stopped).
        case finished
        /// The session died; open a fresh one now — a stop or an immediate stall retry.
        case reattachNow
        /// The session died; wait this long, then open a fresh one. The wait is the shipped
        /// presence backoff and is reported on the item as `.waitingToRetry`.
        case retryAfter(TimeInterval)
    }

    /// DRAIN THE QUEUE. Returns when nothing runnable remains. Re-entrant calls return at
    /// once — one radio, one errand is the rule everywhere on this surface.
    public func run() async {
        guard !running else { return }
        running = true
        defer { running = false }
        while !stopEverything, nextRunnable() != nil {
            let directive = await openSessionAndDrain()
            switch directive {
            case .finished, .reattachNow:
                continue
            case .retryAfter(let seconds):
                guard !stopEverything else { break }
                await sleeper(seconds)
            }
        }
        if stopEverything { markRemainingStopped() }
    }

    private func openSessionAndDrain() async -> Directive {
        let attachment = makeAttachment()
        currentAttachment = attachment
        defer { currentAttachment = nil }
        let result: RecordingDeviceSessionResult<Directive> =
            await attachment.withAuthenticatedSession(
                peripheralIdentifier: peripheralIdentifier,
                advertisedName: advertisedName
            ) { [weak self] client, identity in
                await self?.drain(client: client, identity: identity) ?? .finished
            }
        switch result {
        case .ran(let directive):
            return directive
        case .unavailable(let outcome):
            guard !stopEverything else { return .finished }
            consecutiveSessionFailures += 1
            guard consecutiveSessionFailures < configuration.sessionAttempts else {
                markRunnableFailed(
                    PocketRecorderCheckPresentation.message(for: .unavailable(outcome))
                        ?? PocketRecorderCheckPresentation.notThisRecorderLine)
                return .finished
            }
            let interval = backoff.missed()
            if let request = nextRunnable()?.recording.request {
                setPhase(request, .waitingToRetry(afterSeconds: interval,
                                                  attempt: attemptsByRequest[request] ?? 0))
            }
            return .retryAfter(interval)
        }
    }

    /// AS MANY CONSECUTIVE ITEMS AS ONE SESSION CAN CARRY. The loop leaves only when the
    /// session is known dead (stop, stall, drop — `protected(_:)` retires the client on all
    /// of them) or when nothing runnable remains.
    private func drain(client: PocketBLEClient, identity: PocketAuthenticatedIdentity)
        async -> Directive {
        // The device answered: the session opened. The presence backoff resets HERE, so the
        // next disappearance starts the schedule from the top rather than from wherever a
        // previous outage left it.
        consecutiveSessionFailures = 0
        backoff.found()
        while !stopEverything, let item = nextRunnable() {
            let request = item.recording.request
            guard item.recording.sizeBytes <= PocketBringOver.maximumBytes else {
                setPhase(request, .failed(PocketBringOverPresentation.unreadableRecordingLine))
                continue
            }
            currentRequest = request
            let attempt = (attemptsByRequest[request] ?? 0) + 1
            attemptsByRequest[request] = attempt
            setPhase(request, .starting)
            let sink = phaseSink
            let custody = self.custody
            let destination = self.destination
            let advertisedName = self.advertisedName
            let recording = item.recording
            let work = Task {
                await PocketBringOver.bringOver(
                    on: client, identity: identity, advertisedName: advertisedName,
                    recording: recording, custody: custody, destination: destination,
                    progress: { delivered, announced in
                        // THE DENOMINATOR IS THE `MCU&U&` ANNOUNCEMENT, straight off the
                        // wire, and it reaches the observer in arrival order because this is
                        // called synchronously on the download path — an actor hop here would
                        // let readings arrive shuffled and a monotonic bar go backwards.
                        sink?(request, .transferring(deliveredBytes: delivered,
                                                     announcedBytes: announced))
                    })
            }
            currentWork = work
            let outcome = await work.value
            currentWork = nil
            currentRequest = nil
            // AN OWNER'S STOP WINS OVER EVERY OTHER READING OF THE SAME MOMENT. `stop(_:)`
            // cancels the task and THEN tears the session down, and the teardown's wake-up
            // can reach the parked read before the cancellation flag does — in which case the
            // transfer reports `.linkDropped` for a disconnect this app inflicted on itself.
            // The suppression set is the owner's intent and it is already written, so it is
            // the authority here: a stopped item is stopped, never "retrying in 60 s".
            if outcome.interruption == .stopped || stoppedRequests.contains(request) {
                stoppedRequests.insert(request)
                setPhase(request, .stopped)
                // The stop tore the session down with the task; the REST of the queue gets a
                // fresh session and continues — stop-one is not stop-all.
                return .reattachNow
            }
            switch outcome.interruption {
            case .stopped:
                // Handled above; kept exhaustive so a new interruption cannot fall through
                // to a retry silently.
                return .reattachNow
            case .stalled, .transport:
                guard attempt < configuration.attemptsPerRecording else {
                    setPhase(request, .failed(PocketTransferQueuePresentation.gaveUpLine))
                    return .reattachNow
                }
                // The link was up and the recorder went quiet: one immediate re-ask on a
                // fresh session (the reference implementation's own first move), backoff only
                // if it keeps happening.
                if attempt == 1 {
                    setPhase(request, .waitingToRetry(afterSeconds: 0, attempt: attempt))
                    return .reattachNow
                }
                let interval = backoff.missed()
                setPhase(request, .waitingToRetry(afterSeconds: interval, attempt: attempt))
                return .retryAfter(interval)
            case .linkDropped:
                guard attempt < configuration.attemptsPerRecording else {
                    setPhase(request, .failed(PocketTransferQueuePresentation.gaveUpLine))
                    return .reattachNow
                }
                // THE DEVICE LEFT. Do not hammer: the shipped presence schedule —
                // 60/120/240/300 s — paces the re-attach, and the item says both the wait and
                // that the retry is from the beginning.
                let interval = backoff.missed()
                setPhase(request, .waitingToRetry(afterSeconds: interval, attempt: attempt))
                return .retryAfter(interval)
            case nil:
                switch outcome.outcome {
                case .broughtOver(_, let captureID, _):
                    attemptsByRequest[request] = 0
                    setPhase(request, .broughtOver(captureID: captureID))
                case .alreadyHeld(let captureID):
                    setPhase(request, .alreadyHeld(captureID: captureID))
                case .unreadableRecording:
                    // The recorder answered and the answer was unusable. The session itself
                    // survives a malformed answer, so the next item proceeds on it.
                    setPhase(request,
                             .failed(PocketBringOverPresentation.unreadableRecordingLine))
                case .recorderUnavailable(let line):
                    // An authentication-shaped failure mid-session: this session is suspect.
                    // The item is reported and the rest gets a fresh session.
                    setPhase(request, .failed(line))
                    return .reattachNow
                case .transferIncomplete:
                    // Cut short with no radio interruption: custody would not take the bytes.
                    // Retrying on the same session cannot fix a disk.
                    setPhase(request,
                             .failed(PocketBringOverPresentation.transferIncompleteLine))
                }
            }
        }
        return .finished
    }

    // MARK: - Small parts

    /// Cancel FIRST, teardown SECOND — the order is load-bearing. The task's cancellation flag
    /// is what makes the wake-up the teardown delivers read as `.cancelled` (a stop) rather
    /// than `.disconnected` (a link drop the recorder never had).
    private func cancelCurrent() {
        currentWork?.cancel()
        currentAttachment?.teardown()
    }

    private func nextRunnable() -> PocketTransferItem? {
        items.first {
            !$0.phase.isFinished && !stoppedRequests.contains($0.recording.request)
        }
    }

    private func markRunnableFailed(_ line: String) {
        for item in items
        where !item.phase.isFinished && !stoppedRequests.contains(item.recording.request) {
            setPhase(item.recording.request, .failed(line))
        }
    }

    private func markRemainingStopped() {
        for item in items where !item.phase.isFinished {
            setPhase(item.recording.request, .stopped)
        }
    }

    private func setPhase(_ request: PocketRecordingRequest, _ phase: PocketTransferPhase) {
        if let index = items.firstIndex(where: { $0.recording.request == request }) {
            items[index].phase = phase
        }
        phaseSink?(request, phase)
    }
}

#endif
