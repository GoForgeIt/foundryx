// CaptureIdTimeArithmeticTests — parity proof for the DATEPARSE hang-class fix
// (track 20260717T0759). The arithmetic epoch conversion must agree EXACTLY with
// the DateFormatter it replaced (en_US_POSIX / UTC / yyyyMMdd-HHmmss) — the
// formatter lives on here as the test oracle only, where its ICU cold-load cost
// belongs (a test process), not on the user's main thread.

import XCTest
@testable import FoundryXKit

final class CaptureIdTimeArithmeticTests: XCTestCase {

    /// The exact formatter the app used before the arithmetic replacement.
    private static let oracle: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()

    private func oracleEpoch(_ stamp: String) -> UInt64? {
        guard let d = Self.oracle.date(from: stamp) else { return nil }
        let secs = d.timeIntervalSince1970
        guard secs > 0 else { return nil }
        return UInt64(secs)
    }

    func testParityAcrossRepresentativeCorpus() {
        // Real-shaped stamps: typical, midnight, end-of-day, leap day, year rolls,
        // month lengths, century leap rule, epoch vicinity.
        let stamps = [
            "20260717-135311", "20260625-202500", "20260101-000000",
            "20251231-235959", "20240229-120000",   // leap day (valid)
            "20000229-060000",                       // century leap (÷400 → valid)
            "20260430-115959", "20260531-000001", "20260228-235959",
            "19700101-000001",                       // first representable second
            "19991231-235959", "20301231-235959", "20260301-000000",
        ]
        for s in stamps {
            XCTAssertEqual(CaptureIdTime.epochUTC(fromStamp: s), oracleEpoch(s),
                           "arithmetic ≠ formatter for \(s)")
        }
    }

    func testInvalidCalendarFieldsRejected() {
        // The formatter (non-lenient POSIX) rejects these; arithmetic must too.
        let bad = [
            "20260231-120000",   // Feb 31
            "20230229-120000",   // Feb 29 in a non-leap year
            "21000229-120000",   // century non-leap (÷100, not ÷400)
            "20261301-120000",   // month 13
            "20260017-120000",   // month 0
            "20260700-120000",   // day 0
            "20260732-120000",   // day 32
            "20260717-240000",   // hour 24
            "20260717-126000",   // minute 60
            "20260717-120060",   // second 60
            "99999999-999999",   // nonsense
        ]
        for s in bad {
            XCTAssertNil(CaptureIdTime.epochUTC(fromStamp: s), "must reject \(s)")
        }
    }

    func testPre1970Rejected() {
        // Old code required secs > 0 — the epoch instant itself and anything
        // before it stay nil.
        XCTAssertNil(CaptureIdTime.epochUTC(fromStamp: "19700101-000000"))
        XCTAssertNil(CaptureIdTime.epochUTC(fromStamp: "19691231-235959"))
        XCTAssertNil(CaptureIdTime.epochUTC(fromStamp: "19000615-120000"))
    }

    func testFullIdPathUnchanged() {
        // End-to-end through startedAt(fromCaptureId:) — prefix-agnostic scan intact.
        XCTAssertEqual(CaptureIdTime.startedAt(fromCaptureId: "omi-20260625-202500-ab12cd34"),
                       oracleEpoch("20260625-202500"))
        XCTAssertEqual(CaptureIdTime.startedAt(fromCaptureId: "stress-00001"), nil)
        XCTAssertEqual(CaptureIdTime.startedAt(fromCaptureId: "x-20240229-060000"),
                       oracleEpoch("20240229-060000"))
    }

    /// Exhaustive sweep over a dense stamp grid — thousands of instants across
    /// month/leap/year boundaries. Cheap for arithmetic; the oracle pays ICU once.
    func testParitySweep() {
        var checked = 0
        for (y, mDays) in [(2024, 29), (2025, 28), (2026, 28)] {
            for mo in 1...12 {
                let dmax = [31, mDays, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][mo - 1]
                for d in [1, 15, dmax] {
                    for hms in ["000000", "115959", "235959"] {
                        let s = String(format: "%04d%02d%02d-%@", y, mo, d, hms)
                        XCTAssertEqual(CaptureIdTime.epochUTC(fromStamp: s), oracleEpoch(s),
                                       "arithmetic ≠ formatter for \(s)")
                        checked += 1
                    }
                }
            }
        }
        XCTAssertGreaterThan(checked, 300)
    }
}
