# Omi capture — real-BLE smoke (two-device manual test)

Real BLE connect can't be tested on a single machine: **a Mac's Bluetooth radio cannot
discover its own advertisements**, so an in-process or same-Mac peripheral is invisible to
the central. Verifying `DeviceManager` → `OmiBleSource` (scan → connect → subscribe → frames)
needs **two devices** — a peripheral advertising the Omi service and a separate central.

The automated `@ble-hardware` lane (`BLELoopbackTests`) supports this: it scans for a *real
external* Omi peripheral and **skips** if none is in range. Provide one of the two setups
below, then run it; or do the full manual smoke on the phone.

## Option A — OmiSimulator on a second Mac (no hardware Omi)

Omi ships a simulator that advertises the exact GATT contract (service `19B10000`, audio
char `19B10001` notify, `[counter:2][index:1][frame]` packets):

1. On a **second Mac**, open `~/Development/other/omi/omi/firmware/scripts/devkit/OmiSimulator/OmiSimulator.xcodeproj`, run it. On launch it advertises local name **"Friend"** + the audio service and streams audio frames to any subscriber.
2. Grant the simulator Bluetooth permission if prompted.

## Option B — a real Omi device

Wear/power on an Omi; it advertises the same service.

## Verify — automated lane (central = this Mac or a build machine)

With a peripheral from A or B in range:

```
cd ~/Development/foundryx
FOUNDRYX_BLE_HARDWARE=1 swift test --filter BLELoopbackTests
```

Expected: discovers the peripheral → connects → receives ≥5 stripped Opus frames → PASS.
With nothing in range it SKIPS (never a false failure). Without the env flag it SKIPS (kept
out of the default/CI lane).

## Verify — full phone smoke (the real product path)

1. Peripheral from A/B advertising.
2. FoundryX (TestFlight) → **Capture** tab → it scans → tap the discovered **"Friend"** /
   Omi device → connects.
3. Confirm: header shows the device name + **"Capturing ambiently"** (no Record button);
   capture cards advance 💾 Saved on phone → ✅ Saved to computer as segments stream to the
   desktop door (`/foundryx/capture`); **Pause** flips to "Paused" and stops new segments;
   **Resume** continues; disconnect ends the session.

This exercises the whole front half: real BLE connect → ambient capture → durable WAL →
desktop fsync-ACK.
