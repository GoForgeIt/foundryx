# Bench sitting — PKT01_BLUE_26079bc5, device firmware 1.6, WiFi firmware V8

    device id       PKT01_BLUE_26079bc5
    BLE address     08322547-B7D1-0875-DA0C-0CE9BC1AE529
    firmware        1.6            (device)
    wifi firmware   V8
    sat             2026-08-16, ~16:46 local
    raw capture     PKT01_BLUE_26079bc5-fw1.6-20260816-verb-probe.json (beside this file)
    upstream copy   foundry-hearth/reference/pocket-ble-protocol.md

This is the first time any belief in this program touched real hardware. Everything before it
descended from one third-party decode of firmware **1.3.3**. This file is the record of what the
recorder actually said, and — the half that matters more — of what it was **never asked**.

---

## 1. What the recorder answered, word for word

Every line in this section is a literal frame. Nothing here is paraphrased, rounded, or
reconstructed. The `Sent` column is what went out on the write characteristic
`e49a3002-f69a-11e8-8eb2-f2801f1b9fd1`; the `Answered` column is what came back on notify
`e49a3003-f69a-11e8-8eb2-f2801f1b9fd1`.

| Sent | Answered |
|---|---|
| `APP&BAT` | `MCU&BAT&58` |
| `APP&FW` | `MCU&FW&1.6` |
| `APP&SPACE` | `MCU&SPA&058767&058992` |
| `APP&STE` | `MCU&STE&0` |
| `APP&WF` | `MCU&WF&V8` |
| `APP&WIFI` | `MCU&WIFI&PKT01_BLUE_26079bc5&PD9QQDJ6` |
| `APP&WIFIS` | `MCU&WIFIS&0` |
| `APP&WIFIO` | `MCU&WIFIO` |
| `APP&WIFIC` | `MCU&WIFIC` |
| `APP&LIST_DIRS` | `MCU&DIRS&2026-08-07` `MCU&DIRS&2026-08-11` `MCU&DIRS&2026-08-12` `MCU&DIRS&2026-08-13` `MCU&DIRS&2026-08-14` `MCU&DIRS_SUM&005` |
| `APP&LIST&2026-08-07` | `MCU&F&2026-08-07&20260807142852&4` `MCU&F&2026-08-07&20260807153240&2648` `MCU&F&2026-08-07&20260807161651&1712` `MCU&F&2026-08-07&20260807174644&1499` `MCU&F&2026-08-07&20260807220738&1245` `MCU&F&2026-08-07&20260807222826&1453` `MCU&LIST&006` |
| `APP&D&1970-01-01&19700101000000` | `MCU&D&ERR` |

**P1 (does the WiFi family live on fw 1.6) — ANSWERED.** `APP&WIFI` returned
`MCU&WIFI&PKT01_BLUE_26079bc5&PD9QQDJ6`, not `MCU&UNKNOWN`. The family is live. R6's weakest
joint closes. The SSID **is** the device name.

**P2 (does `APP&D` exist, and does it ack blindly) — ANSWERED, and better than hoped.** A
well-formed frame naming a file that cannot exist returned `MCU&D&ERR`, not a silent ack and not
`MCU&UNKNOWN`. The opcode is established **and** it discriminates: the device tells us when it
did not remove something. Nineteen recordings before, nineteen after. Nothing was destroyed.

That single frame is what makes Nick's delete ruling implementable. "Prove we already hold it"
is worthless if the device lies about what it removed.

---

## 2. The three things this bench changed

**a. `APP&T` exists.** A bare `APP&T` returns `MCU&UNKNOWN`. That was briefly written up as "the
command is absent on this firmware". It is not. It is **write-only and takes a value** —
pocket-libre's `set_time()` sends `T&<YYYYMMDDHHmmss>` and checks for `MCU&T&OK` — and
`MCU&UNKNOWN` means *malformed frame*, not *unknown verb*. Do not conclude a verb is absent from
the reply to a form it does not accept. (The device also already reports `Time: Synced to host`,
so there was nothing to correct and the write was not sent.)

**b. `APP&WF` is the WiFi FIRMWARE VERSION, not credentials.** `MCU&WF&V8` versus
`MCU&WIFI&<ssid>&<password>`. These were conflated.

**c. Two timestamp formats coexist on one device.** The shelf carries bare `20260807142852`
**and** PH-prefixed `PH260811175026`. Nothing in the design accounted for this. `(date,
timestamp)` is a stable identity only if the format is carried **verbatim** — any matcher, key,
or exclusion set that normalises one into the other will address the wrong file, and the file it
addresses on a delete is a recording somebody loses.

---

## 3. A CONTRADICTION IN THIS EVIDENCE — read before touching the fast-sync possession gate

The write-up in `foundry-hearth/reference/pocket-ble-protocol.md` states that `APP&WIFI` returned
password **`PD9QQDJ8`**, that the session key is `PD9QQDJ6KM3PJDFC`, that
`PocketSessionKeyMint.accessPointPassword` derives `sessionKey.prefix(8)` = `PD9QQDJ6`, and that
the two therefore **differ in the eighth character** — making
`PocketAccessPointReadback.provesPossession` return `false` against real hardware.

