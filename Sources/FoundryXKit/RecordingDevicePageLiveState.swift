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

// MARK: - What the re-read actually found

/// THE THREE ANSWERS A RE-READ CAN GIVE, KEPT APART.
///
/// THE DEFECT THIS TYPE EXISTS TO END. `RecordingDevicePageFacts.refreshed` was
///
///     guard let store = RecordingDeviceStore.current(),
///           let records = try? store.records(),
///           let record = records.first(where: { $0.identity == input.identity })
///     else { return input }
///
/// — three conditions and ONE silent `return input`. Exactly one of the three justifies that
/// answer. A recorder the store no longer holds keeps what it was pushed with, deliberately:
/// the alternative is a page blanking its own numbers one frame before it is dismissed, a
/// flash of "nobody ever asked" over a device the account is in the middle of deleting.
///
/// The other two are not that. `RecordingDeviceStore.current()` returning nil means NO ACCOUNT
/// SCOPE RESOLVED — the process could not say whose recorder this is. `try? store.records()`
/// swallowing a throw means the account's file is on disk and UNREADABLE, which
/// `readLocked()` goes out of its way to raise rather than report as "no devices", precisely
/// because reporting it as absence "would silently un-pair every device the person owns". Both
/// were then rendered as the same confident page: the last numbers the recorder stated, under
/// "read 4 minutes ago", with no indication that the phone had just failed to check.
///
/// `observedAt` IS THE RECORDER'S CLOCK-TIME ON THIS PHONE, not the freshness of the read. So
/// a stale figure under a confident age is not a rounding problem — it is the page asserting
/// something it did not verify.
public enum RecordingDevicePageReReading: Equatable, Sendable {
    /// The account's facts for this recorder, as they stand on disk right now.
    case refreshed([String: RecordingDeviceReading])
    /// The store answered, and it is not holding this recorder any more. The ONE condition
    /// under which keeping the pushed value is the honest answer.
    case deviceNotFound
    /// No account binding resolved, so nothing could be asked on anyone's behalf.
    case noAccountScope
    /// The account's device file exists and could not be decoded.
    case storeUnreadable(String)
}

public enum RecordingDevicePageFacts {

    /// THE SENTENCE A PAGE OWES SOMEBODY WHOSE FACTS IT COULD NOT READ.
    ///
    /// It does not blank the numbers — they are still the last thing the recorder actually
    /// said, and they are the most useful thing on the screen. What it withdraws is the
    /// page's implicit claim to have just checked them.
    public static let factsUnreadableNote =
        "Solleva couldn't read what this account has saved for this recorder just now, so "
        + "these numbers may be older than they say."

    /// WHAT THE ACCOUNT HOLDS FOR THIS RECORDER RIGHT NOW.
    ///
    /// OFF THE MAIN ACTOR AT EVERY CALL SITE, and it is not optional politeness:
    /// `RecordingDeviceStore.current()` resolves the account binding — a process-wide lock plus
    /// an on-disk admission-registry read — and then decodes a JSON file. That is the per-row
    /// main-actor disk read `LazyView` exists to prevent, and it belongs on a utility queue in
    /// response to an errand ending, never inside a body pass.
    ///
    /// IT TAKES AN IDENTITY, NOT THE PAGE'S INPUT, so that nothing about what the page is
    /// currently rendering can reach the disk read — and so the answer cannot be quietly
    /// folded back into the caller's stale value the way `refreshed(_:)` did.
    public static func reRead(_ identity: RecordingDeviceIdentity)
        -> RecordingDevicePageReReading {
        guard let store = RecordingDeviceStore.current() else { return .noAccountScope }
        let records: [RecordingDeviceRecord]
        do {
            records = try store.records()
        } catch {
            return .storeUnreadable(error.localizedDescription)
        }
        guard let record = records.first(where: { $0.identity == identity })
        else { return .deviceNotFound }
        return .refreshed(record.readings)
    }

    /// THE READINGS THE PAGE RENDERS, out of the value the list pushed into it and the value a
    /// re-read produced.
    ///
    /// THE DEFECT THIS ENDS. The page held the re-read in `@State private var refreshedInput`
    /// and rendered `refreshedInput ?? input`. That latches: the first errand to finish makes
    /// it non-nil, and from that instant every value the list pushes into the page is
    /// overridden for the life of the screen — so a number the LIST measured after the page's
    /// own last re-read could never be shown. One stale read, and the page was stale forever.
    ///
    /// NEWEST WINS, AND WHOLESALE. Both maps are snapshots of the same account store, so the
    /// later snapshot is simply the better one and its absences are real absences. Merging
    /// them per key would resurrect a fact the account has since dropped — the same reason
    /// `withReadings` replaces rather than merges while the STORE merges.
    ///
    /// A MAP WITH NOTHING IN IT LOSES TO ONE THAT HAS SOMETHING. `nil` is not an instant, and
    /// the page's own rule for a recorder the store cannot speak for is to keep what it was
    /// pushed with rather than flash "nobody ever asked" — see `deviceNotFound` above.
    /// A RE-READ THAT FAILED TAKES NOTHING AWAY, and that is why this takes the last map that
    /// was successfully read rather than the latest outcome. A page that lost its numbers
    /// because it could not confirm them would be throwing away the only true thing it has —
    /// the last figures the recorder itself stated — over a problem with a file on this phone.
    /// What a failed read withdraws is the CLAIM to have just checked, and `note(for:)` owns
    /// that.
    public static func readings(pushed: [String: RecordingDeviceReading],
                                lastRead: [String: RecordingDeviceReading]?)
        -> [String: RecordingDeviceReading] {
        guard let found = lastRead else { return pushed }
        guard let heardInPushed = pushed.values.map(\.observedAt).max() else { return found }
        guard let heardInReRead = found.values.map(\.observedAt).max() else { return pushed }
        return heardInPushed > heardInReRead ? pushed : found
    }

    /// WHAT THE PAGE SAYS ABOUT THE READ ITSELF, or nothing when there is nothing to say.
    ///
    /// `nil` for a re-read that has not happened and for one that found the account's facts.
    /// `nil` for `deviceNotFound` too: the account answered, and it is not holding this
    /// recorder — which the page states by other means the moment the list drops the row.
    public static func note(for reRead: RecordingDevicePageReReading?) -> String? {
        switch reRead {
        case .none, .refreshed, .deviceNotFound:
            return nil
        case .noAccountScope, .storeUnreadable:
            return factsUnreadableNote
        }
    }
}
