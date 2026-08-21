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
separated.

**AND NO FURTHER — A CORRECTION, 2026-08-21.** An earlier version of this file claimed the two
points allowed the model to be "checked against a measurement it did not come from". **That claim
was false and it was circular.** A two-parameter line fitted from two observations must reproduce
both observations exactly: the slope was computed from both points and the intercept from one, so
substituting the other is algebraic reconstruction, not validation. It could not have failed.

That is precisely the defect family this repository has a law about — *a decision derived from a
check whose failure is impossible is not a check* — and it was built here, then cited as evidence
of rigour in four separate documents. Found by cross-vendor review.

**A THIRD INDEPENDENTLY TIMED TRANSFER IS OWED** and is the only thing that tests linearity. It was
attempted on 2026-08-21 against `2026-08-14 / 20260814184537` (~2,836,000 bytes; the two-point model
predicts **124.0 s**) and the recorder had gone to sleep. Until that number exists, **the linear
model is an assumption, not a finding.**

| recording | announced bytes | wall clock |
|---|---|---|
| `2026-08-07 / 20260807142852` | 19,770 | 4.281 s |
| `2026-08-11 / 20260811153632` | 185,078 | 11.308 s |

## Result

    rate  = (185,078 − 19,770) / (11.308 − 4.281)  =  23,524 B/s   (23.0 KB/s)
    setup =  4.281 − 19,770 / 23,524               =   3.44 s

## What it means

- Pocket audio is 32 kbps CBR = **4,000 bytes per second of wall-clock recording**.
- **23,524 / 4,000 = 5.9× realtime**, *over the two short transfers observed*.
- **STATED AS EXTRAPOLATION, NOT AS OUTCOME — corrected 2026-08-21.** An earlier version presented
  the figures below as demonstrated: "a continuous drain keeps up", "the answer is yes", "the whole
  backlog would drain in 2.75 hours". **Only 205 KB was actually transferred, in two sessions
  lasting seconds.** Nothing here tests sustained transfer, throughput degradation, throttling,
  disconnect and retry behaviour, per-file variability, battery state, distance or interference.
  A link that starts at 23.5 KB/s and degrades after minutes of sustained work would leave every
  measurement and every calculation above correct and the conclusion wrong.
- So, as arithmetic on the observed rate and nothing more: a 30-minute recording (7.2 MB) would be
  ~5.2 minutes, and the device's 16.2-hour backlog (233 MB) ~2.75 hours.
- **What the drain track may take from this:** the link is not obviously too slow, which is enough
  to justify building. It is not enough to claim the backlog will shrink in practice.

## Two prior figures, and what this can HONESTLY say about them — corrected 2026-08-21

An earlier version said this measurement "refutes" both. It does not, and the word was wrong twice.

1. **"~3–4 KB/s"** from a laptop session on 2026-08-20. This observation **contradicts treating that
   as a general BLE rate**, but it cannot show the earlier session was mistaken: different
   conditions, distance, or measurement boundaries could produce both numbers honestly. If a repeat
   of that setup reproduced 3.5 KB/s, calling it "wrong by six times" would have mislabelled a real
   conditional observation as an error.
2. **"18–36 KB/s"** from the protocol record. **23.5 KB/s lies inside that range**, so it is not
   refuted numerically at all — and the figure was about the *WiFi* leg, which this experiment did
   not measure. The defensible statement is that it is **inapplicable as Bluetooth evidence and
   remains unvalidated**, not that it was refuted.

## And one incidental confirmation

The listing number is **seconds, not kilobytes**: `4 → 19,770 bytes` (4.94 s at 4,000 B/s) and
`46 → 185,078` (46.3 s). `pocket-libre` labels that column "Size (KB)" and then derives a
"~Duration" by treating it as kilobytes, which is why its own duration column is wrong by ~4×.

## Why this figure is recorded as measured but NOT printed

One rate, one unit, one session, one distance, one radio environment. It is sound enough to decide
an architecture and not sound enough to put a number or an ETA in front of a person, whose
conditions will differ. `PocketFigureSupport.weMeasured` exists for exactly this distinction:
the figure is known, and it is still withheld.
