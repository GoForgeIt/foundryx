#!/bin/bash
# Pre-push gate: run LOCALLY, before the push, exactly the phases CI will run.
#
# WHY THIS EXISTS.
# ---------------
# On 2026-08-12/13 seven ship attempts burned ~6 hours of wall clock discovering
# defects a local run would have named in minutes. The tooling was already here:
# `ci-gates.sh` has had an `iosbrine` phase since 2026-07-25, carrying a comment
# that says in as many words that it exists so "a green ci-gates cannot mean a red
# iOS runtime" — and naming the exact divergence class (Keychain answers
# errSecMissingEntitlement on the hostless iOS host, succeeds on macOS) that later
# shipped VaultDoorCredentialFeatureTests born-red. Every local validation that
# week ran `ci-gates.sh swift gates` and stopped. The phase list was the gap, not
# the phase.
#
# So this hook does not ask the pusher to remember a phase list. It derives the
# phases from what CI runs and refuses to be the shorter list.
#
# SCOPE. Only branches that actually TRIGGER a workflow are gated (main, ship/*):
# gating every scratch push would make the hook something people disable, and a
# disabled gate is worse than none. Bypass is `git push --no-verify`, which prints
# a loud line naming what was skipped — bypassing should feel like a decision.
set -uo pipefail

cd "$(git rev-parse --show-toplevel)" || exit 1

# Which local refs are being pushed? Read stdin the way git delivers it
# (<local ref> <local sha> <remote ref> <remote sha>), falling back to HEAD's
# branch only when git gave us nothing (hand invocation).
#
# SAW_INPUT is a separate flag on purpose. Testing the loop variable instead
# (`[ -z "$remote_ref" ]`) reads as equivalent and is not: the final `read` that
# hits EOF returns non-zero AND blanks the variables it was assigning, so
# remote_ref is always empty after the loop, the fallback always fired, and a
# push of a scratch branch was gated as though it were main. Caught by running
# the hook against a wip ref before trusting it.
GATED=0
SAW_INPUT=0
while read -r _local_ref _local_sha pushed_ref _remote_sha; do
  SAW_INPUT=1
  case "$pushed_ref" in
    refs/heads/main|refs/heads/ship/*) GATED=1 ;;
  esac
done
if [ "$SAW_INPUT" -eq 0 ]; then
  case "$(git rev-parse --abbrev-ref HEAD)" in
    main|ship/*) GATED=1 ;;
  esac
fi

if [ "$GATED" -eq 0 ]; then
  echo "pre-push: branch does not trigger a workflow — gates skipped"
  exit 0
fi

echo "════════════════════════════════════════════════════════════════"
echo " pre-push gates — the same phases ios-publish.yml runs in CI"
echo " (bypass: git push --no-verify)"
echo "════════════════════════════════════════════════════════════════"

# The T25 conformance target starts a REAL relay; absent, P3 is a refusal, not a
# skip. Resolve it the way CI does rather than making the pusher know about it.
# Any prebuilt binary first — including in sibling worktrees, because the
# foundry checkouts here are transient (the worktree-sweep agent removed the one
# this hook originally hard-coded, hours after it was written).
if [ -z "${FOUNDRYX_CONFORMANCE_RELAY_BIN:-}" ]; then
  found="$(ls -t "$HOME"/Development/*/target/release/foundry-relay 2>/dev/null | head -1)"
  [ -n "$found" ] && export FOUNDRYX_CONFORMANCE_RELAY_BIN="$found"
fi
# Else build it from a checkout that actually CONTAINS the crate. Which checkout
# that is cannot be assumed: `~/Development/foundry` tracks whatever branch is in
# flight, and on 2026-08-13 that branch had the crate mid-rename, so a hard-coded
# `-p foundry-relay` there failed with "did not match any packages" while main
# had it all along. Find the crate, then build where it lives.
if [ -z "${FOUNDRYX_CONFORMANCE_RELAY_BIN:-}" ]; then
  echo "pre-push: no prebuilt relay — locating the crate"
  for root in "$HOME"/Development/foundry "$HOME"/Development/foundry-wt-* "$HOME"/Development/*/foundry; do
    [ -f "$root/crates/foundry-relay/Cargo.toml" ] || continue
    echo "pre-push: building foundry-relay in $root"
    if ( cd "$root" && cargo build --release -p foundry-relay --bin foundry-relay -q ); then
      export FOUNDRYX_CONFORMANCE_RELAY_BIN="$root/target/release/foundry-relay"
      break
    fi
  done
fi
if [ ! -x "${FOUNDRYX_CONFORMANCE_RELAY_BIN:-/nonexistent}" ]; then
  echo "PRE-PUSH BLOCKED: no foundry-relay binary and no checkout containing"
  echo "crates/foundry-relay. The P3 conformance lane would report refusals that"
  echo "look like product defects (it did, on 2026-08-12). Check out foundry main"
  echo "and build it, or export FOUNDRYX_CONFORMANCE_RELAY_BIN yourself."
  exit 1
fi
echo "pre-push: relay = $FOUNDRYX_CONFORMANCE_RELAY_BIN"

# THE PHASE LIST IS DERIVED, NOT TYPED. Each CI job's `ci-gates.sh <phases>` line
# is read out of the workflow, so a phase added to CI is gated here on the next
# push with no edit to this file — the drift that let iosbrine sit unrun cannot
# silently reopen. `iosbrine` is appended because CI's simulator job runs that
# coverage through a hand-rolled xcodebuild invocation (a deliberate perf
# optimisation: test-without-building off the compile job's products) rather than
# through the script.
WF=".github/workflows/ios-publish.yml"
PHASES="$(grep -oE 'bash scripts/ci-gates\.sh [a-z ]+' "$WF" 2>/dev/null \
          | sed 's|bash scripts/ci-gates.sh ||' | tr ' ' '\n' | grep . | sort -u | tr '\n' ' ')"
[ -n "$PHASES" ] || PHASES="swift gates compile leak lint"
case " $PHASES " in *" iosbrine "*) ;; *) PHASES="$PHASES iosbrine" ;; esac

echo "pre-push: phases = $PHASES"
echo ""
START=$SECONDS
if bash scripts/ci-gates.sh $PHASES; then
  echo ""
  echo "pre-push: ALL GATES PASS in $(( (SECONDS - START) / 60 ))m — pushing"
  exit 0
fi
echo ""
echo "════════════════════════════════════════════════════════════════"
echo " PUSH BLOCKED — these gates fail HERE, so they would fail in CI."
echo " Fix them locally; CI is not the place to find this out."
echo " Elapsed: $(( (SECONDS - START) / 60 ))m. Bypass: git push --no-verify"
echo "════════════════════════════════════════════════════════════════"
exit 1
