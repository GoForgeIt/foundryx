# `noun-registry-conformance.md` — T13

The record behind **A9** and **A13**: every shipped Swift symbol in this repository
that carried a retired sense, which sense it carried, what it became, and the
`renamed_identifier` row of T05's registry that RULES the replacement spelling.

**Graded, not decorative.** `scripts/t13-rename-conformance.py` derives the rename
set from the diff against the pinned baseline and requires a row here for every
symbol in it — *a rename in the diff with no row is a failure by default* — then
checks each row's replacement against the ruled spelling in `foundry`'s
`docs/noun-registry.md`, WHICH IS NOT IN THIS REPOSITORY. The oracle sits outside
the code under test on purpose: a mutation here cannot move the expectation.

## ⚠ THIS TABLE IS EMPTY, AND THAT IS THE MEASUREMENT, NOT AN OMISSION

T13's ruled renames are **not this repository's**. `docs/noun-registry.md` row 14
(`DoorDialer` -> `HostDialer`) and row 1 (`Relay` -> `Tunnel`) both cite
`crates/foundryx-tunnel/src/lib.rs` — a **Rust** crate in `foundry`, renamed by T05.
Re-derived at `foundryx` `fe1560e`: `DoorDialer` 0, `HostDialer` 0, exact-token
`Tunnel` 0, over 479 `.swift` files carrying 1751 declarations.

An empty table is therefore the honest record, and it is **not** the same as an
absent one. What an absent record cannot do is go red: the checker reports the
derived rename-set size beside the row count, runs a NEGATIVE control (an unrowed
removal must be rejected) and a POSITIVE control (a lawful row citing a real
registry row must be accepted) on every run, and refuses if either control fails.
Without that pair a checker that accepts everything and a checker that rejects
everything both look green over an empty population.

| old symbol | retired sense | new symbol | registry row |
| --- | --- | --- | --- |
