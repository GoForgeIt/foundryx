// PocketTransferControls.swift — WHICH TRANSFER CONTROLS THE RECORDER PAGE OFFERS, AS A RULE IN
// THE KIT INSTEAD OF A BUTTON IN `App/`.
//
// TWO GAPS THIS FILE CLOSES, both recorded through the anvil op log by the agent that landed the
// durable queue, as the reason it declined to mark its own tracks complete:
//
//   GAP 1 — THERE WAS NO STOP CONTROL AT ALL. `PocketTransferQueue.stop(_:)`
//   (`PocketTransferJob.swift`) had NO production caller of any kind, and `stopAll()` had exactly
//   one — inside `PocketRecorderCheckModel.cancel()`, which is lifecycle handling and not a
//   button. `grep '"Stop' App/DeviceScreen.swift` returned nothing, while four OTHER screens in
//   this app ship Stop buttons. So the shipped contract was the INVERSE of the one this track
//   promises: Nick's words are *"only a stop button should stop the pull, or disconnecting or
//   losing connection to the device"*, and after the page-survival fix landed, leaving the page
//   no longer stopped a transfer either. A pull had no owner-reachable exit whatsoever.
//
//   GAP 2 — THE QUEUE ONLY EVER HELD ONE ITEM. Production's single `enqueue` call site passed
//   `[recording]` — a one-element array holding the file the owner tapped. `PocketTransferQueue`
//   CAN drain N recordings over one authenticated session and its Brine suite proves it does, by
//   enqueuing its own two-item fixture directly. Production never supplied more than one, so the
//   one-session advantage — the entire reason the queue exists — was unexercised on the real
//   path, and `PocketTransferQueue.derivedBacklog(from:custody:identity:)`, which computes the
//   backlog in the kit, had ZERO callers anywhere, tests included.
//
// WHY THE RULE LIVES HERE AND NOT AT THE BUTTON. `swift test` cannot compile `App/`. A control
// expressed only as a `Button` in `App/DeviceScreen.swift` is a control no test in this
// repository can see, which is exactly how a queue with a `stop` API shipped with no way to stop
// it — the API's existence was mistaken for the owner's ability. So the DECISION (which controls
// exist, in which state) and the STRINGS (what each says) are here, where Brine holds them, and
// `App/` is left with wiring only. The wiring itself is held separately, by the production
// reachability register, whose rows for these two capabilities anchor on the INVOCATION rather
// than on a construction that would survive deleting the call.

import Foundation

/// ONE CONTROL THE RECORDER PAGE OFFERS FOR MOVING RECORDINGS.
public struct PocketTransferControl: Sendable, Equatable {

    /// WHAT A TAP DOES, AS A VALUE. Named acts rather than closures so a scenario can assert
    /// which control is on the page without rendering one, and so `App/` cannot invent a fifth
    /// behaviour without adding a case here first — where a test will see it.
    public enum Act: String, Sendable, Equatable, CaseIterable {
        /// The owner's stop. Maps to `PocketTransferQueue.stopAll()`.
        case stopEverything
        /// Empty the recorder: enqueue `PocketTransferQueue.derivedBacklog`, in one session.
        case bringEverythingOver
        /// The single file `PocketBringOver.offered` elects — the affordance that already
        /// shipped, kept because a person who wants one recording should not have to take all.
        case bringOneOver
    }

    public let act: Act
    public let title: String

    /// WHETHER THE CONTROL IS LIVE, AND IT IS DECIDED HERE.
    ///
    /// IT USED TO BE DECIDED IN `App/`, and an adversarial review found that the scenario
    /// asserting "no control the page offers is disabled while nothing is running" could not
    /// observe it at all — `PocketTransferControl` had no such field, so the check degenerated
    /// into "the list is not empty" and `.disabled(true)` in the view left it green. A rule the
    /// page's own test cannot see is the exact defect this whole file exists to close, and it
    /// had reappeared one field down.
    ///
    /// THE STOP IS THE ONE CONTROL A BUSY PAGE MUST NOT DISABLE: every other transfer
    /// affordance is held by "no other errand is running", which is false for the entire
    /// duration of the errand the stop exists to end.
    public let isEnabled: Bool

    public init(act: Act, title: String, isEnabled: Bool) {
        self.act = act
        self.title = title
        self.isEnabled = isEnabled
    }
}

public enum PocketTransferControlsPresentation {

    /// THE WORD THAT WAS MISSING FROM THE ENTIRE RECORDER SURFACE. Bare, because the thing it
    /// stops is named by the band directly above it; "Stop transfer" beside a progress line that
    /// already names the recording is the label saying it twice.
    public static let stopAction = "Stop"

