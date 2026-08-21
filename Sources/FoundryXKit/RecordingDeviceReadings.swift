// RecordingDeviceReadings — a fact a recorder stated, together with WHEN it stated it.
//
// THE DEFECT THIS EXISTS FOR, MEASURED RATHER THAN ASSERTED.
//
//   1. `PocketRecordingDeviceBridge.observe` asked a connected recorder for its battery and
//      its firmware, packed them into a `RecordingDeviceObservation`, and the session then
//      closed. `RecordingDeviceAdoption.remember` persisted the identity and the display name
//      out of that observation and DROPPED the two facts. `RecordingDeviceRecord` had five
//      fields and none of them could hold a reading.
//
//   2. So the recorder's own page — which is composed from the store record, not from the
//      session — rendered `Battery: Unavailable` and `Firmware: Unavailable` one second after
//      a check that had just read 84% and 1.6, and went on rendering them for the life of the
//      device. "Unavailable" is a statement about Solleva wearing the costume of a fact about
//      the recorder.
//
//   3. And `APP&SPACE` — the one command that answers "how full is it" — had no production
//      caller at all. `PocketBLEClient.storage()` shipped decoded, unit-tested and unreached,
//      which is the register's own instance-1 defect with a different opcode.
//
// TWO STATES, AND DELIBERATELY NO THIRD. A fact is either READ — a value, and the moment it
// was read, always together — or NEVER ASKED, which renders no number, no dash, no zero and
// no last-known-good, and instead offers the action that would go and ask. `0%` for a battery
// nobody read is worse than `Unavailable`, not better: it is the same absence with a number
// painted over it.
//
// THE MERGE IS THE POINT OF THE WORD "DURABLE". A session that reads two facts REPLACES those
// two and leaves everything else alone; a session that reads nothing changes nothing. A store
// write that overwrote the map wholesale would let a recorder that answered nothing erase what
// an earlier session learned — and, worse, a re-stamped `observedAt` would make an hour-old
// number look like a fresh one, which is the failure mode this whole file exists to remove.

import Foundation

// MARK: - The durable fact

/// One fact a recorder stated, and the instant this phone heard it stated.
///
/// The two fields are inseparable ON PURPOSE. Every constructor takes both, so there is no
/// representable value that carries a number without carrying its age.
public struct RecordingDeviceReading: Codable, Equatable, Sendable {
    /// Exactly what will be shown. Formatting happens where what the recorder's numbers MEAN
    /// is known — percent for the battery, a fullness ratio for storage — not in a view. It
    /// used to say "kilobytes, percent"; the kilobytes were an assumption about `MCU&SPA` that
    /// nothing had measured, and `storageFullness` is where it went.
    public let value: String
    /// THIS PHONE'S CLOCK, at the moment the recorder answered. Never the recorder's own —
    /// a Pocket's clock is unset out of the box (`PocketConversationClock`), so dating a
    /// reading by it would put half the library in 1970.
    public let observedAt: Date

    public init(value: String, observedAt: Date) {
        self.value = value
        self.observedAt = observedAt
    }
}

// MARK: - One rendered line

/// One row of the recorder page's readings strip.
///
/// `value` and `observedAgo` are non-nil together or nil together, and `action` is exactly the
/// complement — the invariant the scenarios assert over every line rather than over the two a
/// test author remembered.
public struct RecordingDeviceReadingLine: Equatable, Sendable {
    public let label: String
    /// What the recorder said, or `nil` when nobody has ever asked. NEVER a plausible default.
    public let value: String?
    /// How long ago it said it, in words. Non-nil exactly when `value` is.
    public let observedAgo: String?
    /// The action that would go and ask. Offered exactly when `value` is `nil`: a stated
    /// absence with no way to end it is a shrug.
    public let action: String?

    public init(label: String, value: String?, observedAgo: String?, action: String?) {
        self.label = label
        self.value = value
        self.observedAgo = observedAgo
        self.action = action
    }

    /// A line that carries a real observation. The paired-existence half of every prohibition
    /// over this strip: a negative predicate passes vacuously on a blank pane.
    public var wasRead: Bool { value != nil }
}

// MARK: - The strip

