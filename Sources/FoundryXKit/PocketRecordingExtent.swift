// PocketRecordingExtent — how big or how long one recording is, and WHERE THAT NUMBER CAME
// FROM, carried in the same value so a surface cannot print one without the other.
//
// THE DEFECT THIS EXISTS FOR, MEASURED ON NICK'S OWN RECORDER ON 2026-08-18.
//
//   Two files came off `PKT01_BLUE_26079bc5` (fw 1.6) — the first ever, in this program's life:
//
//       listing said  4   ->  MCU&U& announced     19,770 bytes
//       listing said 46   ->  MCU&U& announced    185,078 bytes
//
//   `MCU&F&<date>&<stamp>&<n>`'s fifth field is NOT bytes and it is NOT kilobytes. Read as
//   bytes it is out by 4,943x and then by 4,023x; read as kibibytes the real file is 4.83x
//   larger and then 3.93x larger. **A unit that is off by a VARYING factor is not a unit**, and
//   that is what disproves both readings at once.
//
//   The app had shipped both of the wrong ones. First the listing number was stored raw and a
//   6,222-unit file rendered as "1 sec"; the parser was then "fixed" to `n * 1024`, which is
//   why a real Pocket showed **"4 KB" for a 19,770-byte recording** — one unmeasured guess
//   swapped for another, with nothing in the type system able to tell either from a fact.
//
//   So the listing number is carried here WITH NO PAYLOAD AT ALL. `.listedUnitUnresolved` has
//   nothing in it to print. A magnitude that is not carried cannot be rendered, cannot size a
//   buffer, cannot bound a ceiling and cannot be divided into a duration — not because a
//   reviewer noticed, but because there is no number there to reach for.
//
// AND THE OTHER HALF, WHICH IS NOW TRUE. Both files decode as `MPEG ADTS, layer III, v2,
// 32 kbps, 16 kHz, Monaural` — the first audio frame header is `0xFFF348C4`, which reads
// MPEG-2 / Layer III / bitrate index 4 = 32 kbps / sampling index 2 = 16 kHz / mono. 32 kbps
// CBR is exactly 4,000 bytes per second, so
//
//       duration_seconds = announced_bytes / 4000
//
// is measured rather than assumed, and a recording whose REAL byte count is known can state
// how long it is. That byte count arrives one of two ways, and both are equally defensible:
// the recorder announces it in `MCU&U&<n>` at the start of a transfer, or this phone is
// holding the file and can read its length off the disk.
//
// WHAT THIS DELIBERATELY DOES NOT DO. It does not guess forward from the listing. A row for a
// recording nobody has fetched says NOTHING about how big or how long it is, and the page says
// why — see `PocketRecordingExtentPresentation.unknownUntilBroughtOverLine`. Saying nothing is
// better than saying "4 KB" about a 19 KB file, which is the third invented magnitude a Pocket
// surface has printed.

import Foundation

/// HOW BIG ONE RECORDING IS — as a value that knows whether anybody actually measured it.
///
/// Two cases and deliberately no third. There is no `.unknown`-with-a-number and no
/// `.approximately(_:)`: a magnitude carried with a hedge in front of it is a printed
/// magnitude, and the hedge is not evidence.
public enum PocketRecordingExtent: Equatable, Hashable, Sendable {

    /// ALL WE HAVE IS THE LISTING, AND ITS UNIT IS UNRESOLVED.
    ///
    /// NO ASSOCIATED VALUE, ON PURPOSE. `MCU&F&…&<n>` did state a number; this case is the
    /// statement that the number cannot be turned into anything a person reads. Carrying it
    /// would only offer it to the next caller who needed "roughly" something.
    case listedUnitUnresolved

    /// A REAL BYTE COUNT. Either `MCU&U&<n>` — the size a recorder announces when it starts
    /// sending a file — or the length of the file this phone is already holding.
    case bytes(Int)

    /// The byte count, when there is one. `nil` is the whole point of the other case.
    ///
    /// A NON-POSITIVE PAYLOAD IS NOT A MEASUREMENT, AND IT USED TO BECOME ONE. `.bytes(_:)` is
    /// public and takes any `Int`, and this accessor CLAMPED with `max(0, n)` — so
    /// `.bytes(-1)` reported `isMeasured == true` with a byte count of `0`, and the row printed
    /// **"0 sec" as a measured fact**. That is precisely the failure this whole file exists to
    /// remove, re-entering through the one place nobody was reading: a clamp turns malformed
    /// input into a confident answer, which is worse than the absence it replaced.
    ///
    /// So a non-positive count is `nil` — the SAME answer as `.listedUnitUnresolved`, which
    /// makes the surface say nothing rather than say zero. Found by an adversarial cross-vendor
    /// review of this file on 2026-08-20; the assertion that holds it is
    /// `PocketSizesAndDurationsAreTrueFeatureTests.testANonPositiveByteCountIsNotAMeasurement`.
    public var byteCount: Int? {
        if case .bytes(let n) = self, n > 0 { return n }
        return nil
    }

