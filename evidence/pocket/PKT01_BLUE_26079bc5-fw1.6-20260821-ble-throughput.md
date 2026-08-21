# BLE throughput, measured properly — PKT01_BLUE_26079bc5, firmware 1.6

**2026-08-21, superseding an earlier version of this file whose figure was WRONG BY 2.6×.**

## Method

Wall-clock timed downloads over Bluetooth through the reference client `pocket-libre`
(`uv run pocket-libre download`), from a laptop beside the device. The clock covers the WHOLE
command — connect, bond, authenticate, select, transfer, write to disk — so the fixed term below
is real session setup, not an artifact of where the timer started.

Four distinct file sizes, with the 2.84 MB point repeated three times to establish repeatability
(55.863 / 54.395 / 50.414 s) and two larger files taken **after** the model was published, as
out-of-sample tests rather than fitting material.

## The result

Seven timed downloads across four file sizes, least squares over six of them:

    t = 5.34 s + bytes / 60,447 B/s          R² = 0.99661, max residual 4.7 s

| bytes | elapsed | implied B/s |
|---|---|---|
| 19,770 | 30.164 | 655 ← **artifact, excluded, see below** |
| 185,078 | 7.987 | 23,172 |
| 2,839,868 | 55.863 | 50,836 |
| 2,839,868 | 54.395 | 52,208 |
| 2,839,868 | 50.414 | 56,331 |
| 4,981,430 | 83.077 | 59,962 |
| 9,323,322 | 160.952 | 57,926 |

All seven files verified `MPEG ADTS, layer III, v2, 32 kbps, 16 kHz, Monaural`.

**≈60 KB/s steady, ≈5.3 s fixed overhead. Against the 4,000 B/s audio-generation rate that is
≈15× real time**, and continuous background drain is comfortably viable.

## WHY THE PREVIOUS FIGURE WAS WRONG, AND WHY IT SURVIVED

The earlier version fitted **two** points — 19,770 B in 4.281 s and 185,078 B in 11.308 s — and
reported `23,524 B/s, 3.44 s setup`. It also claimed to have "checked the model against a point it
did not come from". **That check was circular**: a two-parameter line fitted to two observations
reproduces both exactly and cannot fail. That was retracted before this measurement was taken.

**What the two points actually were:** one fast relative to the true line and one slow. `19,770`
predicted 5.67 s against the real curve and measured 4.281 s; `185,078` predicted 8.40 s and
measured 11.308 s. **The two errors pulled the slope in opposite directions and flattened it**,
producing a rate 2.6× too low from two individually unremarkable timings. Two points cannot show
you this; that is the whole reason a third was owed.

## THE PRE-REGISTERED PREDICTION IS WHAT CAUGHT IT

Before measuring, the old model's prediction for the 2,836,000-byte file was written down —
**124.0 s**, with the falsifying band stated in advance as "under 90 s or over 170 s means the
relationship is not linear". **Measured 55.863 s.** Outside the band, by the criterion set before
the number existed.

The prediction could not be adjusted afterwards because it was already published. That is the
difference between a measurement and a fitting exercise, and it is the only reason the wrong rate
was found rather than inherited.

## THE 19,770-BYTE POINT IS AN ARTIFACT OF THE REFERENCE CLIENT, NOT OF THE LINK

It sits +24.5 s off the line and reproduces (26.379 s, then 30.164 s). Cause: `pocket-libre`'s
`download_ble` wait-loop — when a file lands **before the loop starts**, it burns its 5 × 5 s stall
detector and exits. That ~25 s is pure timeout.

**IT DOES NOT APPLY TO THIS APP.** `PocketBLEClient` ends a transfer on the `MCU&OFF` terminator
frame, which the protocol record measures arriving **0.086–11.078 ms after the last chunk**
(`PocketBLEProtocolClient.swift:576,587`) — there is no stall detector to burn. The penalty is the
reference client's and is recorded here so nobody imports it as a property of the hardware.

*It does mean earlier small-file timings taken through `pocket-libre` are unreliable in both
directions: this session's own 4.281 s for the same file did NOT hit the artifact, and the laptop's
two runs did.*

## USB mass storage: a clean negative

With a Thunderbolt 4 cable attached, `APP&USB&ON` → `MCU&USB&0`, then 40 s of polling with **no
enumeration** — no USB device, no volume, no external disk, status stuck at `0`. `USB&S` and
`USB&STAT` also return `MCU&USB&0` and never advance; bare `USB`, `USBS`, `USBSTAT` are
`MCU&UNKNOWN`.

An authenticated BLE session of ours **does not satisfy the USB-Mode gate** — the mass-storage
mount is bound to the vendor app. `MCU&USB&0` reads as "acknowledged, not unlocked". This closes
the USB-importer path without accepting the vendor ToS, and at 15× real time BLE does not need it.

## What this does and does not license

It is a rate for THIS unit, on THIS firmware, at desk distance, over seven transfers totalling
20.3 MB — enough to decide an architecture. It still says nothing about sustained multi-hour
drains, thermal or battery degradation, distance, or interference. The figure remains
`locallyMeasuredButWithheld`: known, and still not printed to a person.
