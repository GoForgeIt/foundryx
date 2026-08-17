// RecordingDevicePageLiveState — the recorder page's OWN live state, and the re-read that
// keeps it true.
//
// TWO HALVES OF ONE DEFECT, MEASURED ON THE SHIPPED SCREEN.
//
//   1. NOTHING RE-READ WHAT A CHECK WROTE. `PocketRecorderCheck` reads a recorder's charge,
//      its firmware and how full it is and persists all three against that recorder
//      (`RecordingDeviceStore.recordObservedFacts`) — before it even attempts the listing, so
//      the facts survive a recorder that refuses to say what it is holding. The page renders
//      `page.readings`, which comes from the `RecordingDeviceListInput` captured when the row's
//      `NavigationLink` was pushed; `RecordingDeviceListModel.refresh` fires only on the Omi's
//      connection state, its battery, `saved` or `sources`, and a check on a record-then-sync
//      recorder touches none of those. So the shelf filled with recordings while Battery, Free
//      space and Firmware each went on offering "Connect and check now" — over numbers already
//      sitting on the phone's disk. The offer to go and ask, printed beside an answer.
//
//   2. THE HEADER CLAIMED A LINK THIS DEVICE CLASS NEVER HAS. `page.status` was
//      `input.link.label` for every class. A record-then-sync recorder is never held open: a
//      check opens its own authenticated session, reads, and closes it again, and the
//      composition has no live link to put in that map at all — so the header read "Not
//      connected" while Solleva was on the line listing that recorder's files. "Not connected"
//      there is not a fact about the recorder; it is the absence of a fact about a link that
//      does not exist, printed in the size a person reads first.
//
// WHAT REPLACES IT IS THE ONE LIVE THING THIS CLASS HAS: what a CHECK is doing. Three states,
// and each of them is something the phone actually knows — a check is running; the recorder
// answered, at an instant this phone's clock recorded; or nobody has ever asked.

import Foundation

// MARK: - What a check is doing

/// The live state of a recorder's page, which is the state of the LAST OR CURRENT CHECK and
/// never of a link.
public enum RecordingDeviceCheckState: Equatable, Sendable {
    /// Nobody has ever asked this recorder anything. NOT an error and not a degraded link —
    /// it is the resting state of every remembered recorder until the owner taps.
    case neverChecked
    /// A check is on the line with this recorder right now.
    case checking
    /// The recorder answered, at this instant on THIS PHONE'S clock. Never the recorder's own:
    /// a Pocket's clock is unset out of the box, so dating this by it would put the header in
    /// 1970 (`RecordingDeviceReading.observedAt` carries the same rule for the same reason).
    case answered(at: Date)

    /// - Parameters:
    ///   - isChecking: whether an errand is on the line right now.
    ///   - answeredAt: when the recorder last answered a LISTING on this screen, if it has.
    ///   - readings: the durable facts the account holds for this recorder.
    ///
    /// THE READINGS ARE PART OF THE ANSWER, AND THAT IS WHAT MAKES THIS SURVIVE A RELAUNCH.
    /// `answeredAt` is screen-lifetime state — it is nil on a page opened fresh, even for a
    /// recorder checked five minutes ago before the app was backgrounded. The readings are on
    /// disk with the instant each was heard, so the newest of them is the last time this
    /// recorder is KNOWN to have said anything. Taking the later of the two means a fresh page
    /// says when the recorder last answered instead of claiming nobody ever asked.
    public static func resolve(isChecking: Bool,
                               answeredAt: Date?,
                               readings: [String: RecordingDeviceReading])
        -> RecordingDeviceCheckState {
        if isChecking { return .checking }
        let heard = [answeredAt, readings.values.map(\.observedAt).max()].compactMap { $0 }.max()
        guard let heard else { return .neverChecked }
        return .answered(at: heard)
    }
}

// MARK: - What the header says

public extension RecordingDevicePage {

    /// A recorder nobody has ever asked. It states the absence of an ANSWER, which is true,
    /// rather than the absence of a LINK, which is not a thing this device has.
    static let neverCheckedStatus = "Not checked yet"

    /// A check is on the line. Present tense, because it is happening while this is read.
    static let checkingStatus = "Checking now…"

    /// When the recorder last answered. `elapsed` is the reading strip's own arithmetic, so
    /// the header and the line under it cannot round the same instant differently.
    static func answeredStatus(_ elapsed: String) -> String { "Answered \(elapsed)" }

    /// The header, from what a check is doing.
    static func status(for check: RecordingDeviceCheckState, now: Date) -> String {
        switch check {
        case .neverChecked:
            return neverCheckedStatus
        case .checking:
            return checkingStatus
        case .answered(let at):
            return answeredStatus(RecordingDeviceReadingPresentation.elapsed(from: at, to: now))
        }
    }

    /// Every header a record-then-sync recorder's page can render, so a claim about this
    /// surface's copy is held over the population rather than over whichever string somebody
    /// remembered. `answeredStatus` is sampled at one age; the words it varies are the reading
    /// strip's, and `RecordingDeviceReadingPresentation` owns holding those.
    static var everyCheckStatusLine: [String] {
        [neverCheckedStatus, checkingStatus, answeredStatus("just now")]
    }
}

// MARK: - Re-reading what a check wrote

public extension RecordingDeviceListInput {
    /// The same device, with the facts it has stated replaced wholesale.
    ///
    /// WHOLESALE IS RIGHT HERE AND MERGE IS RIGHT IN THE STORE, which is not a contradiction:
    /// the store merges because a session that read nothing must not erase what an earlier one
    /// learned, and this replaces because its argument IS the merged map the store just
    /// handed back. Merging again here would let a value the page was pushed with outlive a
    /// fact the account has since dropped.
    func withReadings(_ readings: [String: RecordingDeviceReading]) -> RecordingDeviceListInput {
        RecordingDeviceListInput(identity: identity,
                                 displayName: displayName,
                                 declaredCapabilities: declaredCapabilities,
                                 audioProfile: audioProfile,
                                 link: link,
                                 liveActivity: liveActivity,
                                 lastConnected: lastConnected,
                                 isRemembered: isRemembered,
                                 negotiatedProtocol: negotiatedProtocol,
                                 readings: readings)
    }
}

public enum RecordingDevicePageFacts {

    /// WHAT THE ACCOUNT HOLDS FOR THIS RECORDER RIGHT NOW, folded back into the value the page
    /// renders from.
    ///
    /// OFF THE MAIN ACTOR AT EVERY CALL SITE, and it is not optional politeness:
    /// `RecordingDeviceStore.current()` resolves the account binding — a process-wide lock plus
    /// an on-disk admission-registry read — and then decodes a JSON file. That is the per-row
    /// main-actor disk read `LazyView` exists to prevent, and it belongs on a utility queue in
    /// response to a check ending, never inside a body pass.
    ///
    /// A DEVICE THE STORE NO LONGER HOLDS KEEPS WHAT IT WAS PUSHED WITH. The alternative is a
    /// page that blanks its own numbers at the moment the owner forgets the recorder, one
    /// frame before the page is dismissed — a flash of "nobody ever asked" over a device the
    /// account is in the middle of deleting. Unreadable store, same answer, same reason.
    public static func refreshed(_ input: RecordingDeviceListInput) -> RecordingDeviceListInput {
        guard let store = RecordingDeviceStore.current(),
              let records = try? store.records(),
              let record = records.first(where: { $0.identity == input.identity })
        else { return input }
        return input.withReadings(record.readings)
    }
}
