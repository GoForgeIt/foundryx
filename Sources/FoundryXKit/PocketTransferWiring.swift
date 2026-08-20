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
