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
    /// Exactly what will be shown. Formatting happens where the recorder's units are known
    /// (kilobytes, percent), not in a view.
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
    /// FREE SPACE SITS SECOND, not last, because it is the one a person opens this page to
    /// look at. `gapRecovery` is absent: it is a capability, not a reading — nothing is ever
    /// measured for it — and `offlineStorage` is absent because free space is what that row
    /// was standing in for while nobody was asking `APP&SPACE`.
    public static let order: [RecordingDeviceCapabilityKey] = [
        .batteryLevel, .freeSpace, .firmwareVersion,
    ]

    public static func label(for key: RecordingDeviceCapabilityKey) -> String {
        switch key {
        case .batteryLevel:    return "Battery"
        case .freeSpace:       return "Free space"
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

    /// How old a reading is, in words.
    ///
    /// COARSE ON PURPOSE, AND NEVER A CLOCK TIME. "read 20 minutes ago" is a claim this page
    /// can keep true without a per-second tick; "read at 4:02 PM" would need the recorder's
    /// time zone, which this app does not have, and a wall clock the strip does not redraw on.
    /// A reading from the future — a phone whose clock moved backwards — reads as just now
    /// rather than as a negative age.
    public static func ago(from observedAt: Date, to now: Date) -> String {
        let seconds = now.timeIntervalSince(observedAt)
        guard seconds >= 60 else { return "read just now" }
        if seconds < 3_600 { return "read \(plural(Int(seconds / 60), "minute")) ago" }
        if seconds < 86_400 { return "read \(plural(Int(seconds / 3_600), "hour")) ago" }
        return "read \(plural(Int(seconds / 86_400), "day")) ago"
    }

    private static func plural(_ count: Int, _ noun: String) -> String {
        "\(count) \(noun)\(count == 1 ? "" : "s")"
    }

    /// The recorder's own two numbers, as one line.
    ///
    /// BOTH HALVES ARE MEASURED. `MCU&SPA&<used>&<total>` states used and total in kilobytes;
    /// free is their difference and the capacity is the recorder's, never a size this app
    /// decided a Pocket has. A recorder that reports more used than it has capacity for is
    /// clamped at zero free rather than rendered as a negative number.
    public static func freeSpace(usedKilobytes: Int, capacityKilobytes: Int) -> String {
        let free = max(0, capacityKilobytes - usedKilobytes)
        return "\(size(kilobytes: free)) free of \(size(kilobytes: capacityKilobytes))"
    }

    /// Kilobytes as the unit a person reads. `String(format:)` without a locale is POSIX, so
    /// the decimal separator cannot drift with the handset's region.
    public static func size(kilobytes: Int) -> String {
        let kilobytes = max(0, kilobytes)
        if kilobytes >= 1_048_576 {
            return String(format: "%.1f GB", Double(kilobytes) / 1_048_576)
        }
        if kilobytes >= 1_024 {
            return String(format: "%.1f MB", Double(kilobytes) / 1_024)
        }
        return "\(kilobytes) KB"
    }
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
