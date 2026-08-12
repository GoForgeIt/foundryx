# T13's mutation patches — applied in THIS repository, recorded in `foundry`

Each `.patch` here is one mutation of T13's own subject: the per-occurrence retired-form
noun census over this package's sources. They live here because this is what they mutate,
and because `mutation-ledger record` refuses a dirty SUBJECT tree — an untracked patch
would make its own recording impossible.

They are applied by

    mutation-ledger record --subject-repo foundryx --subject-root <a foundryx checkout>

run from a `foundry` checkout, which applies the patch HERE, runs `swift test` HERE with
this repository as its cwd, reverts HERE, and writes the transcript into `foundry` under
`evidence/t13/mutation-ledger/`. The register enumerating them is
`foundry:ci/registers/t13-noun-alignment-mutations.toml`.

| patch | criterion | check it reddens | the step that went red |
|---|---|---|---|
| `T13-A1-M1.patch` | A1 | `swift test --filter NounAlignmentCensusTests` | `testEveryRetiredFormOccurrenceIsLicensed` — `1 retired-form occurrence(s) with no licensing row`, in product source |
| `T13-A1-M2.patch` | A1 | `swift test --filter NounAlignmentCensusTests` | the same assertion, for a SECOND occurrence inside the one file the residue table licenses — the case per-FILE licensing let through |

`T13-A1-M2` is the sharpened re-run of a mutation that **SURVIVED** at `1601b3c`: the
census licensed by PATH, so a second unrelated retired form inside a licensed file
reported `2 occurrences, 2 licensed, 0 unlicensed` and passed. `4a10b8e` made a residue
row name a SITE and asserted the declared count equals the matched count. The mutation
was not weakened to fit the check; the check was fixed to consult its subject.

Both were re-run from this repository's `origin/main` before the patches were written:
the check exited **0** at the baseline and **1** under each patch.