public enum RecordingDeviceReadingPresentation {

    /// The facts a record-then-sync recorder can state, in the order they are shown.
    ///
    /// STORAGE SITS SECOND, not last, because it is the one a person opens this page to look
    /// at. `gapRecovery` is absent: it is a capability, not a reading — nothing is ever
    /// measured for it — and `offlineStorage` is absent because this row is what it was
    /// standing in for while nobody was asking `APP&SPACE`.
    ///
    /// The key is still spelled `freeSpace`: it is a persisted store key, and renaming it
    /// would silently orphan every reading an installed app has already kept.
    public static let order: [RecordingDeviceCapabilityKey] = [
        .batteryLevel, .freeSpace, .firmwareVersion,
    ]

    public static func label(for key: RecordingDeviceCapabilityKey) -> String {
        switch key {
        case .batteryLevel:    return "Battery"
        // "STORAGE", NOT "FREE SPACE". The reading beside it is now `99% full` — a ratio,
        // because the recorder's storage unit is unresolved (see `storageFullness`) — and
        // "Free space: 99% full" is a label and a value answering two different questions.
        case .freeSpace:       return "Storage"
        case .firmwareVersion: return "Firmware"
        default:               return key.rawValue
        }
    }

    public static var labels: [String] { order.map(label(for:)) }

    /// Every line this strip can draw, so a claim about this surface's COPY is held over the
    /// population rather than over whichever string somebody remembered. Named `everyLine` to
    /// match the other presentation families, because the gates that scan them take the union
    /// and a family missing this property is a family the gates cannot see.
    public static var everyLine: [String] { labels + [askAction] }

    /// The one action that reads these facts, named where the reading lives so a line can
    /// never state an absence without stating the way out of it.
    public static var askAction: String { RecordingDevicePage.connectAndCheckAction }

    /// The strip, from what the account has kept.
    public static func lines(_ readings: [String: RecordingDeviceReading],
                             now: Date) -> [RecordingDeviceReadingLine] {
        order.map { key in
            guard let reading = readings[key.rawValue] else {
                return RecordingDeviceReadingLine(label: label(for: key), value: nil,
                                                  observedAgo: nil, action: askAction)
            }
            return RecordingDeviceReadingLine(
                label: label(for: key),
                value: reading.value,
                observedAgo: ago(from: reading.observedAt, to: now),
                action: nil)
        }
    }

    // MARK: - THE STRIP, SAID ONCE INSTEAD OF ONCE PER FACT

    // WHAT WAS ON NICK'S SCREEN. A recorder nobody had checked drew three lines, and each one
    // carried its own copy of the same button:
    //
    //     Battery      [ Connect and check now ]
    //     Free space   [ Connect and check now ]
    //     Firmware     [ Connect and check now ]
    //
    // One errand, offered three times, and it is the SAME errand — `askAction` is one constant
    // and every unread line carries it by construction. A recorder that HAD answered drew the
    // mirror image: three numbers each followed by its own "read just now", for three facts one
    // check read at one instant.
    //
    // NOTHING IS DROPPED. Every fact is still named, asked or not, and the way out of an
    // unasked fact is still offered — once, for the strip, instead of once per row of it.

    /// The strip as one thing rather than as N things, so a view renders what was decided here
    /// instead of deciding it in a body no test can compile.
    public struct ReadingStrip: Equatable, Sendable {
        /// The facts that carry a number, in `order`.
        public let read: [RecordingDeviceReadingLine]
        /// The facts nobody has asked for, in `order`. NAMED, never omitted — a strip that
        /// silently drops what it has not got is the `Unavailable` defect with the row deleted
        /// instead of the word.
        public let unread: [RecordingDeviceReadingLine]
        /// The ONE age, when every fact that has one was read at the same moment — which is the
        /// ordinary case, because one check reads all of them. `nil` when they differ, and then
        /// each read line states its own.
        public let sharedAge: String?
        /// The ONE action that would go and ask, when every unasked fact offers the same one.
        /// `nil` when nothing is unasked.
        public let askAction: String?

