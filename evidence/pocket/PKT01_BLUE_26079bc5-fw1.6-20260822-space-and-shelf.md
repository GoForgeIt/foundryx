# PKT01_BLUE_26079bc5 (fw 1.6) — 2026-08-22 — free space and the whole shelf

**Device:** `PKT01_BLUE_26079bc5`, firmware 1.6. **RSSI** −65 to −66 dBm.
**Driven from:** macOS, CoreBluetooth, directly from the desktop — **not the phone**. The Swift
package targets macOS 13 and `BluetoothSeam` is gated on `canImport(CoreBluetooth)`, so the
protocol is reachable from a Mac. Phone Bluetooth was off, satisfying the one-authenticated-
session-at-a-time constraint.

**Control characteristic:** `001120A3-2233-4455-6677-889912345678` (write + notify), matching
`PocketCharacteristicMap.primary`'s `command`/`control`. Audio is `001120A1`.

**READ-ONLY.** Three verbs were composed: `APP&SK&`, `APP&SPACE`, `APP&LIST_DIRS`/`APP&LIST&`.
**No `APP&D` was composed by any program in this session.**

---

## Verbatim replies

    >> APP&SK&<redacted>
    << MCU&SK&OK

    >> APP&SPACE
    << MCU&SPA&058766&058992

    >> APP&LIST_DIRS
    << MCU&DIRS&2026-08-07
       MCU&DIRS&2026-08-11
       MCU&DIRS&2026-08-12
       MCU&DIRS&2026-08-13
       MCU&DIRS&2026-08-14
       MCU&DIRS&2026-08-20

---

## FINDING 1 — the `MCU&SPA&<a>&<b>` FIELD ORDER IS `<used>&<total>`, AND IT IS NOT INVERTED

`PocketBLEProtocolClient.swift:259-266` carried this as an **unverified third-party decode**, and
warned in-source that if the firmware answered `<total>&<used>` then *"every reading arrives
inverted; the presentation layer clamps with `max(0, capacity - used)` and the owner is shown
'0 KB free of n' stamped 'read just now' — a confident wrong number, and the exact pressure that
makes somebody delete something."*

**Measured: `a = 58766`, `b = 58992`, so `a ≤ b`.** The decode is correct. That warning is now
**answered**, not carried.

## FINDING 2 — the recorder is at 58,766 / 58,992 KB: 226 KB free, 99% full

This lands exactly on the boundary `RecordingDeviceReadingPresentation.storageFullness`'s
floor-not-round rule was written for: **58,766/58,992 = 99.617%**, which ROUNDS to 100 and FLOORS
to 99. The shipped code floors, prints "99% full", and reports not-full — **correct**, because
`used < total`. Had it rounded, it would have told the owner he could not record when he could.

**226 KB ≈ 56 seconds** of audio at the measured 4,000 B/s CBR.

## The shelf, in full — 20 recordings across 6 dates

| date | recordings | KB |
|---|---:|---:|
| 2026-08-07 | 6 | 8,561 |
| 2026-08-11 | 3 | 3,236 |
| 2026-08-12 | 1 | 5,421 |
| 2026-08-13 | 3 | 14,970 |
| 2026-08-14 | 6 | 26,004 |
| 2026-08-20 | 1 | 2 |
| **total** | **20** | **58,194** |

**58,766 KB used − 58,194 KB of files = 572 KB**, about 1%, consistent with directory entries and
filesystem overhead. **The files account for the used space; there is no unexplained consumption.**

### A false finding I nearly reported, recorded because the mechanism matters

The first `LIST_DIRS` probe exited on the FIRST reply line and reported *"the device holds one
date, 2026-08-07"*. On that basis the shelf appeared to hold 8,561 KB against 58,766 KB used — a
50,205 KB gap — and the obvious reading was **"`APP&D` unlinks without reclaiming"**, i.e. Probe
P3's answer arriving early.

**It was wrong.** `LIST_DIRS` returns one line per date and there are six. The gap was entirely
an artefact of reading the first line of a multi-line response as the whole answer.

This is the same defect class this program keeps finding in its own code: a mechanism whose
truncation is indistinguishable from a complete result. It is recorded here rather than quietly
corrected because a reader of the totals above should know how close they came to being wrong.

## Protocol note — `MCU&OFF` ends the ERRAND, not the listing

Issuing a second `LIST&<date>` after `MCU&OFF` on the same session returns nothing. `MCU&OFF` is
`PocketBLEProtocolClient.transferTerminatorFrame`, and `PocketTransferJob.swift:26` records that
the transfer loop re-authenticates after it. The six dates above were therefore enumerated on
**six separate connections**, one per date, which is slower and unambiguous.

## WHAT IS STILL OPEN — Probe P3's second half

**Whether `APP&D` reclaims space or merely unlinks is still unknown**, and
`PocketMeasuredFigures.swift:305` should keep withholding the reclaim figure until it is measured.

The original plan — record a ~2-minute throwaway and delete it — **is not possible: 226 KB of
free space is not enough to record one.** The replacement is closer to production anyway, because
it is what owner-armed auto-clear actually does: delete an EXISTING recording that is provably
stored elsewhere and read `APP&SPACE` either side. Against a 226 KB baseline the delta is
unambiguous at any file size — free space moves, or it does not.

**Blocked on the owner's explicit authorisation for one named recording.** Nothing here composes
a delete.
