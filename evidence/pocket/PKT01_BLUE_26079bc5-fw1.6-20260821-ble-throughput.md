# BLE throughput, measured — PKT01_BLUE_26079bc5, firmware 1.6

**2026-08-21.** The figure this repository had carried as an open planning guess since the
2026-08-16 bench, closed by measurement.

## Method

Two complete downloads of different lengths over Bluetooth, from a Mac, through the reference
client `pocket-libre` (`uv run pocket-libre download`) — not through this repository's own client,
so the number is a property of the LINK rather than of our implementation. Wall-clock timed around
the whole command, which includes connect, bond, authenticate, select and transfer.

Two points of different sizes were taken deliberately: a single download yields one number
dominated by fixed session setup and cannot be extrapolated. Two allow rate and setup to be
separated and, critically, allow the model to be **checked against a measurement it did not come
from**.

| recording | announced bytes | wall clock |
|---|---|---|
| `2026-08-07 / 20260807142852` | 19,770 | 4.281 s |
| `2026-08-11 / 20260811153632` | 185,078 | 11.308 s |

## Result

    rate  = (185,078 − 19,770) / (11.308 − 4.281)  =  23,524 B/s   (23.0 KB/s)
    setup =  4.281 − 19,770 / 23,524               =   3.44 s

**Check, against the point not used to derive `setup`:**
`3.44 + 185,078 / 23,524 = 11.31 s` versus **11.31 s measured**. The linear model holds.

## What it means

- Pocket audio is 32 kbps CBR = **4,000 bytes per second of wall-clock recording**.
- **23,524 / 4,000 = 5.9× realtime.** A continuous drain keeps up with a recorder still in use,
  with roughly six times the headroom it needs. This was the open question behind
  `20260821T0153_the_drain_survives_termination`, and the answer is yes.
- A 30-minute recording (7.2 MB) transfers in **5.1 minutes**.
- The device held **58,194 s of audio (16.2 hours, 233 MB)** across 20 recordings at the time of
  measurement; the whole backlog would drain in **2.75 hours**, plus ~69 s of total session setup.

## Two prior figures this refutes

1. **"~3–4 KB/s"**, reported from a laptop session on 2026-08-20. Wrong by a factor of six.
2. **"18–36 KB/s"**, carried in the protocol record and flagged there as an unmeasured estimate of
   the *WiFi* leg. It brackets the real *Bluetooth* rate almost exactly — which is a coincidence,
   not a vindication, and the flag on it was correct at the time it was written.

## And one incidental confirmation

The listing number is **seconds, not kilobytes**: `4 → 19,770 bytes` (4.94 s at 4,000 B/s) and
`46 → 185,078` (46.3 s). `pocket-libre` labels that column "Size (KB)" and then derives a
"~Duration" by treating it as kilobytes, which is why its own duration column is wrong by ~4×.

## Why this figure is recorded as measured but NOT printed

One rate, one unit, one session, one distance, one radio environment. It is sound enough to decide
an architecture and not sound enough to put a number or an ETA in front of a person, whose
conditions will differ. `PocketFigureSupport.weMeasured` exists for exactly this distinction:
the figure is known, and it is still withheld.
