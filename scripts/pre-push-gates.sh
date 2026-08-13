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

# CONFORMANCE BINARIES — DERIVED FROM CI, NOT LISTED HERE.
#
# The conformance targets start REAL processes; absent, every predicate is a
# REFUSAL that reads exactly like a product defect. There are two today and the
# first version of this hook resolved only one: it built the P3 relay, left
# FOUNDRYX_CONFORMANCE_TUNNEL_BIN unset, and P1/A9 refused — so the hook BLOCKED
# a merge whose tree was fine, on a red it manufactured itself. A hook that cries
# wolf gets bypassed, which would have cost more than the bug it was added for.
#
# So the pairs are read out of the workflow: each `cargo build … -p PKG --bin BIN`
# and the `export FOUNDRYX_CONFORMANCE_*_BIN=…/BIN` beside it. A third binary
# added to CI is resolved here on the next push with no edit to this file.
CI_WF=".github/workflows/ios-publish.yml"
resolve_conformance_bins() {
  local var pkg bin found root
  # Pair each exported *_BIN var with the --bin it points at, in workflow order.
  while IFS='|' read -r var bin pkg; do
    [ -n "$var" ] || continue
    # already set by the caller? honour it.
    eval "current=\${$var:-}"
    if [ -n "${current:-}" ] && [ -x "${current}" ]; then
      echo "pre-push: $var = $current (inherited)"; continue
    fi
    found="$(ls -t "$HOME"/Development/*/target/release/"$bin" 2>/dev/null | head -1)"
    if [ -z "$found" ]; then
      # Build where the crate actually lives: ~/Development/foundry tracks
      # whatever branch is in flight, and on 2026-08-13 that branch had the
      # crate mid-rename while main had it all along.
      for root in "$HOME"/Development/foundry "$HOME"/Development/foundry-wt-* "$HOME"/Development/*/foundry; do
        [ -f "$root/Cargo.toml" ] || continue
        echo "pre-push: building $pkg ($bin) in $root"
        if ( cd "$root" && cargo build --release -p "$pkg" --bin "$bin" -q 2>/dev/null ); then
          found="$root/target/release/$bin"; break
        fi
      done
    fi
    if [ ! -x "${found:-/nonexistent}" ]; then
      echo "PRE-PUSH BLOCKED: could not resolve $var (binary '$bin' from package"
      echo "'$pkg'). Its conformance lane would report refusals that look like"
      echo "product defects. Build it in a foundry checkout, or export $var."
      exit 1
    fi
    export "$var=$found"
    echo "pre-push: $var = $found"
  done <<EOF
$(awk '
  /cargo build --release -p/ { for (i=1;i<=NF;i++) { if ($i=="-p") pkg=$(i+1); if ($i=="--bin") bin=$(i+1) } }
  /export FOUNDRYX_CONFORMANCE_[A-Z]+_BIN=/ {
    v=$0; sub(/^[^A-Z]*/,"",v); sub(/=.*/,"",v);
    if (pkg && bin) print v "|" bin "|" pkg;
  }' "$CI_WF")
EOF
}
resolve_conformance_bins

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
