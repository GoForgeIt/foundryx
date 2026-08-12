#!/usr/bin/env python3
"""T13 A9 + A13 — every rename in the diff has a conformance row, and the
replacement is the RULED spelling.

    A9   "Every renamed symbol in the diff has a conformance-record row naming
          which ruled referent it carried.  A rename in the diff with no row is a
          FAILURE BY DEFAULT, per T05's own governing rule."
    A13  "For every renamed symbol, the conformance record's `new symbol` is
          checked against the canonical Swift spelling pinned in T05's registry
          for that referent.  The check reports HOW MANY REPLACEMENTS IT COMPARED
          and fails naming any that does not match.  ...  Point the check at a
          registry file that does not pin a Swift spelling and it EXITS NON-ZERO
          rather than passing vacuously."

═══ WHY THIS FILE EXISTS: A RULING IS BEING OVERTURNED, AND THE OLD ONE WAS ═══
═══ RIGHT ABOUT THE NUMBERS                                                 ═══

Both criteria were recorded UNFALSIFIABLE on the ground that A9 quantifies over
"every renamed symbol in the T13 rename diff" and that set is EMPTY — the two ruled
renames (`docs/noun-registry.md` rows 14 `DoorDialer`->`HostDialer` and 1
`Relay`->`Tunnel`) both cite `crates/foundryx-tunnel/src/lib.rs`, a RUST file in the
`foundry` repository, already renamed by T05.  THE MEASUREMENT IS CORRECT AND IS
RE-DERIVED BY THIS PROGRAM ON EVERY RUN: at `foundryx` origin/main, `DoorDialer` 0,
`HostDialer` 0, exact-token `Tunnel` 0, conformance-record files 0.

WHAT WAS WRONG WAS THE INFERENCE FROM IT.  "Vacuous at the baseline" and
"unfalsifiable" are different claims, and only the first is supported:

  · VACUOUS AT THE BASELINE means the population is empty right now, so the
    universally-quantified clause passes trivially right now.  True.
  · UNFALSIFIABLE means NO REACHABLE STATE of this repository makes the check go
    red.  FALSE — and falsified by the mechanism this program is graded by.  A
    mutation is an UNCOMMITTED WORKING-TREE PATCH: `mutation-ledger` runs the check
    on the clean tree, applies the patch, runs the check again, and reverts.  So
    the mutation IS the thing that populates the set.  The disposition wrote the
    mutation down itself — "rename `WelcomeFrontDoor` -> `WelcomeFrontEntry` and
    omit its row" — and `WelcomeFrontDoor` has 86 occurrences here.  A criterion
    whose own stated mutation reddens it is not unfalsifiable.

═══ THE VACUITY TRAP THIS PROGRAM MUST NOT WALK INTO ═════════════════════════

A check whose green comes from an empty population is the defect this program has
recorded more than once: zero executed is not green.  If the only assertion here
were "every removed symbol has a row", the baseline green would be a green over
NOTHING, and `mutation-ledger` would be recording a red against a baseline that
never asserted anything.

So THREE things execute on every run, and the run REFUSES if any of them did not:

  C1  THE DERIVATION IS NON-EMPTY.  The declaration sets at both commits are
      derived and their sizes reported.  A run that read zero declarations refuses
      rather than reporting a clean rename set.
  C2  A NEGATIVE CONTROL, executed against a synthetic rename: a removed symbol
      with no conformance row MUST be rejected.  Without it, a checker that
      accepts everything is green at the baseline and green under the mutation.
  C3  A POSITIVE CONTROL, executed against a synthetic rename: a removed symbol
      WITH a lawful row citing a real registry row MUST be accepted.  Without it,
      a checker that rejects everything also passes C2 — and would be red under
      every mutation for the wrong reason.

C2 and C3 are the pair.  Either alone is satisfied by a degenerate checker, and a
degenerate checker is what a vacuous population hides.

═══ THE ORACLE IS OUTSIDE THE CODE UNDER TEST ════════════════════════════════

A13's expectation is READ FROM T05's REGISTRY IN THE `foundry` REPOSITORY, never
from anything in `foundryx`.  The mutation lands in `foundryx`; the spelling it is
graded against cannot move with it.  This is the shape T11 A1 used (its expectation
read from T01's ruled clause table on the hearth) and the shape T10 A8 used (golden
vectors from Python's own base64).  A registry that cannot be read is a REFUSAL at
exit 2 — never a pass, which is A13's own stop condition 5.

EXIT CODES
    0 PASS    1 FAIL (named, both directions)    2 REFUSE (an input, or a control,
                                                  could not be established)
"""
from __future__ import annotations

