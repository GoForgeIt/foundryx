# The whole inventory, and what the listing number actually is — PKT01_BLUE_26079bc5, firmware 1.6

**Recorder:** `PKT01_BLUE_26079bc5`
**Peripheral:** `08322547-B7D1-0875-DA0C-0CE9BC1AE529`
**Taken:** 2026-08-22, from the Mac beside the recorder, over CoreBluetooth.
**Measured by:** a read-only enumeration script whose verb allowlist refuses anything but the
`read`-class verbs; the only write it can emit is `SK&` **with the key already in
`~/.pocket-libre/config.toml`**, read from disk and never accepted as an argument, so it cannot
mint a new one by typo.

**Authorised by Nick on 2026-08-22 with the risk stated**, because
`foundry-hearth/reference/pocket-ble-protocol.md` says never to send `APP&SK&` to a paired
recorder while `U1` is open. See "What this closes" below — it is now less open.

## The device, as it answered today

```
APP&SK&<stored>   MCU&SK&OK
APP&BAT           MCU&BAT&64
APP&FW            MCU&FW&1.6
APP&SPACE         MCU&SPA&058767&058992
APP&STE           MCU&STE&0
APP&LIST_DIRS     MCU&DIRS&2026-08-07 / -08-11 / -08-12 / -08-13 / -08-14, MCU&DIRS_SUM&005
```

Healthy, idle, 64 % battery. **99.6 % full — 225 of 58,992 units free.**

## The inventory — 19 files across 5 dates

| date | stamp | listed |
|---|---|---:|
| 2026-08-07 | 20260807142852 | **4** |
| 2026-08-07 | 20260807153240 | 2648 |
| 2026-08-07 | 20260807161651 | 1712 |
| 2026-08-07 | 20260807174644 | 1499 |
| 2026-08-07 | 20260807220738 | 1245 |
| 2026-08-07 | 20260807222826 | 1453 |
| 2026-08-11 | 20260811153632 | **46** |
| 2026-08-11 | PH260811175026 | 1813 |
| 2026-08-11 | PH260811215157 | 1377 |
| 2026-08-12 | PH260812145921 | 5421 |
| 2026-08-13 | PH260813121431 | 5178 |
| 2026-08-13 | PH260813134921 | 3580 |
| 2026-08-13 | 20260813203109 | 6212 |
| 2026-08-14 | 20260814001621 | 7192 |
| 2026-08-14 | 20260814175651 | 2330 |
| 2026-08-14 | 20260814184537 | 709 |
| 2026-08-14 | 20260814185753 | 3584 |
| 2026-08-14 | 20260814215622 | 7048 |
| 2026-08-14 | 20260814235352 | 5141 |

**Both timestamp spellings are present on one device** — bare `2026…` and `PH26…` — which the
two-timestamp-spellings work already assumes and which is worth having confirmed on real hardware
rather than inferred.

## What this closes: `O-LISTING-UNIT`

The 2026-08-18 record left this open with **two points**. This reading adds **19 listings and a
storage total**, and two of the listings are byte-anchored by that same 08-18 trace:

| listed | announced by `MCU&U&` | ratio |
|---:|---:|---:|
| 4 | 19,770 bytes | 4942.5 |
| 46 | 185,078 bytes | 4023.4 |

The ratio is not constant, so the unit is not bytes-per-unit. **It is SECONDS, floored, at
32 kbps CBR (4,000 bytes/s):**

```
19,770 / 4000 =  4.94 s -> floor  4   listed  4   MATCH
185,078 / 4000 = 46.27 s -> floor 46   listed 46   MATCH
```

Both anchors land exactly, and the corroboration is independent of them: **the 19 listings sum to
58,192 against `MCU&SPA` used of 58,767 — 99.0 %.** The listing unit and the storage unit are the
same unit, which the 08-18 record suspected and could not check.

**The caveat, stated rather than buried.** This rests on 32 kbps CBR, which the 08-18 record
established from **one frame header of each of two files**. It is consistent with `file` reporting
32 kbps and it is not the same as proving every frame of every recording. If the encoder is ever
VBR the floor arithmetic drifts. So: `O-LISTING-UNIT` is **resolved to seconds** on the evidence
available, and `O-BITRATE-CONSTANT` remains the thing it depends on.

`O-STORAGE-UNIT` resolves with it: seconds. Implied capacity **58,992 s ≈ 16.4 hours ≈ 236 MB of
32 kbps audio** — which does *not* match a 64 GB part, so the device is reporting a partition or a
configured cap, not the raw medium. That is a new open question, not a resolved one.

## What this does NOT establish

**Not P10.** P10 is the *phone's* bring-over failing, and nothing here touches the phone. The
useful negative result: the recorder is healthy, idle, answers every read verb, and served a full
inventory on request — so a P10 explanation that requires the recorder to be unresponsive or
broken is not supported by this reading.

**One candidate cause checked and eliminated.** The listing/announcement mismatch (~4–5×) cannot
trip the download ceiling: `PocketBringOver.maximumBytes` is a flat 32 MB
(`PocketBringOver.swift:428`, `:540`), not derived from the listed size, so a file listed as `4`
passes the pre-flight guard regardless of unit. `PocketBringOver.swift:618-619` already records the
mismatch — *"the listing is a different unit (measured: listing 4 -> 19,770 announced bytes)"* —
and this reading independently confirms that number on today's device.

## `U1` — what happened when the key was re-sent

`U1` asked whether a keyed recorder refuses a second key write. **Re-sending the key it already
holds returned `MCU&SK&OK`, and every read verb answered afterwards.** So a same-key re-send is
accepted and is not refused.

**That is not the whole of U1** and must not be quoted as if it were. What remains untested — and
should stay untested against this recorder — is whether a **different** key would be accepted and
overwrite the pairing. This reading says nothing about that case, which is the dangerous one.
