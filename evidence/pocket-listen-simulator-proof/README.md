# Simulator proof — a recording that came off a recorder plays here (Step 9)

`UITests/PocketListenProofUITests.swift`, run on iPhone 17 Pro
(`B3D9FB15-5FAA-4A4E-9DBA-562B94F89668`), 2026-08-16. **2 tests, 0 failures**, standalone AND in
lane position — `bash scripts/ci-gates.sh uiproof` is green with this suite added to it
(16 proofs, 0 failures).

    xcodebuild test -project FoundryX.xcodeproj -scheme FoundryXUIProof \
      -configuration Debug -destination "platform=iOS Simulator,id=<udid>" \
      -only-testing:FoundryXUITests/PocketListenProofUITests

## A DEFECT IN THE PROOF ITSELF, FOUND BY RUNNING IT IN THE LANE

The first version of this suite used the `-Screen detail -Capture <id>` deep link, the way
`AudioPlaybackProofUITests` does. It passed twice standalone and **failed both cases inside the
lane**: the app was up and idle, on the conversation list, and the `fullScreenCover` that link
raises from `CaptureScreen.onAppear` never appeared — "the detail opened", 15 s, twice.

Rewritten to open the conversation the way a person does (find the card, tap it), it then failed
AGAIN in the lane for a second, different reason: `PlaceRestoreProofUITests` runs immediately
before it and its whole subject is that the app comes back to the tab you left, via a durable
`AppPlacementStore` record in a container that survives between runs. The list was not on screen
at all — the card was missing for the full 45 s while the very next suite found the same card in
4.7 s. `-FreshActionState` (which clears `AppPlacementStore`, and which
`RecordingDeviceProofUITests` already carries for exactly this reason) is what makes it
order-independent.

Both are worth writing down: a UI proof that only runs standalone is a proof whose ability to
fail is a property of what ran before it.

The screenshots the run attaches are NOT committed — this repository keeps text evidence, and
three retina PNGs is 5.5 MB. They are written by the run itself; the last run left them at
`build/pocket-listen-proof-screens/` and the result bundle at `build/pocket-listen-proof.xcresult`.

## What each shot shows

**01 — three places on a brought-over recording.** The detail for `pkt-20260814-090000-proof001`
("Walk to the trailhead"), whose original MP3 `DemoSeed` put in this account's `pocket-recordings`
custody this launch. Under Listen:

    This plays from this iPhone — no computer needed.
    On the recorder:  Unknown - never checked
    On this iPhone:   Yes - just now
    Safe elsewhere:   Yes - just now
    Solleva keeps the recorder's original file on this iPhone. Freeing that space isn't
    something Solleva can do yet.

Three places, three ages, `unknown` shown as unknown — and the standing trade (Listen ships,
reclaiming the local copy does not) said out loud on the surface rather than left as an absence.

**02 — playing from this phone with no computer.** After one tap on Listen: `Stop`, a scrubber,
`0:01 / 0:07`. There is no door in this environment. The bytes came off the phone.

**03 — the paired case.** `omi-demo-1`, a conversation this phone recorded, in the SAME launch
environment: no three-place row, nothing plays, and the honest line is "Can't reach your
computer". This is what stops shot 02 passing for the wrong reason — if Listen had simply
stopped calling the door for everything, or if the demo target were quietly reachable, this
test goes red.

## The mutation that proves the wiring, not just the logic

`evidence/pocket-listen-mutation-patches/M5-the-wiring-itself.patch` deletes the one line in
`initialLoad()` that resolves the held file. The kit suite stays **4 tests / 0 failures** and
this proof goes red — `("0") is not equal to ("5")`.