    /// The paired-existence half for every scan over a shelf: a population of rows that are all
    /// `.listedUnitUnresolved` satisfies every prohibition below vacuously.
    public var isMeasured: Bool { byteCount != nil }
}

// MARK: - What a surface may say about it

public enum PocketRecordingExtentPresentation {

    /// BYTES PER SECOND, MEASURED, NOT ASSUMED.
    ///
    /// The two files pulled on 2026-08-18 both carry the frame header `0xFFF348C4`:
    /// MPEG-2, Layer III, bitrate index `0100` = 32 kbps, sampling index `10` = 16 kHz, channel
    /// mode `11` = mono. 32,000 bits/second is 4,000 bytes/second.
    ///
    /// THE SAME DIVISOR WAS ONCE A FABRICATION, and the difference is not the number — it is
    /// what it is applied TO. It used to divide the LISTING number, which is not bytes, and
    /// printed "44 min" on every row of Nick's shelf. It now divides a byte count a recorder
    /// announced or a file this phone is holding.
    public static let bytesPerSecond = 4_000

    /// HOW LONG THIS RECORDING IS, or `nil` when nobody has measured it.
    ///
    /// `nil` IS A REAL ANSWER AND CALLERS MUST RENDER IT AS SILENCE. A row that fell back to
    /// "0 sec", "—" or "unknown size" would be the absence with a magnitude painted over it,
    /// which is the failure this whole file exists to remove.
    public static func line(_ extent: PocketRecordingExtent) -> String? {
        guard PocketMeasuredFigures.mayStateLengthFromAMeasuredByteCount,
              let bytes = extent.byteCount else { return nil }
        return length(ofBytes: bytes)
    }

    /// The duration a real byte count implies, in this app's own vocabulary.
    ///
    /// NOT `public`, and that is the register's wiring: a caller that reached past `line(_:)`
    /// would be a caller that skipped `PocketMeasuredFigures`, which is exactly how an
    /// unmeasured figure got onto a row the first two times.
    static func length(ofBytes bytes: Int) -> String {
        let seconds = Int((Double(max(0, bytes)) / Double(bytesPerSecond)).rounded())
        if seconds < 60 { return "\(seconds) sec" }
        if seconds < 3_600 {
            let minutes = seconds / 60, rest = seconds % 60
            return rest == 0 ? "\(minutes) min" : "\(minutes) min \(rest) sec"
        }
        let hours = seconds / 3_600, minutes = seconds % 3_600 / 60
        return minutes == 0 ? "\(hours) hr" : "\(hours) hr \(minutes) min"
    }

    /// WHAT A PAGE SAYS INSTEAD, once, where there is room for a sentence.
    ///
    /// A stated absence with no way out of it is a shrug — the rule the readings strip already
    /// follows — so the sentence names the one action that WOULD settle it, and that action is
    /// already on the same page.
    public static let unknownUntilBroughtOverLine =
        "How long this is isn't known until it's brought over — the recorder's list doesn't say."

    public static var everyLine: [String] { [unknownUntilBroughtOverLine] }
}

// MARK: - Reading the one byte count this phone can take for itself

public enum PocketRecordingExtentReader {

    /// THE LENGTH OF THE FILE THIS PHONE IS HOLDING, or `.listedUnitUnresolved` when it is
    /// holding nothing.
    ///
    /// `resourceValues(forKeys:)` AND NEVER `attributesOfItem`. The latter stats far more than
    /// a size and has already cost this program a startup hang; the former reads one key.
    public static func extent(ofHeldFile url: URL?) -> PocketRecordingExtent {
        guard let url,
              let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size > 0 else { return .listedUnitUnresolved }
        return .bytes(size)
    }

    /// EVERY ROW'S EXTENT, RESOLVED ONCE, keyed the way the shelf keys its rows.
    ///
    /// It asks CUSTODY, which is the one authority on "is this file here" — the same authority
    /// `PocketShelfReadModel.presences` asks for the same recordings. A second index of held
    /// files would be a second answer to "do we have this", which the delete ruling names as
    /// how a recording gets lost.
    ///
    /// `async` and off the main actor for the reason every other custody read is: it stats the
    /// disk once per recording.
    public static func extents(_ recordings: [PocketRecording],
                               identity: RecordingDeviceIdentity,
                               custody: (any PocketRecorderFileCustody)?)
        async -> [String: PocketRecordingExtent] {
        guard let custody else { return [:] }
        var resolved: [String: PocketRecordingExtent] = [:]
        for recording in recordings {
            let key = PocketRecorderFileKey(identity: identity,
                                            date: recording.date,
                                            timestamp: recording.timestamp)
            let held = await custody.heldFile(key)
            resolved["\(recording.date)/\(recording.timestamp)"] = extent(ofHeldFile: held)
        }
        return resolved
    }
}
