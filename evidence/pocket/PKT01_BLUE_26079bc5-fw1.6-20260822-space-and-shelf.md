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

## Protocol note — **CORRECTED 2026-08-22, and the first version was wrong**

### The correction: a LISTING terminates with `MCU&LIST&<count>`, not `MCU&OFF`

    >> APP&LIST&2026-08-20
    << MCU&F&2026-08-20&20260820160218&2
    << MCU&LIST&001

**`MCU&LIST&<zero-padded count>` is the listing terminator**, and it appears in no source file in
this repository — `PocketBLEProtocolClient` knows `MCU&OFF` as
`transferTerminatorFrame` and nothing else. A client waiting only for `MCU&OFF` after a `LIST&`
waits forever.

### What the first version of this note claimed, and why it was wrong

It said: *"Issuing a second `LIST&<date>` after `MCU&OFF` on the same session returns nothing…
the six dates were therefore enumerated on six separate connections."*

**That inference was false.** The multi-date program was waiting for `MCU&OFF` to advance to the
next date. Listings do not send `MCU&OFF` — they send `MCU&LIST&<count>` — so the program stalled
after the first date and I attributed the stall to a **session constraint that does not exist**.
Six connections worked, but not for the stated reason, and the stated reason would have misled
the next person into an unnecessary reconnect per date.

`MCU&OFF` really is the transfer terminator (`PocketTransferJob.swift:26` records the transfer
loop re-authenticating after it). That part stands. **What does not stand is applying it to
listings.**

### Why this is recorded rather than silently edited

It is the same failure as the truncated `LIST_DIRS` above, one layer up: a mechanism produced
silence, and I supplied a confident explanation for the silence instead of investigating it. Two
instances in one session, in one probe, from the same root — **an absent signal read as a
positive finding.**

## WHAT IS STILL OPEN — Probe P3's second half

**Whether `APP&D` reclaims space or merely unlinks is still unknown**, and
`PocketMeasuredFigures.swift:305` should keep withholding the reclaim figure until it is measured.

The original plan — record a ~2-minute throwaway and delete it — **is not possible: 226 KB of
free space is not enough to record one.** The replacement is closer to production anyway, because
it is what owner-armed auto-clear actually does: delete an EXISTING recording that is provably
stored elsewhere and read `APP&SPACE` either side. Against a 226 KB baseline the delta is
unambiguous at any file size — free space moves, or it does not.

**Authorised by the owner 2026-08-22** for one named recording: `2026-08-20 / 20260820160218`
(2 KB, ~1 s).

### THE FIRST ATTEMPT DELETED NOTHING AND REPORTED A VERDICT ANYWAY

Recorded in full, because it is the most serious instance of this program's defining defect that
this session produced — and it happened **inside the instrument built to measure that defect.**

The run timed out in its FIRST phase (`listBefore`), because of the `MCU&LIST&<count>` terminator
corrected above. **No `APP&D` was composed. No `APP&SPACE` was read** — both `used` values were
still their `-1` sentinel. And it printed:

    VERDICT: APP&D UNLINKS ONLY — gone from the listing, free space did not move

The mechanism: the verdict branch tested `presentBefore && !presentAfter`, and `presentAfter` is
`false` **both when the recording was measured absent and when the re-listing never ran.** One
value, two meanings, and the wrong one was load-bearing.

Had that gone unexamined, this directory would now contain a hardware finding — *"`APP&D` unlinks
without reclaiming"* — supported by **no measurement whatsoever**, in a file whose entire purpose
is that every figure traces to an observation.

**The fix is structural, not a corrected branch.** The verdict now refuses to speak unless
space-before, space-after, a delete acknowledgement **and** a completed re-listing all exist; if
any is missing it prints `NO VERDICT — probe incomplete:` and names them. **A measurement
instrument must not be able to conclude from data it never gathered.**

---

# PROBE P3 — ANSWERED. **`APP&D` UNLINKS. IT DOES NOT RECLAIM.**

Authorised by the owner and run 2026-08-22 against `2026-08-20 / 20260820160218` (2 KB, ~1 s).

## Verbatim

    >> APP&SK&<redacted>
    << MCU&SK&OK
    >> APP&LIST&2026-08-20
    << MCU&F&2026-08-20&20260820160218&2      <- present, 2 KB
    << MCU&LIST&001
    >> APP&SPACE
    << MCU&SPA&058766&058992                  <- 226 KB free
    >> APP&D&2026-08-20&20260820160218
    << MCU&D                                  <- acknowledged

    (fresh session, read-only)
    >> APP&SPACE
    << MCU&SPA&058766&058992                  <- STILL 226 KB free
    >> APP&LIST&2026-08-20
    << MCU&LIST&000                           <- the date is now EMPTY

| | before | after |
|---|---:|---:|
| listed on 2026-08-20 | 1 file | **0 files** |
| used | 58,766 KB | **58,766 KB** |
| free | 226 KB | **226 KB** |

**A 2 KB file was removed from the shelf and free space did not move by one kilobyte.**

## What this changes, and it is not small

`PocketMeasuredFigures.swift:305` describes this figure as *"how much room deleting a recording
gives back"*. **The answer is: none.**

**AUTO-CLEAR CANNOT FREE SPACE ON THIS FIRMWARE.** Clearing recordings removes them from the
listing but does not make room to record. A recorder at 226 KB free stays at 226 KB free however
much is cleared.

**This contradicts an assumption in the out-of-space guidance shipped earlier the same day.**
`PocketRecorderRoomPresentation.makeRoomAction` reads *"Make room now"* and is offered to an owner
whose recorder is full. On this firmware **that offer does not do what it says.** Clearing is
still worth doing — it is how recordings leave the device once they are safe elsewhere — but it is
NOT a remedy for a full recorder, and the copy must stop implying that it is.

Whether a factory reset (`APP&RESET`, untested) reclaims, or whether the space returns after some
delayed compaction, is **unknown and not claimed here.** One observation, one firmware, one file.

## The instrument had to be fixed three times first, and refused to lie each time

Three verbs, three DIFFERENT completion signals — none of which except `MCU&OFF` appears anywhere
in this repository:

| verb | completion signal |
|---|---|
| `LIST&<date>` | `MCU&LIST&<zero-padded count>` |
| `SPACE` | `MCU&SPA&<used>&<total>` — self-terminating |
| `D&<date>&<stamp>` | `MCU&D` — bare, self-terminating |
| a transfer | `MCU&OFF` |

The probe stalled on each in turn. **On every stall the verdict guard refused to conclude** and
named what was missing — *"space-after never read; no delete acknowledgement received; recorder
never re-listed"*. Without that guard, the FIRST run would have printed this same conclusion
having measured nothing at all, and the right answer would have been believed for entirely wrong
reasons.

**A near-miss worth recording even so:** while making a re-run work, `presentBefore = true` was
briefly written into a terminator handler — fabricating a measurement to satisfy the guard. It was
reverted before running. The before-values above are carried as constants explicitly labelled
`[recorded trace]`, taken from the deleting run's own output, and are not re-derived.

`MCU&D` is also a prefix of `MCU&DIRS`; this probe compares whole fields, which is the same
discipline `PocketRecorderClearing.swift:56` uses.
