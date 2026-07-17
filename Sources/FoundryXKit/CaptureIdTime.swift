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
    /// Parse the embedded `yyyyMMdd-HHmmss` (UTC) timestamp out of a capture id and
    /// return it as Unix seconds, or `nil` if the id carries no such stamp.
    ///
    /// Matches any `<8 digits>-<6 digits>` run (e.g. `omi-20260625-202500-ab12cd34`),
    /// so the prefix can be anything. Sanity-bounded: the calendar fields must form a
    /// real date (rejects e.g. `99999999-999999`).
    ///
    /// PURE ARITHMETIC — deliberately NOT DateFormatter (the DATEPARSE hang class,
    /// track 20260717T0759): `DateFormatter.date(from:)` loads ICU DateFormatSymbols
    /// on a cold cache — 626–937 ms main-thread hangs measured on device when the
    /// capture list's first sort/grouping parsed hundreds of ids in one burst. The
    /// stamp is fixed-format ASCII digits in UTC; integer math (days-from-civil) gives
    /// the identical epoch with zero ICU, zero Calendar, zero allocation.
    public static func startedAt(fromCaptureId id: String) -> UInt64? {
        guard let stamp = firstStamp(in: id) else { return nil }
        return epochUTC(fromStamp: stamp)
    }

    /// `yyyyMMdd-HHmmss` (already shape-validated) → Unix seconds, or nil when the
    /// fields don't form a real UTC instant (bad month/day/time, or pre-1970).
    /// Internal (not private) so tests can pin parity against a reference formatter.
    static func epochUTC(fromStamp stamp: String) -> UInt64? {
        let a = Array(stamp.utf8)
        guard a.count == 15 else { return nil }
        func num(_ r: Range<Int>) -> Int {
            var v = 0
            for i in r { v = v * 10 + Int(a[i] - 48) }
            return v
        }
        let y = num(0..<4), mo = num(4..<6), d = num(6..<8)
        let h = num(9..<11), mi = num(11..<13), s = num(13..<15)
        guard (1...12).contains(mo), h < 24, mi < 60, s < 60 else { return nil }
        guard d >= 1, d <= daysIn(month: mo, year: y) else { return nil }
        // days-from-civil (Howard Hinnant's algorithm) — proleptic Gregorian.
        let yy = y - (mo <= 2 ? 1 : 0)
        let era = (yy >= 0 ? yy : yy - 399) / 400
        let yoe = yy - era * 400
        let doy = (153 * (mo + (mo > 2 ? -3 : 9)) + 2) / 5 + (d - 1)
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        let days = era * 146097 + doe - 719468   // days since 1970-01-01
        // Match the old `secs > 0` semantics: pre-1970 and the exact epoch instant → nil.
        guard days > 0 || (days == 0 && h + mi + s > 0) else { return nil }
        return UInt64(days) * 86_400 + UInt64(h * 3_600 + mi * 60 + s)
    }

    private static func daysIn(month: Int, year: Int) -> Int {
        switch month {
        case 1, 3, 5, 7, 8, 10, 12: return 31
        case 4, 6, 9, 11: return 30
        default:
            let leap = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
            return leap ? 29 : 28
        }
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
