// CaptureIdTime — recover a conversation's REAL start instant from its capture id
// (track 20260628T1609). A capture id is minted as `omi-yyyyMMdd-HHmmss-<uuid8>`
// with the timestamp stamped in **UTC** (see `CaptureManager.newCaptureId`). That
// stamp is a FIXED point in time the moment the conversation began — it never moves
// on re-ingest, re-sync, or relaunch. So when a capture has no durable `meta.json` /
// `card.json` start (legacy or door-discovered captures), the id itself is a stable,
// processing-time-proof fallback for the conversation date — far better than the
// WAL's launch-time `startedAt`, which is what made old conversations show as "Today".
//
// Pure + unit-tested. The recovered value is an absolute Unix instant; the LIST then
// buckets it into a calendar day with `Calendar.current` (device-local), so an
// evening recording lands on its local day, not the UTC day.

import Foundation

public enum CaptureIdTime {
    /// The shared `yyyyMMdd-HHmmss` (UTC) formatter, matching `newCaptureId`.
    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()

    /// Parse the embedded `yyyyMMdd-HHmmss` (UTC) timestamp out of a capture id and
    /// return it as Unix seconds, or `nil` if the id carries no such stamp.
    ///
    /// Matches any `<8 digits>-<6 digits>` run (e.g. `omi-20260625-202500-ab12cd34`),
    /// so the prefix can be anything. Sanity-bounded: the calendar fields must form a
    /// real date (rejects e.g. `99999999-999999`).
    public static func startedAt(fromCaptureId id: String) -> UInt64? {
        guard let stamp = firstStamp(in: id) else { return nil }
        guard let date = stampFormatter.date(from: stamp) else { return nil }
        let secs = date.timeIntervalSince1970
        guard secs > 0 else { return nil }
        return UInt64(secs)
    }

    /// The first `\d{8}-\d{6}` substring in `id`, or nil. Hand-rolled (no NSRegularExpression
    /// per-call cost) — scan for 8 digits, a dash, then 6 digits.
    private static func firstStamp(in id: String) -> String? {
        let chars = Array(id)
        var i = 0
        while i + 15 <= chars.count {
            if isDigits(chars, i, 8), chars[i + 8] == "-", isDigits(chars, i + 9, 6) {
                return String(chars[i..<(i + 15)])
            }
            i += 1
        }
        return nil
    }

    private static func isDigits(_ chars: [Character], _ start: Int, _ count: Int) -> Bool {
        guard start + count <= chars.count else { return false }
        for j in start..<(start + count) where !chars[j].isNumber { return false }
        return true
    }
}
