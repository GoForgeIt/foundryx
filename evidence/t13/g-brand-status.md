# T13 / A11 leg (b) — the `T-BRANDGATE` runnability probe, and `G-BRAND`'s status

A11 is a CONJUNCTION and its spec forbids substituting one conjunct for the other in as
many words: *"This spec has no authority to substitute (a) for (b); only Nick can grant
that exception"*, and *"omitting the probe fails A11"*. Leg (a) — the copy/accessibility
byte comparison — is graded by
`Tests/FoundryXBrineTests/CopyAndAccessibilityFrontierTests.swift`. This file is leg (b),
and `testTheGBrandRecordCarriesTheProbeItClaims` reads it: a status recorded here with no
probe beside it is A11's own stated falsifier and goes RED.

G-BRAND: OPEN (GAP-10)

## PROBE RESULT

Executed at track start and re-stated here in the repository the check runs in, so a
fresh clone can read the evidence the check grades without a path off one laptop.

```text
T-BRANDGATE occurrences in foundryx @ 1601b3c : 0
foundry:scripts/ci/brand-gate-step1.sh              : requires `target.html|url`; hardcodes
                                                      `brand-gate-callers/foundry-desktop.json`
foundry:ci/registers/t12a-brand-gate-pins.toml      : its only pin is justified for foundry's
                                                      Tauri desktop window
foundryx:scripts/ci-gates.sh phases                 : swift gates compile leak flake lint
                                                      iosbrine uiproof  — zero brand references
```

BLOCKED BY: the shipped `T-BRANDGATE` wrapper is HTML/URL-shaped and foundry-desktop
specific. FoundryX is a native Swift app, no FoundryX caller config or adapter exists, and
running the gate against this target is therefore not possible with the shipped wrapper.
`T-BRANDGATE` is NOT RUNNABLE against `foundryx` today.

Leg (b) is UNADAPTED, not subjectless: the external predicate package and the resolver
both exist. Recording `G-BRAND: DISCHARGED` here would be false, which is exactly why the
check treats `DISCHARGED` and `OPEN` asymmetrically — `DISCHARGED` may only be written
beside a probe that RAN the gate at both commits with its predicate count reported, and
`OPEN` may only be written beside a named blocker. A status with neither is refused.

Carried into T14's exit pack named, per A11's own destination.
