// PocketTransferWiring.swift — THE THREE DECISIONS A RECORDER PAGE WOULD OTHERWISE MAKE IN A
// SwiftUI BODY, MOVED WHERE `swift test` CAN EXECUTE THEM.
//
// `PocketTransferQueue` shipped with no production caller, and the row that says so
// (`pocket-transfer-queue-run`) named the reason: the page still owned its transfer as a Task
// on a `@StateObject`, with `.onDisappear { check.cancel() }` underneath it. Wiring the page to
// the queue is three decisions, and every one of them is the kind that has already shipped
// wrong in this file's neighbourhood BECAUSE it was written in a view:
//
//   1. WHAT LEAVING THE PAGE DOES. It was an unconditional `cancel()` in a modifier — the whole
//      defect, since a bring-over measured at 18-36 KB/s is exactly the errand a person walks
//      away from. `.onDisappear` cannot be executed by anything in this repository, so the rule
//      shipped unread; `PocketErrandScenePhasePolicy` is the same rule for the scene phase and
//      it lives in the kit for the same reason (a `phase != .active` comparison in a body once
//      made TAKING A SCREENSHOT kill a transfer).
//   2. WHAT A FINISHED PHASE OBLIGES THE APP TO DO. The old tail branched on
//      `outcome.captureID != nil` and did four things under it, one of which — handing the
//      capture to `CaptureManager` — is the difference between a recording a person can read
//      and a directory nothing in the running app knows exists.
//   3. WHICH READINGS ARE WORTH WAKING A SCREEN FOR. The queue reports every chunk
//      synchronously on the radio path, by design; at the measured 18-36 KB/s over ~180-byte
//      notifications that is 100-200 readings a second. Publishing each one is a `@Published`
//      write and a SwiftUI invalidation per BLE notification, which is the shape that has cost
//      this program main-thread time before. The coalescing rule is a rule, so it is here.

import Foundation

// MARK: - Leaving the page

/// WHAT A DEPARTURE DOES TO THE ERRAND THAT IS ALREADY RUNNING.
public enum PocketErrandDeparture: Sendable, Equatable {
    /// Stop it, tear the radio down, and say so. Right for work whose ONLY point is the screen
    /// that asked for it.
    case stopTheErrand
    /// Leave it alone. The bytes are the point, not the page.
    case leaveItRunning
}

/// THE RULE THE RECORDER PAGE'S `.onDisappear` ASKS.
///
/// A CHECK IS STOPPED AND A TRANSFER IS NOT, and the asymmetry is the whole fix. A check reads
/// a shelf to draw a page: with the page gone there is nothing left for its answer to land on,
/// and a `CBCentralManager` held open for it is battery spent on nobody's behalf. A bring-over
/// is custody moving — the file lands on this phone and becomes a conversation whether or not
/// anybody is watching the bar — and it is measured in tens of minutes, so "the owner looked at
/// something else" is the ORDINARY case rather than an abandonment.
///
/// A REMOVAL IS STOPPED TOO, and deliberately: it is destructive, it is short, and a
/// destructive errand that outlives the screen that authorised it is the one thing this surface
/// must never do.
///
/// AND THE SUBJECT ALONE IS NOT ENOUGH TO DECIDE, which is the trap this signature exists to
/// avoid. The FAST SYNC — the WiFi leg — records itself under the very same `bring-over`
/// subject token, and it is NOT a durable job: its whole tail sits behind the page's model, so
/// left running past a departure it would publish into nothing, never reach `finishErrand`, and
/// never give back the background-time assertion it took — which is how iOS terminates an app.
/// So the caller states the fact (is a durable queued job actually driving this?) and the rule
/// is written over both.
public enum PocketErrandDeparturePolicy {
    public static func decide(_ inFlight: PocketErrandInFlight?,
                              isDurableJob: Bool) -> PocketErrandDeparture {
        // NOTHING IS RUNNING. `cancel()` is silent in that case and stays the answer, so a
        // departure from an idle page still releases whatever a lease or a token is holding.
        guard let inFlight else { return .stopTheErrand }
        guard inFlight.subject == PocketErrandCommand.bringOverSubject else {
            return .stopTheErrand
        }
        return isDurableJob ? .leaveItRunning : .stopTheErrand
    }
}

// MARK: - What a phase obliges the app to do

