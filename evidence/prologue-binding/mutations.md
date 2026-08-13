# `prologue-binding` — the six mutations, each with the scenario it reddened

**Subject.** `features/prologue-binding.feature`, driven by
`swift test --filter PrologueBindingFeatureTests` in this repository. Tips: foundryx
`origin/main` `e3659a6`, foundry `origin/main` `afaba943`.

**Baseline, before any mutation:** rc=**0**, `PROLOGUE-BINDING: scenarios executed = 6,
failed = 0, skipped = 0`.

Every mutation below was applied to the working tree, the suite re-run, the exit code and
the failing scenario names captured from that run, and the mutation reverted with
`git checkout --` (`git status --porcelain -- Sources` = 0 lines after each). **No mutation
survived.** A surviving one would be a finding and there is none to record.

| id | what was changed | rc | scenarios failed | the message the run printed |
|---|---|---|---|---|
| M1 | `NoiseXX.swift:211` — the INITIATOR stops mixing the prologue | 1 | 4 of 6 | *a run with matching bindings did not complete, so nothing below is measurable* (the Background's pinning step) |
| M2 | `NoiseXX.swift:211` **and** `:319` — BOTH peers stop mixing it | 1 | 3 of 6 | *the handshake COMPLETED although the two peers bound it to different things. The prologue is not load-bearing in this build…* |
| M3 | `NoiseXX.swift:319` — the RESPONDER stops mixing it | 1 | 4 of 6 | *a run with matching bindings did not complete, so nothing below is measurable* |
| M4 | this driver's own oracle: the different-addresses step given the SAME address on both sides | 1 | 1 of 6 | *the handshake COMPLETED although the two peers bound it to different things…* |
| M5 | the drive's post-`101` bytes lengthened to 32 | 1 | 1 of 6 | *a correctly speaking peer ACCEPTED 32 bytes of bare tenancy as an opening…* |
| M6 | the opening message shortened to 31 bytes | 1 | 1 of 6 | *an opening value is 32 bytes; this one is 31* |

## M2 is the one the element turns on, and M1/M3 are not substitutes for it

A gpt-5.6-sol review predicted this before it was run, and it was right: **dropping the mix
from ONE peer only does not grade the property.** With one side still mixing a non-empty
prologue the mismatched runs go on failing — for the wrong reason — so M1 and M3 grade the
SYMMETRY that success needs, not whether a host or version disagreement is load-bearing.
Only the coordinated M2, where neither peer mixes anything, asks the real question: it makes
every mismatched run **complete**, and scenarios 2, 3 and 4 catch it. **Scenario 1 stays
green under M2**, which is what makes it the failability control rather than a fourth copy
of the same assertion.

## What these scenarios do NOT establish, named rather than folded in

* **They do not serve `prologue-bytes`.** The peers are this repository's own; the relay
  does not use them; the element's owner is T10. `served` is `false` before and after.
* **They do not pin the serialization of the `||`.** No document does, so no scenario here
  asserts a byte encoding, and T10 A13's golden vector is still owed.
* **They say nothing about the production consumers.** `RelayTransport.swift:100` and
  `DoorConnection.swift:281` both take the default EMPTY prologue, and supplying explicit
  prologues to two test peers cannot catch that. It is recorded in the contract register's
  `_blocked_on` instead.