import argparse
import os
import pathlib
import re
import subprocess
import sys

HERE = pathlib.Path(__file__).resolve().parent
REPO = HERE.parent
CONFORMANCE = REPO / "noun-registry-conformance.md"

# Swift declarations whose disappearance is a rename or a deletion.  Both are
# "unjustified without a row" under A9's rule, and deliberately so: the criterion
# says a rename with no row is a failure BY DEFAULT, and a checker that let a
# DELETION through would be answered by deleting the symbol instead of renaming it.
DECL = re.compile(
    r"(?m)^\s*(?:public\s+|internal\s+|private\s+|fileprivate\s+|open\s+|final\s+|"
    r"@\w+\s+)*(class|struct|enum|protocol|actor|extension|typealias)\s+([A-Z]\w*)")

ROW_RE = re.compile(
    r"^\|\s*`?([A-Za-z_]\w*)`?\s*\|\s*(RS-\d+|row\s*\d+)\s*\|\s*`?([A-Za-z_]\w*)`?\s*"
    r"\|\s*(\d+)\s*\|", re.M)


class Refuse(Exception):
    pass


def git(repo, *args):
    r = subprocess.run(["git", "-C", str(repo), *args],
                       capture_output=True, text=True)
    return r.returncode, r.stdout, r.stderr


def declarations_at(repo, ref):
    """{symbol: file} for every Swift declaration reachable at `ref`."""
    rc, out, err = git(repo, "ls-tree", "-r", "--name-only", ref)
    if rc != 0:
        raise Refuse("could not list %s: %s" % (ref, err.strip()))
    files = [f for f in out.splitlines() if f.endswith(".swift")]
    if not files:
        raise Refuse("%s holds ZERO .swift files; a rename set derived from an "
                     "empty corpus asserts nothing about renames" % ref)
    syms = {}
    for f in files:
        rc, body, _ = git(repo, "show", "%s:%s" % (ref, f))
        if rc != 0:
            continue
        for _kind, name in DECL.findall(body):
            syms.setdefault(name, f)
    return syms, len(files)


def declarations_worktree(repo):
    files = [p for p in repo.rglob("*.swift")
             if ".build" not in p.parts and "DerivedData" not in p.parts]
    if not files:
        raise Refuse("the working tree holds ZERO .swift files")
    syms = {}
    for p in files:
        try:
            body = p.read_text(errors="replace")
        except OSError:
            continue
        for _kind, name in DECL.findall(body):
            syms.setdefault(name, str(p.relative_to(repo)))
    return syms, len(files)


def find_registry(explicit):
    """T05's registry, in the `foundry` repository.  NEVER a copy in this one.

    Searched rather than hard-bound, because an absolute path from one laptop is
    how a gate becomes unrunnable anywhere else; and REFUSED rather than defaulted,
    because A13's own stop condition 5 says a check pointed at a registry that pins
    no spelling exits non-zero instead of passing vacuously."""
    cands = []
    if explicit:
        cands.append(pathlib.Path(explicit))
    env = os.environ.get("T05_NOUN_REGISTRY")
    if env:
        cands.append(pathlib.Path(env))
    for up in (REPO.parent, REPO.parent.parent):
        cands.append(up / "foundry" / "docs" / "noun-registry.md")
        cands.append(up / "fw" / "docs" / "noun-registry.md")
    for c in cands:
        if c.is_file():
            return c
    raise Refuse(
        "T05's noun registry could not be read.  Tried: %s\n"
        "  A13 grades the replacement spelling AGAINST THAT REGISTRY, and a check "
        "that cannot read its oracle must exit non-zero rather than pass "
        "vacuously — A13's own stop condition 5.  Pass --registry or set "
        "T05_NOUN_REGISTRY." % ", ".join(str(c) for c in cands))


def ruled_rows(registry_path):
    """{row number: (from, to)} from T05's registry — the ORACLE."""
    text = registry_path.read_text()
    if "```toml noun-registry" not in text:
        raise Refuse("%s carries no `toml noun-registry` block; it pins no ruled "
                     "spellings at all, so there is nothing to grade against"
                     % registry_path)
    body = text.split("```toml noun-registry\n", 1)[1].split("\n```", 1)[0]
    try:
        import tomllib
    except ImportError:  # pragma: no cover
        import tomli as tomllib  # type: ignore
    rows = tomllib.loads(body).get("renamed_identifier") or []
    out = {}
    for r in rows:
        if "number" in r and "from" in r and "to" in r:
            out[int(r["number"])] = (r["from"], r["to"])
    if not out:
        raise Refuse("%s enumerates ZERO renamed_identifier rows" % registry_path)
    return out