/// WHAT THE RUNNING APP OWES ONE QUEUED RECORDING AT THIS PHASE.
///
/// Every field is a thing the old bring-over tail did inline behind `if let captureID`, which
/// is a branch no test in this repository could reach: it was in `App/`.
public struct PocketTransferFollowThrough: Sendable, Equatable {
    /// The conversation to hand to the capture owner, or `nil`. WITHOUT THIS HAND-OFF the
    /// recording is a complete, correct capture directory that nothing in the running app knows
    /// exists — `loadExisting()` runs once, at construction — so it sits un-uploaded until the
    /// next launch.
    public let adoptCaptureID: String?
    /// Custody moved, so the shelf this page is drawing is now stale and the safety evidence
    /// behind it was taken before this recording existed. Both have to be re-taken.
    public let custodyMoved: Bool
    /// This recording's journey through the queue is over — the errand may be closed.
    public let isFinished: Bool
    /// The sentence to show, or `nil` for a phase that says nothing (a recording waiting its
    /// turn is not an announcement).
    public let line: String?
    /// The CLOSED token `errand.stop` records, or `nil` while the errand is still running. It
    /// is never the diagnostic sentence: the wire form is space-separated `key=value`, so an
    /// outcome carrying spaces corrupts every parser downstream.
    public let outcomeToken: String?

    public init(adoptCaptureID: String?, custodyMoved: Bool, isFinished: Bool,
                line: String?, outcomeToken: String?) {
        self.adoptCaptureID = adoptCaptureID
        self.custodyMoved = custodyMoved
        self.isFinished = isFinished
        self.line = line
        self.outcomeToken = outcomeToken
    }

    /// THE WHOLE BRANCH, AS A VALUE.
    ///
    /// `alreadyHeld` ADOPTS TOO, and that is not an oversight carried forward: the bytes and
    /// the conversation were already on this phone, and the running app may still never have
    /// been told about the capture — which is the same invisible-recording defect as a fresh
    /// transfer's, arrived at down a cheaper road.
    public static func decide(_ phase: PocketTransferPhase) -> PocketTransferFollowThrough {
        let line = PocketTransferQueuePresentation.line(for: phase)
        switch phase {
        case .broughtOver(let captureID, _):
            return .init(adoptCaptureID: captureID, custodyMoved: true, isFinished: true,
                         line: line, outcomeToken: DoorLog.succeeded)
        case .alreadyHeld(let captureID):
            return .init(adoptCaptureID: captureID, custodyMoved: true, isFinished: true,
                         line: line, outcomeToken: "already-held")
        case .stopped:
            return .init(adoptCaptureID: nil, custodyMoved: false, isFinished: true,
                         line: line, outcomeToken: "stopped")
        case .failed(let reason):
            return .init(adoptCaptureID: nil, custodyMoved: false, isFinished: true,
                         line: line, outcomeToken: Self.token(forFailure: reason))
        case .queued, .starting, .transferring, .waitingToRetry:
            return .init(adoptCaptureID: nil, custodyMoved: false, isFinished: false,
                         line: line, outcomeToken: nil)
        }
    }

    /// WHAT A DRAIN OF N RECORDINGS LEFT BEHIND IT — every hand-off, not just the first item's.
    ///
    /// THE DEFECT THIS EXISTS FOR. The production caller read `await queue.snapshot.first?.phase`
    /// and decided from that ONE item, which was correct only because production could never
    /// enqueue more than one. The moment the queue is handed the backlog, deciding from
    /// `.first` adopts ONE conversation and silently drops the rest — the invisible-recording
    /// defect `PocketTransferFollowThrough` was written to prevent, reintroduced by the
    /// batch it was written for.
    ///
    /// THE LINE IS A COUNT AND NOTHING ELSE. A count is unit-free and every one of its terms was
    /// observed by the queue itself, which is the only kind of number this surface is allowed to
    /// print — the recorder's listing figure has been rendered wrongly twice and its unit is
    /// still unresolved. So there is no size here, no rate and no estimate: how many were
    /// brought over, and how many are still on the recorder.
    public struct Batch: Sendable, Equatable {