        public init(read: [RecordingDeviceReadingLine],
                    unread: [RecordingDeviceReadingLine],
                    sharedAge: String?,
                    askAction: String?) {
            self.read = read; self.unread = unread
            self.sharedAge = sharedAge; self.askAction = askAction
        }

        /// The paired-existence half: a compression that compressed a strip with nothing in it
        /// satisfies every rule below and proves nothing.
        public var isEmpty: Bool { read.isEmpty && unread.isEmpty }
    }

    public static func strip(_ lines: [RecordingDeviceReadingLine]) -> ReadingStrip {
        let read = lines.filter(\.wasRead)
        let unread = lines.filter { !$0.wasRead }
        // A read line whose age is missing cannot be covered by a shared one, so the strip
        // falls back to per-line ages rather than stating an age for a fact that has none.
        // EVERY read line must have an age AND they must all be the same one — `Set` alone
        // would collapse three lines to one entry and then call a strip with a missing age
        // "shared".
        let ages = read.map(\.observedAgo)
        let shared: String? = (!read.isEmpty
                               && !ages.contains(where: { $0 == nil })
                               && Set(ages.compactMap { $0 }).count == 1)
            ? ages.first ?? nil
            : nil
        let asks = Set(unread.compactMap(\.action))
        return ReadingStrip(read: read,
                            unread: unread,
                            sharedAge: shared,
                            askAction: asks.count == 1 ? asks.first : nil)
    }

    /// How old a reading is, in words.
    ///
    /// COARSE ON PURPOSE, AND NEVER A CLOCK TIME. "read 20 minutes ago" is a claim this page
    /// can keep true without a per-second tick; "read at 4:02 PM" would need the recorder's
    /// time zone, which this app does not have, and a wall clock the strip does not redraw on.
    /// A reading from the future — a phone whose clock moved backwards — reads as just now
    /// rather than as a negative age.
    public static func ago(from observedAt: Date, to now: Date) -> String {
        "read \(elapsed(from: observedAt, to: now))"
    }

    /// THE AGE WITHOUT THE VERB, so a second surface can put its own verb in front of it
    /// rather than spell the arithmetic again.
    ///
    /// The recorder page's header says when the RECORDER ANSWERED, and a strip line says when
    /// a FACT WAS READ. Those are two sentences about one instant, and computing the instant
    /// twice is how "read 20 minutes ago" and "Answered 19 minutes ago" end up one above the
    /// other on the same screen. Same rounding, same words, one implementation.
    public static func elapsed(from observedAt: Date, to now: Date) -> String {
        let seconds = now.timeIntervalSince(observedAt)
        guard seconds >= 60 else { return "just now" }
        if seconds < 3_600 { return "\(plural(Int(seconds / 60), "minute")) ago" }
        if seconds < 86_400 { return "\(plural(Int(seconds / 3_600), "hour")) ago" }
        return "\(plural(Int(seconds / 86_400), "day")) ago"
    }

    private static func plural(_ count: Int, _ noun: String) -> String {
        "\(count) \(noun)\(count == 1 ? "" : "s")"
    }

    /// HOW FULL THE RECORDER IS — a ratio, because a ratio is the only part of this frame
    /// that survives not knowing the unit.
    ///
    /// WHAT THIS USED TO SAY, ON NICK'S PHONE, ABOUT A 64 GB RECORDER:
    ///
    ///     225 KB free of 57.6 MB
    ///
    /// `MCU&SPA&058767&058992` states used and total in a unit NOBODY HAS RESOLVED. This file
    /// asserted it was kilobytes; the same assumption in the listing parser has since been
    /// measured and disproved (`PocketRecordingExtent` — listing 4 was 19,770 real bytes and
    /// listing 46 was 185,078, off by a varying factor), and nothing distinguishes the storage
    /// frame's unit from the listing's. So the amount is withheld and the RATIO is printed:
    /// `used / total` cancels the unit, is what a person opens this page to find out, and is
    /// exactly as true whether those five digits are kilobytes, seconds or blocks.
    ///
    /// `nil` when the recorder states no capacity at all — a division by zero has no honest
    /// rendering, and "0% full" for a recorder that answered nothing is an absence with a
    /// number painted over it.
    ///
    /// A recorder reporting more used than total reads as full rather than as over 100%.
    /// IT ASKS `PocketMeasuredFigures` FIRST, like every other figure this app prints about a
    /// recorder, so withdrawing the ratio is a one-line change in the register — beside the
    /// frame that entitles it — and never a quiet edit in a view.
    public static func storageFullness(used: Int, total: Int) -> String? {
        switch room(used: used, total: total) {
        case .notAsked:                   return nil
        case .roomRemaining(let percent): return "\(percent)% full"
        case .noRoomLeft:                 return "\(fullPercent)% full"
        }
    }