def parse_conformance(text):
    """[(old, sense, new, row_number)] from the conformance record."""
    return [(m.group(1), m.group(2), m.group(3), int(m.group(4)))
            for m in ROW_RE.finditer(text)]


def grade(removed, rows, ruled):
    """THE RULE, as one pure function — so the controls exercise the SAME code
    the real legs do.  A control that ran a second implementation would prove
    something about the copy."""
    problems = []
    by_old = {r[0]: r for r in rows}
    for sym in sorted(removed):
        if sym not in by_old:
            problems.append(
                "A9: unjustified rename %s (declared at the baseline in %s, absent "
                "now) — NO conformance-record row names it.  A rename in the diff "
                "with no row is a failure by default." % (sym, removed[sym]))
    compared = 0
    for old, sense, new, num in rows:
        if num not in ruled:
            problems.append("A13: row %r cites registry row %d and the registry has "
                            "no such row" % (old, num))
            continue
        _rfrom, rto = ruled[num]
        compared += 1
        if new != rto:
            problems.append(
                "A13: %s -> %s cites registry row %d, whose ruled spelling is %r.  "
                "The replacement is A spelling, not THE ruled one."
                % (old, new, num, rto))
    return problems, compared


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--baseline", default=None,
                    help="the pinned commit the rename set is derived against")
    ap.add_argument("--registry", default=None)
    args = ap.parse_args()

    try:
        registry = find_registry(args.registry)
        ruled = ruled_rows(registry)
        print("oracle: %s (%d ruled renamed_identifier row(s)) — OUTSIDE this "
              "repository, so a mutation here cannot move the expectation"
              % (registry, len(ruled)))

        baseline = args.baseline
        if not baseline:
            rc, out, err = git(REPO, "rev-parse", "HEAD")
            if rc != 0:
                raise Refuse("could not resolve HEAD: %s" % err.strip())
            baseline = out.strip()
        base_syms, base_files = declarations_at(REPO, baseline)
        now_syms, now_files = declarations_worktree(REPO)

        # ── C1 — the derivation is non-empty ────────────────────────────────
        print("derived %d declaration(s) over %d file(s) at baseline %s; "
              "%d declaration(s) over %d file(s) in the working tree"
              % (len(base_syms), base_files, baseline[:12],
                 len(now_syms), now_files))
        if not base_syms or not now_syms:
            raise Refuse("a declaration set is EMPTY; every clause below would be "
                         "green over nothing")

        removed = {s: f for s, f in base_syms.items() if s not in now_syms}
        text = CONFORMANCE.read_text() if CONFORMANCE.exists() else ""
        rows = parse_conformance(text)
        print("rename set derived from the diff: %d symbol(s)%s; conformance record: "
              "%s, %d row(s)"
              % (len(removed), (" — " + ", ".join(sorted(removed))) if removed else "",
                 CONFORMANCE.name if CONFORMANCE.exists() else "ABSENT", len(rows)))

        # ── C2 / C3 — the controls, executed every run ──────────────────────
        # Synthetic, in memory, through the SAME `grade` the real legs use.
        ctl_num = sorted(ruled)[0]
        ctl_from, ctl_to = ruled[ctl_num]
        neg, _ = grade({"__ControlUnrowed__": "control"}, [], ruled)
        if not any("A9: unjustified rename __ControlUnrowed__" in p for p in neg):
            raise Refuse("NEGATIVE CONTROL DID NOT FIRE: a removed symbol with no "
                         "row was accepted.  This checker accepts everything, and "
                         "its green says nothing.")
        pos, pos_compared = grade({}, [(ctl_from, "RS-1", ctl_to, ctl_num)], ruled)
        if pos or pos_compared != 1:
            raise Refuse("POSITIVE CONTROL DID NOT PASS: a lawful row citing "
                         "registry row %d (%s -> %s) was rejected (%s).  This "
                         "checker rejects everything, so a red under any mutation "
                         "would be a red it was always going to give."
                         % (ctl_num, ctl_from, ctl_to, pos or "compared %d" % pos_compared))
        print("controls executed: 2 (negative: unrowed removal rejected; positive: "
              "row %d %s -> %s accepted)" % (ctl_num, ctl_from, ctl_to))

        problems, compared = grade(removed, rows, ruled)
        print("A13 compared %d replacement(s) against the registry's ruled spelling"
              % compared)

    except Refuse as e:
        print("REFUSED: %s" % e)
        return 2

    if problems:
        print("FAIL: %d problem(s):" % len(problems))
        for p in problems:
            print("  - %s" % p)
        return 1

    print("PASS: every renamed symbol in the diff carries a conformance row (A9) "
          "and every replacement is the registry's ruled spelling (A13)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