        /// ONE RECORDING THAT LANDED: the conversation to hand over, AND the recorder's own name
        /// for the file it came from, IN THE SAME VALUE.
        ///
        /// THEY USED TO BE TWO PARALLEL ARRAYS and `App/` paired them BY INDEX. An adversarial
        /// review named it: they aligned only because today's phases happen to produce an
        /// adoption id and set `custodyMoved` together, so correctness was an incidental
        /// invariant of how the two arrays were built rather than a property of the type. A
        /// future phase where the two diverge would adopt capture A and log it against
        /// recording B, and no test over either array alone could see it. Pairing them here
        /// makes the misalignment unrepresentable.
        public struct Landed: Sendable, Equatable {
            /// WITHOUT THIS HAND-OFF the recording is a complete, correct capture directory
            /// that nothing in the running app knows exists — `loadExisting()` runs once, at
            /// construction — so it sits un-uploaded until the next launch.
            public let captureID: String
            /// `<date>/<timestamp>`, and it is the exact key the owner-armed clear's candidate
            /// set is built from. A recording missing from that set can never be cleared.
            public let token: String
            public init(captureID: String, token: String) {
                self.captureID = captureID
                self.token = token
            }
        }

        /// Every recording that landed, in queue order.
        public let landed: [Landed]
        /// Every item reached a terminal phase.
        public let isFinished: Bool
        public let line: String?
        public let outcomeToken: String?

        public init(landed: [Landed], isFinished: Bool, line: String?, outcomeToken: String?) {
            self.landed = landed
            self.isFinished = isFinished
            self.line = line
            self.outcomeToken = outcomeToken
        }
    }

    /// AN EMPTY QUEUE IS NOT A SUCCESSFUL ONE. A drain that lost every item reports the same
    /// incomplete transfer a single lost item reported, rather than an empty batch that reads
    /// as "nothing to do" — which is the silence the whole errand vocabulary refuses.
    public static func decide(batch items: [PocketTransferItem]) -> Batch {
        guard !items.isEmpty else {
            return Batch(landed: [], isFinished: true,
                         line: PocketBringOverPresentation.transferIncompleteLine,
                         outcomeToken: "transfer-incomplete")
        }
        // ONE ITEM IS NOT A BATCH, and it may not read like one. "1 of 1 brought over" for the
        // single tap that has always existed would be a regression in words: the person asked
        // for one recording and the sentence about it already exists and says more.
        if items.count == 1 {
            let one = decide(items[0].phase)
            return Batch(landed: landed(items[0], one), isFinished: one.isFinished,
                         line: one.line, outcomeToken: one.outcomeToken)
        }
        let decided = items.map { ($0, decide($0.phase)) }
        let finished = decided.allSatisfy { $0.1.isFinished }
        let landedItems = decided.flatMap { landed($0.0, $0.1) }
        // BROUGHT OVER IS NOT THE SAME WORD AS ALREADY HELD, and an adversarial review caught
        // this counting them together: a five-item queue whose five phases were all
        // `.alreadyHeld` reported "5 of 5 brought over" when the session had transferred
        // nothing. `.alreadyHeld` still ADOPTS — the running app may never have been told
        // about a capture whose bytes were on the phone all along — so it belongs in `landed`.
        // It does not belong in a sentence with the verb "brought over" in it.
        let transferred = decided.filter { if case .broughtOver = $0.0.phase { return true }
                                           else { return false } }.count
        let alreadyHeld = decided.filter { if case .alreadyHeld = $0.0.phase { return true }
                                           else { return false } }.count
        return Batch(
            landed: landedItems,
            isFinished: finished,
            line: finished ? batchLine(broughtOver: transferred, of: items.count,
                                       alreadyHeld: alreadyHeld) : nil,
            // THE TOKEN IS COUNTED TOO, because a drain that moved nothing and a drain that
            // moved everything are the same word — "batch" — to every parser downstream, and
            // the command log is where a failing night gets diagnosed from.
            outcomeToken: finished ? "batch-\(transferred)-of-\(items.count)" : nil)
    }