    /// The percentage a full recorder prints. Named once so the sentence and the decision
    /// cannot disagree about what "full" looks like.
    public static let fullPercent = 100

    /// **WHETHER THE RECORDER CAN TAKE ANOTHER RECORDING**, as a value rather than a rendered
    /// string.
    ///
    /// `storageFullness` renders this and nothing else, so the sentence a person reads and the
    /// decision the app makes come from ONE rule. Without this, a caller asking "is it full"
    /// holds a `String` and has to match `"100% full"` — a check that silently stops working
    /// the day the copy is reworded, which is this codebase's most-repeated defect class.
    ///
    /// FLOOR, NOT ROUNDED, and it matters at exactly one place — the top. Nick's recorder
    /// reports 58,767 of 58,992, which is 99.6% and would ROUND to full. It is not full: it
    /// took another recording that same day. **Only a recorder reporting at least as much used
    /// as it has capacity has no room left.** Telling somebody they cannot record when they can
    /// is the one direction this must not err in.
    public static func room(used: Int, total: Int) -> PocketRecorderRoom {
        guard PocketMeasuredFigures.mayStateHowFullTheRecorderIs,
              total > 0, used >= 0 else { return .notAsked }
        guard used < total else { return .noRoomLeft }
        return .roomRemaining(percentFull: Int(Double(used) / Double(total) * 100))
    }

    // A SENTENCE EXPLAINING WHY THERE IS NO MEGABYTES FIGURE WAS WRITTEN HERE AND DELETED.
    //
    // Nothing rendered it. Copy that exists in the kit, is enumerated by a `everyLine` family
    // and is drawn by no surface is the exact shape the reachability register exists to catch
    // — the gates count it as shipped and a person never reads it. The strip says "99% full",
    // which is the fact somebody opens this page for; the reason the amount is missing is
    // recorded in `PocketMeasuredFigures` under `recorder.storageAmount`, where the person who
    // wants to re-admit it will be standing.
}

// MARK: - Keeping them

extension RecordingDeviceStore {

    /// MERGE, NEVER REPLACE. Facts this session read are updated; facts it did not read keep
    /// the value AND the `observedAt` an earlier session gave them.
    public func recordReadings(_ readings: [String: RecordingDeviceReading],
                               for identity: RecordingDeviceIdentity) throws {
        guard !readings.isEmpty else { return }
        try mutateRecord(identity) { record in
            for (key, reading) in readings { record.readings[key] = reading }
        }
    }

    /// Called after a session that asked a recorder for its facts.
    ///
    /// ASYMMETRIC WITH `recordUserDetach`, FOR THE REASON `recordUserReconnect` IS. A detach
    /// for an unknown device is upserted because the detach is itself the fact worth keeping.
    /// A READING for a device this account does not remember is not: inventing a remembered
    /// device out of a status read would put it in the set `RecordingDeviceActivation` chooses
    /// from. So the no-op is reported as a no-op.
    @discardableResult
    public static func recordObservedFacts(
        identity: RecordingDeviceIdentity,
        readings: [String: RecordingDeviceReading]
    ) -> RecordingDeviceDetachOutcome {
        guard let store = current() else {
            return .unavailable(RecordingDeviceStoreError.noResolvableAccountScope
                .errorDescription ?? "no account scope")
        }
        do {
            guard try store.records().contains(where: { $0.identity == identity }) else {
                return .noMatchingRecord(scope: store.scope)
            }
            try store.recordReadings(readings, for: identity)
            return .recorded(scope: store.scope)
        } catch {
            return .unavailable(error.localizedDescription)
        }
    }
}
