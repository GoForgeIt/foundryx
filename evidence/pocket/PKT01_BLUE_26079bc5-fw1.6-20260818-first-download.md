# The first two files that ever came off a Pocket — PKT01_BLUE_26079bc5, firmware 1.6

**Recorder:** `PKT01_BLUE_26079bc5`
**Device firmware:** `1.6`  (WiFi firmware `V8`)
**Peripheral:** `08322547-B7D1-0875-DA0C-0CE9BC1AE529`
**Taken:** 2026-08-18, from the Mac beside the recorder, over CoreBluetooth.

## Provenance — read this before quoting anything below

These frames were **not captured by this repository**. They were captured on 2026-08-18 by an
instrumented copy of `pocket-libre` (MIT, `~/Development/pocket-libre`, unmodified) and are
recorded in two places outside this file:

* `foundryx-hearth/reference/pocket-ble-protocol.md` — the written record, commit `4a3dcff`
  plus the corrections appended the same day.
* `Tests/FoundryXBrineTests/fixtures/pocket/pocket-fw16-ble-download-trace.json` — the machine
  record: every event with its arrival time and byte length, audio bodies elided.

This file is a **transcription for the figure register**, so that a figure this app prints names
an artifact in `evidence/pocket` like every other one. Nothing here was measured by writing this
file. Where the two upstream records disagree — they do, about throughput — the disagreement is
stated rather than resolved.

## The frames

```
APP&U&2026-08-07&20260807142852
MCU&U&19770
```

19,770 bytes then arrived on the audio characteristic `001120a1`, in 82 notifications, and the
transfer was terminated by an unsolicited `MCU&OFF` on the control characteristic `001120a3`.

The second file, from a different date:

```
APP&U&2026-08-11&20260811153632
MCU&U&185078
```

## THE LISTING NUMBER IS NOT THE SIZE — this is what these two files settle

| `MCU&F&…&<n>` said | `MCU&U&` announced | read as bytes | read as kibibytes (`× 1024`) |
|---|---|---|---|
| 4  | 19,770  | × 4,943 | 4,096 → real file **4.83×** larger |
| 46 | 185,078 | × 4,023 | 47,104 → real file **3.93×** larger |

**Neither reading holds, and that is what disproves both**: a unit that is wrong by a *varying*
factor is not a unit. Both readings have shipped in this app — the raw number first, then
`n * 1024` as its "fix" — and the second is why a real recorder's page showed **`4 KB` for a
19,770-byte recording**.

Nothing may be sized, bounded, timed or drawn from the listing number. It is registered as
`recorder.recordingSize`, withheld, with `O-LISTING-UNIT` naming what would close it: a **third**
file from a different size band. The leading hypothesis is that the number is the **duration in
seconds** — `floor(19770/4000) = 4` and `floor(185078/4000) = 46`, both exact — but two points
fit many rules and it is **not established**.

## THE BITRATE IS 32 kbps CBR = 4,000 BYTES PER SECOND

The first byte of the first audio notification is the MP3 frame header `0xFFF348C4`, and there
is no preamble in front of it (`mp3_sync_offset = 0`). That header decodes as:

```
0xFFF348C4 = 1111 1111 1111 0011  0100 1000  1100 0100
             ^^^^^^^^^^^ sync
                         ^^ 10   = MPEG-2
                            ^^ 01 = Layer III
                                   ^^^^ 0100 = bitrate index 4 = 32 kbps
                                        ^^ 10 = sampling index 2 = 16 kHz
                                                  ^^ 11 = mono
```

32,000 bits/second is exactly **4,000 bytes/second**, so

```
duration_seconds = announced_bytes / 4000
```

19,770 bytes → 4.94 s. 185,078 bytes → 46.27 s. This is what entitles
`recorder.recordingDuration` to be printed, and it is entitled **only over a real byte count** —
`MCU&U&<n>`, or the length of a file this phone is holding. The same divisor applied to the
listing number is the fabrication that put "44 min" on nineteen rows.

## Throughput — the two records disagree, and the slower one governs

| source | figure |
|---|---|
| `foundryx-hearth/reference/pocket-ble-protocol.md` | ~18 KB/s (185,078 bytes in 9.9 s, wall clock over a whole `pocket-libre` invocation) |
| `pocket-fw16-ble-download-trace.json` | 36.3 / 32.8 / 21.2 KB/s (audio burst only, three transfers) |

The wall-clock figure includes the reference implementation's own dead time. **Design to 18 KB/s.**
Nick's largest recording is 15–27 minutes on the wire either way.

## NOT MEASURED, and therefore not quotable

* **The listing number's unit.** Two points. `O-LISTING-UNIT` is open.
* **The storage unit.** `MCU&SPA&058767&058992` is internally consistent with the sum of the 19
  listings, and both are in the same unresolved unit. The hardware is a 64 GB recorder and these
  are five-digit figures. `O-STORAGE-UNIT` is open; the app prints the **ratio** only.
* **Whether the bitrate is constant across a whole file.** One frame header was read. `file`
  reporting `32 kbps` for both files is consistent with CBR and does not prove it for every
  frame of every recording.
* **Whether `MCU&OFF` means "transfer complete" or "transfer engine off".** Three observations
  out of three say it exists and lands on the control characteristic. Nothing says what it means.