    /// WHAT THE PAGE SAYS AFTER A DRAIN. Counts only — no size, no rate, no estimate. The
    /// recorder's listing unit is still unresolved and this surface has printed an invented
    /// magnitude three times; a count is unit-free and every term of it was observed by the
    /// queue itself.
    ///
    /// EVERY TERM IS CLAMPED INTO THE POPULATION IT DESCRIBES. An adversarial review put
    /// `(broughtOver: 99, of: 2)` through the first draft and got "99 of 2 brought over" with
    /// nothing remaining — a nonsense that reads as an emphatic success. A count that cannot be
    /// true of the queue it describes is corrupt input, and the honest rendering of corrupt
    /// input is not a confident sentence.
    public static func batchLine(broughtOver: Int, of total: Int, alreadyHeld: Int = 0) -> String {
        let total = max(0, total)
        let brought = min(max(0, broughtOver), total)
        let held = min(max(0, alreadyHeld), total - brought)
        let remaining = total - brought - held
        var line = "\(brought) of \(total) brought over."
        // SAID SEPARATELY, because "brought over" is a claim about the radio. A recording this
        // phone already had did not come over anything.
        if held > 0 {
            line += " \(held) " + (held == 1 ? "was" : "were") + " already on this iPhone."
        }
        guard remaining > 0 else { return line + " Nothing is left on the recorder to bring." }
        return line + " \(remaining) " + (remaining == 1 ? "is" : "are")
            + " still on the recorder."
    }

    private static func landed(_ item: PocketTransferItem,
                               _ decided: PocketTransferFollowThrough) -> [Batch.Landed] {
        guard let captureID = decided.adoptCaptureID, decided.custodyMoved else { return [] }
        return [Batch.Landed(captureID: captureID,
                             token: item.recording.date + "/" + item.recording.timestamp)]
    }

    /// A FAILURE IS FOUR DIFFERENT DIAGNOSES AND THE PHASE CARRIES ONLY A SENTENCE, so the
    /// sentence is what they are told apart by — against the SHIPPED constants, never against a
    /// substring, so a copy edit moves this mapping rather than silently defaulting it.
    ///
    /// The default is `recorder-unavailable` because the one failure line this queue renders
    /// that is NOT one of the three constants is the attach seam's own, and that seam's whole
    /// vocabulary is "the recorder could not be reached".
    private static func token(forFailure reason: String) -> String {
        switch reason {
        case PocketBringOverPresentation.unreadableRecordingLine:   return "unreadable"
        case PocketBringOverPresentation.transferIncompleteLine:    return "transfer-incomplete"
        case PocketTransferQueuePresentation.gaveUpLine:            return "gave-up"
        default:                                                    return "recorder-unavailable"
        }
    }
}

// MARK: - Which readings reach a screen

/// WHICH OF THE QUEUE'S READINGS IS WORTH WAKING A SCREEN FOR.
///
/// The queue's `PhaseSink` is called synchronously from the radio path and its own
/// documentation says coalescing belongs above that seam. This is above it, and it is a CLASS
/// rather than a free function because the rule needs the previous reading: "has the whole
/// percent changed" cannot be answered by a policy that is handed one number.
///
/// EVERY PHASE THAT IS NOT A PROGRESS READING IS ADMITTED, ALWAYS. A start, a retry wait, a
/// stop and an ending are each one event, and dropping one of them to save a redraw would lose
/// the sentence rather than the frame.
public final class PocketTransferProgressReporter: @unchecked Sendable {
    private let lock = NSLock()
    private var last: PocketTransferPhase?

    public init() {}

    /// Record this reading and answer whether a screen should be told about it.
    public func admit(_ phase: PocketTransferPhase) -> Bool {
        lock.withLock {
            let verdict = Self.isWorthReporting(previous: last, next: phase)
            // ONLY AN ADMITTED READING BECOMES THE BASELINE. Storing every reading would make
            // the comparison "did the percent change since the last CHUNK" — which is true
            // roughly never at 180 bytes a notification, and would suppress the bar entirely
            // for a long file.
            if verdict { last = phase }
            return verdict
        }
    }

    /// THE RULE. Two `.transferring` readings collapse unless the whole percent moved or the
    /// recorder restated its total; everything else is an event and is always reported.
    public static func isWorthReporting(previous: PocketTransferPhase?,
                                        next: PocketTransferPhase) -> Bool {
        guard case .transferring(_, let nextAnnounced) = next else { return true }
        guard case .transferring(_, let lastAnnounced)? = previous else { return true }
        // A DIFFERENT DENOMINATOR IS A DIFFERENT FILE, not a smoother bar.
        guard lastAnnounced == nextAnnounced else { return true }
        return wholePercent(next) != wholePercent(previous)
    }

    private static func wholePercent(_ phase: PocketTransferPhase?) -> Int? {
        guard let fraction = phase?.fraction else { return nil }
        return Int(fraction * 100)
    }
}
