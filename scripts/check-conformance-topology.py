#!/usr/bin/env python3
"""T25 / A2 — THE CONFORMANCE TARGET IS NOT A MEMBER OF THE HERMETIC SET.

## What was here before, and why it was not a check

The separation is REAL and it is WRITTEN DOWN: `Package.swift` records that
`FoundryXConformanceTests` does not depend on `FoundryXBrineTests` and therefore cannot
see `BrineFeatureRunner`, whose own header declares it hermetic — *"no real network, no
real hardware; every seam is injected"*.  A conformance obligation met inside that runner
would be met against our own responder.

But `grep -rn 'not a member|nonMembership|non-membership' Tests/ Package.swift` returned
NOTHING.  The topology was a fact of the build graph and a paragraph in a manifest; nothing
asserted it, so nothing would say so if it changed.  A2 asks for the assertion, and this is
it.

## THE DISCRIMINATOR THAT MAKES THIS CHECK WORTH HAVING

A2's own mutation — *"add the conformance feature to the hermetic runner and let it
pass"* — is not executable as written, and pretending otherwise proves the wrong thing:
adding the dependency breaks the SwiftPM BUILD GRAPH, so a COMPILE ERROR would stand in
for the non-membership assertion.  Red for the wrong reason is not evidence.

So this reads the manifest through `swift package dump-package`, which PARSES the manifest
without building it, and separates the two outcomes with two different exit codes:

    0  PASS     the manifest parsed and the conformance target does not reach the
                hermetic target through its dependency closure.
    1  FAIL     the manifest parsed and it DOES.  Named, with the closure printed.
    2  REFUSED  the manifest did not parse.  This says NOTHING about topology in either
                direction, and it is not a pass.  `became hermetic` and `no longer
                compiles` are different facts about the world, and a check that reported
                one as the other would let a broken manifest masquerade as a verdict.

## WHY THIS IS A SCRIPT AND NOT AN XCTest — MEASURED, NOT PREFERRED

The first form of this check was an XCTest in `FoundryXBrineTests` that shelled out to
`dump-package`.  It HUNG — not failed, hung — and was killed at ten minutes: SwiftPM
inside SwiftPM contends for the package lock the enclosing `swift test` run already holds,
and `--scratch-path` does not lift it.  A check that deadlocks is worse than a check that
is missing, because a timeout in CI reads as an infrastructure flake.  A2's seam is *a
check*, not a test host, and this needs neither a build nor a relay.

## WHAT THIS COVERS, AND WHAT IT DOES NOT

COVERED: *"a check asserts the conformance target is not a member of the hermetic set"*.
NOT COVERED, named rather than folded in: A2's other conjunct — *"the conformance feature
run THROUGH `BrineFeatureRunner` FAILS its live-relay assertion"*.  That is a RUN, not a
topology, and it has no assertion here.

Usage:  python3 scripts/check-conformance-topology.py
"""
import json
import os
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
HERMETIC = "FoundryXBrineTests"
CONFORMANCE = "FoundryXConformanceTests"
# The hermetic runner itself.  If this file is not a source of the hermetic target, the
# whole topology claim is about the wrong target and the assertion would be true and
# meaningless.
RUNNER = "Tests/FoundryXBrineTests/BrineFeatureRunner.swift"


def refuse(message):
    print(f"REFUSED: {message}", file=sys.stderr)
    print("  This run says NOTHING about target topology in either direction.",
          file=sys.stderr)
    sys.exit(2)


def dump_package():
    proc = subprocess.run(
        ["swift", "package", "dump-package", "--package-path", str(ROOT)],
        capture_output=True, text=True,
    )
    if proc.returncode != 0:
        refuse(
            "THE MANIFEST DOES NOT PARSE — `swift package dump-package` exited "
            f"{proc.returncode}.\n{proc.stderr.rstrip()}"
        )
    try:
        return json.loads(proc.stdout)
    except json.JSONDecodeError as exc:
        refuse(f"dump-package produced output that is not JSON: {exc}")


def main():
    manifest = dump_package()
    raw = manifest.get("targets")
    if not raw:
        refuse("dump-package produced no `targets` array.")

    names = {t["name"] for t in raw if "name" in t}
    deps = {}
    for target in raw:
        name = target.get("name")
        if not name:
            continue
        local = []
        for dependency in target.get("dependencies", []):
            # `byName`/`target` resolve to a LOCAL target when the name is one of ours;
            # a `product` is another package and can never be a member of this set.
            for key in ("byName", "target"):
                value = dependency.get(key)
                if value and isinstance(value, list) and value and value[0] in names:
                    local.append(value[0])
        deps[name] = local

    # NON-VACUITY FIRST.  A membership assertion over a target the manifest does not
    # declare is true for the wrong reason: a typo would pass it forever.
    for required in (CONFORMANCE, HERMETIC):
        if required not in deps:
            print(
                f"FAIL: the manifest declares no target named `{required}`, so "
                "`not a member of the hermetic set` would be satisfied by the set being "
                f"absent.\n  declared targets: {', '.join(sorted(deps))}",
                file=sys.stderr,
            )
            sys.exit(1)
    if not (ROOT / RUNNER).exists():
        print(
            f"FAIL: `{RUNNER}` is not on disk, so `{HERMETIC}` is not demonstrably the "
            "target that carries `BrineFeatureRunner`, and the topology claim would be "
            "about a target chosen by name rather than by content.",
            file=sys.stderr,
        )
        sys.exit(1)

    seen, stack = set(), list(deps[CONFORMANCE])
    while stack:
        nxt = stack.pop()
        if nxt in seen:
            continue
        seen.add(nxt)
        stack.extend(deps.get(nxt, []))

    print(
        f"CONFORMANCE TOPOLOGY: manifest parsed, {len(deps)} target(s) declared "
        f"({', '.join(sorted(deps))}); {CONFORMANCE} closure = "
        f"[{', '.join(sorted(seen)) or 'empty'}]; hermetic target `{HERMETIC}` declared: "
        f"true; in closure: {str(HERMETIC in seen).lower()}."
    )
    if HERMETIC in seen:
        print(
            f"FAIL: NON-MEMBERSHIP VIOLATED — `{CONFORMANCE}` reaches `{HERMETIC}` through "
            f"its dependency closure [{', '.join(sorted(seen))}], so it can see "
            "`BrineFeatureRunner`, a runner whose own header declares `no real network, no "
            "real hardware; every seam is injected`. A conformance obligation met inside it "
            "is met against our own responder.",
            file=sys.stderr,
        )
        sys.exit(1)
    print("PASS: the conformance target is not a member of the hermetic set.")


main()