**The raw capture beside this file says `PD9QQDJ6`** — which is exactly `sessionKey.prefix(8)`,
i.e. the derivation **agrees**.

Both cannot be true. One of the two is a transcription error, and this bench cannot say which,
because it took **one** sample and did not re-read `APP&WIFI` to confirm it.

    STATE:  UNRESOLVED. Not "the derivation is wrong", not "the derivation is right".
    COST:   Step 8's possession gate is either sound or fails closed against every real
            recorder, and we do not currently know which.
    CLOSES: re-read APP&WIFI on PKT01_BLUE_26079bc5 twice, record both replies verbatim
            beside the session key. Sixty seconds. Do not reason about the prefix.

Until that re-read exists, **no fix to the derivation may be merged**, because there is nothing
here to validate a fix against. `APP&SK&` must not be sent to settle it: whether a keyed recorder
refuses a second key write is open unknown **U1**, and getting it wrong breaks the phone's
pairing and changes the recorder's WiFi password.

---

## 4. WHAT WAS NOT MEASURED — and therefore may not be claimed

This is the load-bearing half of this document. Each line below is a number or a claim the
program has been carrying, and the reason it is still not evidence.

| Not measured | Why it is still open | What may NOT be said |
|---|---|---|
| **BLE throughput** | No file was transferred. `APP&U` was deliberately refused: it ties up the radio for minutes to hours on the owner's own device. No MTU, connection interval or PHY was recorded either. | Nothing about how long a Bluetooth pull takes. The "3–4 KB/s ceiling" remains a third-party figure from fw 1.3.3. |
| **The WiFi transfer rate** | The transfer was never performed. | Nothing about WiFi speed. `E-WIFI-RATE` is open. |
| **The WiFi serving endpoint** | Never confirmed. pocket-libre itself records the HTTP endpoint the device serves files from as **unconfirmed upstream**. The AP was opened and closed; nothing was fetched through it. | No URL, and no claim that fast sync has a working file path. `E-WIFI-ENDPOINT` is open. |
| **"~150× faster"** | Never timed, on either leg. It is a **flagged planning guess** and always was. | It must never be rendered to a user, in figures or in words. A superlative is the prose form of the same guess. |
| **The audio bitrate that turns a size into a duration** | The 4,000 bytes/second divisor descends from the third-party fw-1.3.3 decode and from a fixture *we* encoded to match that belief (`Tests/FoundryXBrineTests/fixtures/pocket/pocket-fw16-3s.mp3`, generated by ffmpeg + lame, not pulled off a recorder). No audio has ever come off a Pocket. | How long any recording lasts. The recorder states **kilobytes**; kilobytes are what may be printed. |
| **Whether delete reclaims space or only unlinks** | Probe P3 was not run — it needs a throwaway recording, and the recorder is 99% full. Only a sentinel delete that could not succeed was issued. | "Free up space on your recorder." Delete may be offered as *removing a recording*, never as *reclaiming N megabytes*. |
| **Whether a keyed recorder refuses a second `APP&SK&`** | U1. Never probed, on purpose. | Anything about re-keying. |
| **Whether the 8-second silence bound holds over hours** | Never exercised. | Nothing about unattended long pulls. |

---

## 5. The state this recorder is in

    APP&SPACE  ->  MCU&SPA&058767&058992      used 58,767 KB of 58,992 KB
    APP&LIST_DIRS -> five dates, MCU&DIRS_SUM&005
    recordings on the shelf: 19
    newest date seen: 2026-08-14

**99.6% full.** 225 KB free. It has almost certainly stopped being able to record. This is the
condition the delete work exists for, and it is not hypothetical.

---

## 6. What IS validated as working

The `prepare()` choreography is sound on real hardware: `WIFIO → WIFIS(3) → WIFIC → WIFIS(0)`
opens the access point and tears it down cleanly, and the status codes move as expected. Status
`0` is closed; `3` is open-with-no-client. The control path is not the problem — the two gates in
front of it are (the no-delay readiness poll at `PocketBLEProtocolClient.swift:516-518` where
pocket-libre waits 90 s, and the status-`1` check ordered before any client has joined at
`PocketFastSync.swift:93-96`).

## 7. Hazard for implementers

`MCU&D&ERR` shares a prefix with `MCU&DIRS`, `MCU&DIRS_SUM` and a delete success ack. A matcher
on `"MCU&D"` matches all four, and one of those four means *your recording is gone*. **Match the
full frame.** Treat `MCU&D&ERR` as an explicit refusal, never as a delete that happened.

## 8. Reproducing this

```
python3 -m venv <venv> && <venv>/bin/pip install -e ~/Development/pocket-libre
<venv>/bin/pocket-libre scan
<venv>/bin/pocket-libre status --address 08322547-B7D1-0875-DA0C-0CE9BC1AE529 --key <key>
```

The session key lives in the **iPhone's** Keychain — device screen → key custody → Reveal → Copy.
The pocket-libre clone is at `3111d14` and does **not** carry the `delete` command (unmerged
PR #2), so a delete must be issued as a raw frame.

**Never send `APP&SK&` against a paired recorder.**
