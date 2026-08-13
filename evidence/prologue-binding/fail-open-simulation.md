# The T25 A6 fail-open — the fix, SIMULATED and measured, and why it was not landed here

## The defect

`HostResolver.swift:94` reads `(obj["machine_id"] as? String) ?? ""`; `hexToData("")` returns
nil on its `!hex.isEmpty` guard; `RelayConfig.expectedDoorStatic` is therefore nil, and BOTH
consumers are conditional — `RelayTransport.swift:109` and `DoorConnection.swift:286` — so no
pin is checked and **the channel completes with any door**. The relay's own security argument
depends on that pin (`crates/foundryx-tunnel/src/lib.rs:204`: open door registration is safe
*because* the phone pins the door's static key), so an absent `machine_id` voids the model.

Reachability is not hypothetical: a 200 from `/host/resolve` always carries `machine_id`
today (`host_api.rs:482`, `host_registry.rs:43`), so an absent one can only come from a broken
or hostile gateway — which is exactly the party the pin exists to defend against.

## The fix, exactly

```diff
--- a/Sources/FoundryXKit/RelayTransport.swift
+++ b/Sources/FoundryXKit/RelayTransport.swift
-        if let expected = config.expectedDoorStatic {
-            guard initiator.remoteStaticPublic == expected else {
-                throw RelayError.doorIdentityMismatch
-            }
-        }
+        guard let expected = config.expectedDoorStatic,
+              initiator.remoteStaticPublic == expected else {
+            throw RelayError.doorIdentityMismatch
+        }
--- a/Sources/FoundryXKit/DoorConnection.swift
+++ b/Sources/FoundryXKit/DoorConnection.swift
-        if let expected = config.expectedDoorStatic, initiator.remoteStaticPublic != expected {
+        guard let expected = config.expectedDoorStatic,
+              initiator.remoteStaticPublic == expected else {
             task.cancel(with: .policyViolation, reason: nil)
             throw RelayError.doorIdentityMismatch
         }
```

**The narrower repair is better still and is named rather than done:** make
`RelayConfig.expectedDoorStatic` NON-OPTIONAL and have `HostResolver.resolveRelayConfig`
throw on an absent or unparseable `machine_id`. Then no consumer can skip the check, present
or future — the guard sits at the property instead of at the two places the need happened to
appear first.

## What landing it does — MEASURED, not predicted

Applied to the working tree, `swift test --filter FoundryXConformanceTests` re-run against a
freshly built relay, then reverted (`git diff --stat -- Sources` = 0 afterwards):

* **The fix works.** `=== PREDICATE P1 [CLOSED] casesExecuted=2 ===`, and
  *"case absent-identity: the client REFUSED on door identity (expectedDoorStatic pinned=false)"*.
* **It moves nothing on D7's five elements.** `contract elements served = 4 of 5` — identical
  to the run without it. So the fail-open is **not** what `prologue-bytes` could not serve.
* **The suite goes rc=1**, on two assertions:
  * `A9BaselineRedTests.testAllThreePredicatesAreRedAtTheBaseline` —
    *"A9 requires all three predicates RED at the pinned baseline. 1 came back GREEN: P1."*
  * `P1ConformanceTests.testP1IsOpenBecauseTheClientProceeded`.

## Why it was NOT landed in this lane

**Not because it reddens A9.** That reason does not survive contact: a gpt-5.6-sol review
called `A9BaselineRedTests` **mis-sited**, and the measurement above proves the point — a
baseline-red record that re-derives its reds from the LIVE TREE (`A9BaselineRedTests.swift:32-48`)
makes a security repair indistinguishable from a regression, and its ordering leg
(`:86-95`) infers *"the reds were taken before any reply"* from the present-day absence of a
file, which cannot establish that the file never existed. A9's own criterion asks for an
artifact **at a pinned SHA** (`spec.md:217,235`). The repair is to capture that artifact —
pinned SHA, captured outputs, ordering evidence — and let the live predicates go closed.

It was not landed **because T25's own criteria disposition already routes this**: A6 (KEEP,
rung D7) asks that P1 *execute behaviourally and both cases run*, which it does; the
REMEDIATION is A10 and A12 (both DEFER, rung D7), and A12 makes *"open / no-response"* an
explicitly recorded outcome. The fail-open is at `open`, with its patch written down and its
consequence measured, which is what A10 asks a status to carry. Landing the fix and the A9
re-siting together is a change to another criterion's just-landed artifact, and it belongs to
a lane that owns both.

## Is it related to what D7 could not serve?

**Separate in cause, same in shape, and on the same rung.**

* **Separate.** Different handshake: `prologue-bytes` is about a step-3 handshake the relay
  does not have (`grep -rni prologue --include='*.rs' crates/` → 0 at foundry `afaba943`),
  while the fail-open is on the blind tunnel's Noise-XX to the door, which exists and
  completes. Measured: fixing it leaves `served` at 4 of 5.
* **Same shape.** Both are *this client binds its channel to nothing*. `RelayTransport` and
  `DoorConnection` construct their initiator with the DEFAULT EMPTY prologue, so the door pin
  is the ONLY binding on that channel — and it is optional. The prologue that `prologue-bytes`
  is about would have been an INDEPENDENT second binding; its absence is why the optional pin
  is a single point of failure rather than defence in depth.
* **Same rung.** `criteria-disposition.md` puts A6 at **D7**, so "it moves none of the five
  elements" does not take it off D7 — an earlier draft of this ruling said it did, and that
  was wrong.