    /// WHAT STOPPING COSTS, SAID BEFORE IT IS PRESSED AND NOT AFTER.
    ///
    /// The wire admits no offset and custody keeps no partial, so a stop discards everything
    /// transferred so far — and this surface's standing rule is that a person watching a long
    /// transfer is told that rather than shown a bar that quietly returns to zero. The
    /// after-the-fact sentence already exists (`PocketTransferQueuePresentation.stoppedLine`);
    /// this is the same fact in the tense the owner is in while deciding.
    public static let stopConsequenceLine =
        "Stopping keeps nothing — this recording would start again from the beginning."

    /// EMPTY THE RECORDER. The count is IN the title because "Bring them all over" beside a
    /// shelf the owner has not counted is a control whose cost is invisible, and every one of
    /// these is a full-length Bluetooth transfer.
    ///
    /// `nil` for a backlog of zero or one: with nothing to batch, this control would be a second
    /// button doing what `bringOneOver` already does, and a page that offers the same act twice
    /// is how a person learns the two buttons must differ in some way they cannot see.
    ///
    /// A NEGATIVE COUNT IS NOT A SMALL ONE. It cannot arise from `derivedBacklog`, whose result
    /// is an array — but this is a public entry point taking an `Int`, and an adversarial review
    /// pointed out that `-1` simply made the control vanish, which is indistinguishable from an
    /// empty recorder. `nil` is the same answer either way here, so the guard is stated as
    /// `1 <` rather than `> 1` at a boundary somebody could later move past zero by accident.
    public static func bringEverythingAction(backlogCount: Int) -> String? {
        guard backlogCount > 1 else { return nil }
        return "Bring all \(backlogCount) over"
    }

    /// THE ONE PLACE THE PAGE'S TRANSFER CONTROLS ARE DECIDED.
    ///
    /// - Parameter transferInFlight: is a durable transfer running right now. This is the whole
    ///   hinge: while one is, the ONLY transfer control is the stop — starting a second is what
    ///   the one-radio-one-errand rule already forbids, and offering a disabled start beside a
    ///   live transfer is the "looks enabled, does nothing" shape this page has shipped twice.
    /// - Parameter backlogCount: how many recordings the recorder holds that this phone does
    ///   not — `PocketTransferQueue.derivedBacklog(…).count`, never the raw shelf count.
    ///
    /// - Parameter otherErrandRunning: some OTHER errand — a shelf check, a removal — holds the
    ///   radio. It decides `isEnabled`, and it decides it HERE rather than at the button,
    ///   because a rule spelled in `App/` is a rule the suite cannot execute.
    ///
    /// THE TWO HALVES ARE A PAIR, and neither may be asserted alone. "A stop is offered while a
    /// transfer runs" is satisfied by a page that offers a stop ALWAYS — which is a button that
    /// stops nothing whenever nothing is running. So the negative half is part of the rule: with
    /// no transfer in flight there is NO stop.
    public static func controls(transferInFlight: Bool,
                                backlogCount: Int,
                                otherErrandRunning: Bool = false) -> [PocketTransferControl] {
        if transferInFlight {
            // THE STOP IS ALWAYS LIVE. The errand it ends is itself the reason the page is busy,
            // so holding it to "nothing else is running" would grey it out exactly while there
            // is something to stop.
            return [PocketTransferControl(act: .stopEverything, title: stopAction,
                                          isEnabled: true)]
        }
        var controls: [PocketTransferControl] = []
        if backlogCount >= 1 {
            controls.append(PocketTransferControl(act: .bringOneOver,
                                                  title: PocketBringOverPresentation.actionTitle,
                                                  isEnabled: !otherErrandRunning))
        }
        if let title = bringEverythingAction(backlogCount: backlogCount) {
            controls.append(PocketTransferControl(act: .bringEverythingOver, title: title,
                                                  isEnabled: !otherErrandRunning))
        }
        return controls
    }

    /// THE ANSWER A TAP EARNS WHEN THE BACKLOG TURNED OUT TO BE EMPTY.
    ///
    /// The count on the button is taken at the last shelf statement, and custody can move under
    /// it — an import finishing, another leg landing the same file. So a tap can arrive at a
    /// genuinely empty backlog, and an entry point that returned silently there would be a live
    /// control that consumes the tap and shows nothing. Found by an adversarial review, which
    /// named the exact sequence: display "Bring all 12 over", let custody acquire all twelve,
    /// then tap.
    public static let nothingLeftToBringLine =
        "Every recording on the recorder is already on this iPhone."

    /// Every string this family can put in front of a person, for the copy scans that take the
    /// union of the families' populations. A family without one is a family the gates CANNOT
    /// SEE — the defect that let an unmeasured speed claim ship on the fast-sync offer.
    public static var everyLine: [String] {
        [stopAction, stopConsequenceLine, nothingLeftToBringLine]
            + [2, 12].compactMap { bringEverythingAction(backlogCount: $0) }
    }
}
