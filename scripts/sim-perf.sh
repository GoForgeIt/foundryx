#!/usr/bin/env bash
# sim-perf — large-library launch-perf harness for a chosen simulated iPhone.
#
# Answers "is the app fast on an iPhone SE vs a 17 Pro when the library is big?"
# by seeding N synthetic conversations (-StressSeed), cold-launching the app on a
# named simulator, and reading the app's OWN perf spans (capture-hydrate,
# capture-list-first-paint) back out of the unified log. The simulator device IS
# the emulated iPhone type — run it across several to get a device matrix.
#
# Usage:
#   scripts/sim-perf.sh                         # iPhone 17 Pro, N=500
#   scripts/sim-perf.sh "iPhone SE (3rd generation)" 1000
#   scripts/sim-perf.sh "iPhone 16 Pro" 300
#
# Budget: capture-hydrate should stay under HYDRATE_BUDGET_MS (default 800ms) —
# the 7.5s cold-launch hang we shipped would have blown this wide open. Exit 1 on
# breach so it can gate. Requires the Debug sim build (built here if missing).
set -euo pipefail
cd "$(dirname "$0")/.."

DEVICE="${1:-iPhone 17 Pro}"
N="${2:-500}"
SEGS="${3:-156}"              # avg segment files per capture (0 = card-only, pre-track behavior)
HYDRATE_BUDGET_MS="${HYDRATE_BUDGET_MS:-800}"
FIRSTPAINT_BUDGET_MS="${FIRSTPAINT_BUDGET_MS:-300}"    # track 20260717T0759 AC4/AC6
# capture-status-warm on a COLD status cache. Was 5000 — which rubber-stamped a measured
# 2343ms warm and could never have failed. 1000ms is the honest number: a cold warm pass over
# a stress library must not cost the user a full second (track 20260722T1244 AC3).
WARM_BUDGET_MS="${WARM_BUDGET_MS:-1000}"               # capture-status-warm, cold status cache
REWARM_BUDGET_MS="${REWARM_BUDGET_MS:-500}"            # SECOND launch: cache hit, no re-scan
# THIRD launch, after the churn drive deleted the durable `.status-cache.json` of every
# capture it touched: the re-warm is measured against an INVALIDATED cache, not the all-valid
# static one the 500ms re-warm budget blesses.
#
# MEASURED, not aspired to: 1002ms on an iPhone 17 Pro at N=175 / ~31k segment files
# (2026-07-22). Over a 45s drive the rotating churn window sweeps the whole library, so this
# is effectively a full rescan minus the seeding cost — which is why it lands near the cold
# `status-warm` number rather than near `re-warm`. It is a RATCHET at today's truth (the same
# convention `RECORD_BUDGET_MS` documents above): it cannot get worse without failing, and it
# is the number to drive down when the warm scan itself is made incremental.
#
# S5 (review): 1100 on a SINGLE 1002ms sample is 9.8% headroom on a machine-dependent
# wall-clock measured on a laptop that also runs a simulator, a test runner and whatever else.
# ~10% is inside normal run-to-run variance for a disk-bound scan, so it would have false-redded
# and taught everyone to re-run rather than to look. 1400 is ~40% over the one measured sample:
# still far tighter than the 5000ms rubber stamp this family of budgets started at, still
# catches the class it exists for (a re-warm that regresses toward the multi-second cold path),
# and does not pretend one sample on one machine is a precise number. The way to tighten it is
# more samples, not a narrower guess.
CHURN_REWARM_BUDGET_MS="${CHURN_REWARM_BUDGET_MS:-1400}"
# Nav budgets. tab-switch gates the WARMED lap (the UITest's first cycle builds each
# tab once; steady-state is what users feel all day — measured 34-90ms vs 150-200ms
# first-build). record-start is a RATCHET at today's truth: the 384ms is entirely
# SwiftUI fullScreenCover presentation (record-start-sync measures our begin work at
# 0ms) — the <200ms goal needs presentation pre-warm (named next target, track
# 20260717T0759). The stall ceiling is tied to the record budget because the record
# present IS the one known >250ms main-thread turn; tighten both together.
TAB_BUDGET_MS="${TAB_BUDGET_MS:-100}"                  # nav phase: tab-switch (warmed lap)
RECORD_BUDGET_MS="${RECORD_BUDGET_MS:-450}"            # nav phase: record-start (goal: 200)
# The stall ceiling is now the PRODUCTION SENSOR'S OWN THRESHOLD (250ms —
# App/PerfMetricsSubscriber.swift:147). It was 450: a gate looser than the sensor that fires in
# users' hands is not a gate, it is a rubber stamp (track 20260722T1244 AC3). The record-start
# budget stays 450 because the fullScreenCover present is a KNOWN, separately-tracked cost; it
# is measured by its own span, not by the stall sensor.
STALL_CEILING_MS="${STALL_CEILING_MS:-250}"            # nav phase: no stall above this
NAV="${NAV:-1}"               # NAV=0 skips the UITest-driven nav-budget phase
CHURN="${CHURN:-1}"           # CHURN=0 skips the churn-interleaved CQRS phase
BUNDLE_ID="com.goforgeit.foundryx"
# Dedicated DerivedData so the .app path is predictable. Overridable so two harness runs on
# one machine do not fight over the same XCBuildData/build.db (xcodebuild fails outright with
# "database is locked" when they do).
DD="${SIM_PERF_DD:-build/sim-perf-dd}"

echo "==> sim-perf: device='$DEVICE'  N=$N  segs≈$SEGS  budgets: hydrate<${HYDRATE_BUDGET_MS} first-paint<${FIRSTPAINT_BUDGET_MS} warm<${WARM_BUDGET_MS} tab<${TAB_BUDGET_MS} record<${RECORD_BUDGET_MS}"

# 1. Resolve (create if absent) the simulator UDID for this device type.
UDID="$(xcrun simctl list devices available | grep -F "$DEVICE (" | head -1 \
        | grep -oE '[0-9A-F-]{36}' | head -1 || true)"
if [ -z "$UDID" ]; then
  echo "==> creating simulator '$DEVICE'"
  # N4: `|| true` is REQUIRED. Under `set -euo pipefail` a `grep` that matches nothing (no iOS
  # runtime installed) fails the pipeline and aborts the harness with no diagnosis at all.
  RUNTIME="$(xcrun simctl list runtimes | grep -oE 'com.apple.CoreSimulator.SimRuntime.iOS[^ ]*' | tail -1 || true)"
  [ -n "$RUNTIME" ] || { echo "FAIL — no iOS simulator runtime installed; cannot create '$DEVICE'"; exit 2; }
  UDID="$(xcrun simctl create "sim-perf-$DEVICE" "$DEVICE" "$RUNTIME")"
fi
echo "==> simulator UDID: $UDID"
xcrun simctl boot "$UDID" 2>/dev/null || true

# 2. Build the app for the simulator (skip if already built into $DD).
# RELEASE build with the PERF_HARNESS compilation condition: Debug's unoptimized
# SwiftUI inflated nav numbers ~2-5x (246ms tab-switch that Release renders far
# faster), which would force vanity budgets. PERF_HARNESS re-enables the DEBUG-gated
# seed/-PerfLog/watchdog harness hooks in an otherwise-Release binary — budgets stay
# the track's real, device-scale numbers.
APP="$DD/Build/Products/PerfRelease-iphonesimulator/FoundryX.app"
# ALWAYS build (same family of defect as ci-gates S10): the old `[ ! -d "$APP" ]` guard meant
# that once a .app existed, every later run measured THAT BINARY — a source change you were
# trying to measure, or a seam you had just deleted, was simply not in the build under test.
# xcodebuild is incremental, so an unchanged tree costs seconds.
echo "==> building FoundryX (PerfRelease, simulator) into $DD"
xcodegen generate >/dev/null
xcodebuild build -project FoundryX.xcodeproj -scheme FoundryX -configuration PerfRelease \
  -destination "id=$UDID" -derivedDataPath "$DD" CODE_SIGNING_ALLOWED=NO >build/sim-perf-build.log 2>&1 \
  || { echo "FAIL — PerfRelease build failed:"; grep -aE "error:" build/sim-perf-build.log | head -20; exit 2; }
[ -d "$APP" ] || { echo "build produced no .app at $APP"; exit 2; }

# 3. Fresh install (uninstall first so the seeded library is the ONLY content).
xcrun simctl uninstall "$UDID" "$BUNDLE_ID" 2>/dev/null || true
xcrun simctl install "$UDID" "$APP"

# Rescue helper: `simctl launch --console-pty` intermittently captures NOTHING
# (observed on fresh sims). The spans also land in the unified log — if the console
# file has none, pull them from `log show` since the given start instant.
rescue_spans() {   # logfile start_time
  grep -q "perf-span" "$1" 2>/dev/null && return 0
  echo "==> console capture empty — rescuing spans from the unified log"
  # Bounded at both ends and pinned to the app's own process, same as `collect_spans` (S4):
  # an unbounded window would fold a neighbouring phase's spans into this launch's numbers.
  xcrun simctl spawn "$UDID" log show --start "$2" --end "$(date '+%Y-%m-%d %H:%M:%S')" \
      --style compact \
      --predicate 'processImagePath CONTAINS "FoundryX.app/FoundryX" AND eventMessage CONTAINS "perf-span"' \
      2>/dev/null \
    | grep -oE "perf-span [a-z0-9-]+ ms=[0-9]+" >> "$1" || true
}

# 4. Launch with the stress seed + perf-log mirror; capture the console.
LOG="build/sim-perf-$(echo "$DEVICE" | tr ' ()' '___')-N$N.log"
LAUNCH_START="$(date '+%Y-%m-%d %H:%M:%S')"
echo "==> launching (stress-seed $N) — console → $LOG"
# --console-pty streams the app's stdout/NSLog until it exits or we time out.
( xcrun simctl launch --console-pty "$UDID" "$BUNDLE_ID" \
    -StressSeed "$N" -StressSegs "$SEGS" -MainPreview -PerfLog >"$LOG" 2>&1 ) &
LAUNCH_PID=$!
# Wait for the WARM span (the last launch-path span) instead of a fixed sleep —
# first launch also pays the synthetic segment seeding, which can take a while.
for _ in $(seq 1 120); do
  grep -q "perf-span capture-status-warm" "$LOG" 2>/dev/null && break
  sleep 1
done
sleep 2   # let trailing spans flush
xcrun simctl terminate "$UDID" "$BUNDLE_ID" 2>/dev/null || true
kill "$LAUNCH_PID" 2>/dev/null || true
wait "$LAUNCH_PID" 2>/dev/null || true
rescue_spans "$LOG" "$LAUNCH_START"

# 4b. RELAUNCH (no uninstall): the durable status cache + warm-rows index only pay off
#     on the SECOND launch — a fresh install always walks the cold path, so a
#     fresh-install-only harness can NEVER catch a cache regression (measured: pre-fix
#     1907ms vs post-fix-cold 1563ms — indistinguishable; post-fix WARM is the win).
RELOG="build/sim-perf-relaunch-$(echo "$DEVICE" | tr ' ()' '___')-N$N.log"
RELAUNCH_START="$(date '+%Y-%m-%d %H:%M:%S')"
echo "==> relaunching (warm caches) — console → $RELOG"
( xcrun simctl launch --console-pty "$UDID" "$BUNDLE_ID" \
    -StressSeed "$N" -StressSegs "$SEGS" -MainPreview -PerfLog >"$RELOG" 2>&1 ) &
RELAUNCH_PID=$!
for _ in $(seq 1 60); do
  grep -q "perf-span capture-status-warm" "$RELOG" 2>/dev/null && break
  sleep 1
done
sleep 2
xcrun simctl terminate "$UDID" "$BUNDLE_ID" 2>/dev/null || true
kill "$RELAUNCH_PID" 2>/dev/null || true
wait "$RELAUNCH_PID" 2>/dev/null || true
rescue_spans "$RELOG" "$RELAUNCH_START"

# 5. Pull the perf spans back out and check the budget.
echo ""
echo "==> perf spans (device='$DEVICE', N=$N):"
grep -oE "perf-span [a-z0-9-]+ ms=[0-9]+" "$LOG" | sort -u || true

HYDRATE_MS="$(grep -oE "perf-span capture-hydrate[^ ]* ms=[0-9]+" "$LOG" \
              | grep -oE 'ms=[0-9]+' | grep -oE '[0-9]+' | sort -n | tail -1 || true)"
FIRSTPAINT_MS="$(grep -oE "perf-span capture-list-first-paint ms=[0-9]+" "$LOG" \
                 | grep -oE 'ms=[0-9]+' | grep -oE '[0-9]+' | sort -n | tail -1 || true)"

WARM_MS="$(grep -oE "perf-span capture-status-warm[^ ]* ms=[0-9]+" "$LOG" \
           | grep -oE 'ms=[0-9]+' | grep -oE '[0-9]+' | sort -n | tail -1 || true)"
REWARM_MS="$(grep -oE "perf-span capture-status-warm[^ ]* ms=[0-9]+" "$RELOG" \
             | grep -oE 'ms=[0-9]+' | grep -oE '[0-9]+' | sort -n | tail -1 || true)"

FAILED=""
WARNED=""

# ------------------------------------------------------- S6: KNOWN OPEN GAP vs YOUR REGRESSION
# Two of these budgets are red TODAY on truthful numbers (`status-warm` measured 1538 against an
# honest 1000ms budget). Leaving the budget at the honest number is right; leaving the HARNESS
# permanently red is how a gate gets muted inside a week, and then it stops catching anything.
#
# `scripts/perf-baseline.tsv` is the ledger of those known gaps: `<metric> <baseline> <ticket>`.
#   • value  > baseline           → HARD FAIL. You made a tracked gap worse.
#   • budget < value <= baseline  → LOUD WARN, named with its ticket. Known, tracked, not yours.
#   • value <= budget             → PASS, and the harness tells you to DELETE the stale baseline
#                                   line, so the ratchet closes behind you.
# An entry without a ticket reference is not a known gap, it is an excuse: it hard-fails.
BASELINE_FILE="${BASELINE_FILE:-scripts/perf-baseline.tsv}"
baseline_for() {   # metric → "<value> <ticket>" or empty
  [ -f "$BASELINE_FILE" ] || return 0
  awk -v m="$1" '$1 !~ /^#/ && $1 == m { print $2, $3; exit }' "$BASELINE_FILE"
}

check_budget() {   # label value budget  (empty value = missing span → fail)
  local label="$1" value="$2" budget="$3"
  local metric; metric="$(echo "$label" | tr -d ' ')"
  if [ -z "$value" ]; then
    echo "  $label : (no span captured — see $LOG)"
    FAILED="$FAILED $metric(missing)"
    return
  fi
  local base; base="$(baseline_for "$metric")"
  local bval; bval="$(echo "$base" | awk '{print $1}')"
  local btick; btick="$(echo "$base" | awk '{print $2}')"
  if [ "$value" -le "$budget" ]; then
    echo "  $label : ${value}ms  (budget ${budget}ms)"
    if [ -n "$bval" ]; then
      echo "      ↳ NOW UNDER BUDGET — delete the '$metric' line from $BASELINE_FILE (ratchet)"
    fi
    return
  fi
  if [ -n "$bval" ] && [ -z "$btick" ]; then
    echo "  $label : ${value}ms  (budget ${budget}ms)  BASELINE WITHOUT A TICKET — not a known gap"
    FAILED="$FAILED $metric(untracked-baseline)"
    return
  fi
  if [ -n "$bval" ] && [ "$value" -le "$bval" ]; then
    echo "  $label : ${value}ms  (budget ${budget}ms)  ⚠ KNOWN OPEN GAP ≤${bval}ms — $btick"
    WARNED="$WARNED $metric(${value}>${budget},known≤${bval},$btick)"
    return
  fi
  if [ -n "$bval" ]; then
    echo "  $label : ${value}ms  (budget ${budget}ms)  REGRESSED PAST THE TRACKED BASELINE ${bval}ms ($btick)"
    FAILED="$FAILED $metric(${value}>baseline:${bval})"
    return
  fi
  echo "  $label : ${value}ms  (budget ${budget}ms)"
  FAILED="$FAILED $metric(${value}>${budget})"
}

# Same ledger, for COUNT ceilings (stalls) rather than millisecond budgets.
check_count() {   # metric value ceiling
  local metric="$1" value="$2" ceiling="$3"
  [ "$value" -le "$ceiling" ] && return 0
  local base; base="$(baseline_for "$metric")"
  local bval; bval="$(echo "$base" | awk '{print $1}')"
  local btick; btick="$(echo "$base" | awk '{print $2}')"
  if [ -n "$bval" ] && [ -n "$btick" ] && [ "$value" -le "$bval" ]; then
    echo "      ↳ ⚠ KNOWN OPEN GAP ≤${bval} — $btick"
    WARNED="$WARNED $metric(${value}>${ceiling},known≤${bval},$btick)"
    return 0
  fi
  FAILED="$FAILED $metric(${value}>${ceiling})"
}

# A FLOOR, not a ceiling: proof that a thing actually happened. Never baseline-excusable —
# "the drive did not run" is not a known perf gap, it is a broken gate.
check_min() {     # metric value floor
  local metric="$1" value="$2" floor="$3"
  if [ "${value:-0}" -lt "$floor" ]; then
    echo "      ↳ FLOOR BREACHED: $metric=${value:-0}, need ≥${floor}"
    FAILED="$FAILED $metric(only:${value:-0}<${floor})"
  fi
}

echo ""
check_budget "hydrate    " "$HYDRATE_MS"    "$HYDRATE_BUDGET_MS"
check_budget "first-paint" "$FIRSTPAINT_MS" "$FIRSTPAINT_BUDGET_MS"
check_budget "status-warm" "$WARM_MS"       "$WARM_BUDGET_MS"
check_budget "re-warm    " "$REWARM_MS"     "$REWARM_BUDGET_MS"

# ---------------------------------------------------------------- S4: a BOUNDED log window
# `log show --start <t>` with no `--end` and no process predicate returns everything from t to
# NOW — so a stall emitted by an EARLIER phase (the nav phase's 450ms landed 14s before the
# churn drive even started) was read back as if the churn had caused it, and so was anything
# any other process on the machine logged. The window is now closed at both ends and pinned to
# the app's own image path (`FoundryX.app/FoundryX` — which does NOT match the
# `FoundryXUITests-Runner` executable).
collect_spans() {   # start end   → raw matching log lines (spans AND stall stacks)
  xcrun simctl spawn "$UDID" log show --start "$1" --end "$2" --style compact \
    --predicate 'processImagePath CONTAINS "FoundryX.app/FoundryX" AND (eventMessage CONTAINS "perf-span" OR eventMessage CONTAINS "stallstack" OR eventMessage CONTAINS "perf-harness")' \
    2>/dev/null || true
}

# ------------------------------------------------- S3: the nav-stall signal has a DRIVER in it
# The only `stallstack` sampled across a whole session was
# `XCTAutomationSupport → Foundation → CoreFoundation → UIKitCore → SwiftUI` (502ms): XCUITest's
# OWN accessibility querying blocking the app's main thread. Gating on a number that includes
# the measuring instrument contradicts this track's R5 (deterministic over timing) and will
# flake red on a busy machine.
#
# CHOICE MADE (be explicit): BOTH halves of the review's option list, in this order —
#   • the DETERMINISTIC churn-write count is the PRIMARY churn assertion (a fixed count of
#     command-side spans; no wall-clock in it at all);
#   • the stall assertion is KEPT as a real failure, but stalls whose sampled backtrace names
#     the automation driver are attributed to the driver and reported, not failed.
# Stalls in 250–400ms never get a backtrace (the sampler's own capture threshold is 400ms), so
# they are always attributed to the product and always fail. That is the honest split.
#
# stall_verdict <spans> <stacklines> → prints "<n_product> <n_driver>"
stall_verdict() {
  local spans="$1" stacks="$2"
  # ms values of stalls whose sampled stack names the automation driver.
  # EVERY grep here must be allowed to match NOTHING. Under `set -o pipefail` a non-matching
  # grep fails the whole pipeline, and the callers' `|| echo "0 0"` fallback then fired IN
  # ADDITION to awk's own "0 0" — producing a TWO-LINE verdict, so `[ "$CHURN_STALLS" -gt 0 ]`
  # died with "integer expected" and the churn stall assertion silently could not fail. That is
  # the exact "gate that cannot fail" class this track exists to kill, found in this gate.
  local drv; drv="$( { echo "$stacks" \
      | grep -E "XCTAutomationSupport|XCTestCore|libXCTTargetBootstrap" \
      | grep -oE "stallstack ms=[0-9]+" | grep -oE '[0-9]+$' | sort -u; } || true )"
  { echo "$spans" | grep -E "^perf-span nav-stall " | grep -oE '[0-9]+$' || true; } \
    | awk -v c="$STALL_CEILING_MS" -v d="$drv" '
        BEGIN { n = split(d, a, "\n"); for (i = 1; i <= n; i++) if (a[i] != "") driver[a[i]] = 1 }
        $1 > c { if ($1 in driver) dcount++; else pcount++ }
        END { printf "%d %d\n", pcount + 0, dcount + 0 }'
}

# 6. Nav-budget phase (track 20260717T0759 AC6): drive real tab switches + a record
#    start via PerfBudgetNavUITests; the app emits tab-switch / record-start /
#    nav-stall spans; we read them from the unified log SINCE this phase started.
if [ "$NAV" = "1" ]; then
  echo ""
  echo "==> nav phase: PerfBudgetNavUITests on '$DEVICE'"
  xcrun simctl privacy "$UDID" grant microphone "$BUNDLE_ID" 2>/dev/null || true
  NAV_START="$(date '+%Y-%m-%d %H:%M:%S')"
  NAVLOG="build/sim-perf-nav-$(echo "$DEVICE" | tr ' ()' '___')-N$N.log"
  if ! xcodebuild test -project FoundryX.xcodeproj -scheme FoundryXUIProof \
      -configuration PerfRelease \
      -destination "id=$UDID" -derivedDataPath "$DD" \
      -only-testing:FoundryXUITests/PerfBudgetNavUITests/testNormalNavDriveEmitsBudgetSpans \
      -only-testing:FoundryXUITests/PerfBudgetNavUITests/testDeepNavDriveListTranscriptAndSpeakerSheet \
      -only-testing:FoundryXUITests/PerfBudgetNavUITests/testDeepNavSpeakerSheetUnderStallWatch \
      CODE_SIGNING_ALLOWED=NO >"$NAVLOG" 2>&1; then
    echo "FAIL — nav drive itself failed (see $NAVLOG)"
    exit 1
  fi
  NAV_END="$(date '+%Y-%m-%d %H:%M:%S')"
  SPANS="$(collect_spans "$NAV_START" "$NAV_END" | grep -oE "perf-span [a-z0-9-]+ ms=[0-9]+" || true)"
  NAV_STACKS="$(collect_spans "$NAV_START" "$NAV_END" | grep -F "stallstack" || true)"
  span_max() { echo "$SPANS" | grep -E "^perf-span $1 " | grep -oE '[0-9]+$' | sort -n | tail -1; }
  # Warmed-lap tab switches = the LAST 4 spans chronologically (lap 2 of 2).
  TAB_MS="$(echo "$SPANS" | grep -E "^perf-span tab-switch " | grep -oE '[0-9]+$' | tail -4 | sort -n | tail -1 || true)"
  TAB_COLD_MS="$(span_max tab-switch || true)"
  RECORD_MS="$(span_max record-start || true)"
  # `|| true`: with `set -o pipefail`, a `grep` that matches NOTHING (the healthy case —
  # zero stalls) fails the whole pipeline and, under `set -e`, would abort the harness at
  # exactly the moment it was passing.
  VERDICT="$(stall_verdict "$SPANS" "$NAV_STACKS" | head -1)"
  [ -n "$VERDICT" ] || VERDICT="0 0"
  STALLS="$(echo "$VERDICT" | awk '{print $1}')"
  STALLS_DRIVER="$(echo "$VERDICT" | awk '{print $2}')"
  echo ""
  check_budget "tab-switch " "$TAB_MS"    "$TAB_BUDGET_MS"
  [ -n "$TAB_COLD_MS" ] && echo "  tab-cold    : ${TAB_COLD_MS}ms  (first-build, informational)"
  check_budget "record-st  " "$RECORD_MS" "$RECORD_BUDGET_MS"
  echo "  nav-stalls  : ${STALLS:-0} product over ${STALL_CEILING_MS}ms  (budget: 0)" \
       "; ${STALLS_DRIVER:-0} attributed to the XCUITest driver (excluded, see S3)"
  if [ "${STALLS:-0}" -gt 0 ]; then
    echo "$SPANS" | grep -E "^perf-span nav-stall " || true
    check_count "nav-stall" "${STALLS}" 0
  fi
fi

# 7. CHURN-INTERLEAVED CQRS phase (track 20260722T1244 — the hole this whole wave exists for).
#
#    Everything above measures the QUERY side against a static, pre-warmed, read-only library.
#    The device pathology is a list rebuild that runs a beat AFTER a COMMAND invalidated the
#    read-model memos (sidecarCache / metaCache / startTimeCache / .status-cache.json). This
#    phase drives the app under CONTINUOUS real write traffic — segment append, drain ACK,
#    status-poller card merge, finalize — at N=175 on the skewed-heavy seed, and asserts ZERO
#    `nav-stall` spans over the production sensor's own 250ms threshold.
#
#    It then RELAUNCHES: the churn deleted a slice of the durable `.status-cache.json` files,
#    so the re-warm below is measured against a PARTIALLY INVALIDATED cache rather than the
#    all-valid static one the 500ms re-warm budget blesses (AC4).
if [ "$CHURN" = "1" ]; then
  echo ""
  echo "==> churn phase: write-interleaved nav drive (N=$N, -StressChurn 200ms) on '$DEVICE'"
  CHURN_START="$(date '+%Y-%m-%d %H:%M:%S')"
  CHURNLOG="build/sim-perf-churn-$(echo "$DEVICE" | tr ' ()' '___').log"
  # S9: the drive used to hardcode -StressSeed 175 and ignore this script's N entirely, so a
  # `sim-perf.sh "iPhone SE" 1000` run reported churn numbers for a 175-capture library under a
  # "N=1000" heading. xcodebuild forwards TEST_RUNNER_-prefixed variables into the test runner's
  # environment; the UITest reads FX_STRESS_N. Propagation is VERIFIED below against the size
  # the app says it seeded — a silent fallback to 175 is a failure, not a default.
  if ! TEST_RUNNER_FX_STRESS_N="$N" xcodebuild test -project FoundryX.xcodeproj -scheme FoundryXUIProof \
      -configuration PerfRelease \
      -destination "id=$UDID" -derivedDataPath "$DD" \
      -only-testing:FoundryXUITests/PerfBudgetNavUITests/testChurnInterleavedNavDriveEmitsNoStalls \
      CODE_SIGNING_ALLOWED=NO >"$CHURNLOG" 2>&1; then
    echo "FAIL — churn drive itself failed (see $CHURNLOG)"
    exit 1
  fi
  CHURN_END="$(date '+%Y-%m-%d %H:%M:%S')"
  CHURN_RAW="$(collect_spans "$CHURN_START" "$CHURN_END")"
  CHURN_SPANS="$(echo "$CHURN_RAW" | grep -oE "perf-span [a-z0-9-]+ ms=[0-9]+" || true)"
  CHURN_STACKS="$(echo "$CHURN_RAW" | grep -F "stallstack" || true)"

  # ------------------------------------------------------------ B3: PROOF THE COMMANDS RAN
  # The old proof-of-life counted `tab-switch` spans — evidence that NAVIGATION happened, which
  # says nothing about whether a single COMMAND ever ran. Delete `StressChurn.installIfRequested`
  # from RootView, rename the seed prefix out from under `stressIds`, or let the timer never
  # fire, and the drive still emitted tab switches, still saw zero stalls, and PASSED — putting
  # back exactly the CQRS hole this phase exists to close. `churn-rewarm` cannot cover for it
  # either: it is an upper bound, so a DEAD churn (~220ms re-warm) sails under it.
  #
  # The churn now emits its own span per COMPLETED write batch (`churn-write`, and
  # `churn-write-live` when a live recording put the active capture in the window), and only
  # when bytes actually landed on disk. This is the PRIMARY churn assertion: a deterministic
  # count, no wall-clock in it.
  #
  # FLOOR ARITHMETIC: 45s of drive at one 200ms tick = ~225 batches. The floor is set well
  # below that (60) so timer coalescing, a slow machine, or a late arm cannot false-red it,
  # while ZERO or a handful — every way the churn can silently die — is unambiguously red.
  CHURN_WRITES="$( { echo "$CHURN_SPANS" | grep -cE "^perf-span churn-write ms="; } || true )"
  CHURN_LIVE="$( { echo "$CHURN_SPANS" | grep -cE "^perf-span churn-write-live ms="; } || true )"
  CHURN_TABS="$( { echo "$CHURN_SPANS" | grep -cE "^perf-span tab-switch "; } || true )"
  CHURN_TOTAL="$( { echo "$CHURN_SPANS" | grep -c .; } || true )"
  echo "  churn spans : ${CHURN_TOTAL:-0} total, ${CHURN_TABS:-0} tab-switch, ${CHURN_WRITES:-0} churn-write, ${CHURN_LIVE:-0} churn-write-live"
  check_min "churn-write" "${CHURN_WRITES:-0}" 60
  check_min "churn-tab-switch" "${CHURN_TABS:-0}" 8
  # S8: the live/active branch of `invalidateSidecar` (CaptureManager.swift:1703) is the
  # highest-traffic write path while a recording runs and is where the real "stale card up to
  # 5s" defect lived. It is only reachable with an ACTIVE capture, so the drive starts a real
  # recording (-SyntheticMic) and this floor makes a recording that failed to start RED rather
  # than a quiet reduction back to the query-only case.
  check_min "churn-write-live" "${CHURN_LIVE:-0}" 30

  # S9: the app announces the library size it actually seeded; it must be the N asked for.
  CHURN_SEEDED="$(echo "$CHURN_RAW" | grep -oE "stress-seed n=[0-9]+" | grep -oE '[0-9]+$' | tail -1 || true)"
  echo "  churn seed  : n=${CHURN_SEEDED:-?} (requested $N)"
  if [ "${CHURN_SEEDED:-0}" != "$N" ]; then
    FAILED="$FAILED churn-seed-size(seeded:${CHURN_SEEDED:-none}!=requested:$N)"
  fi

  CHURN_VERDICT="$(stall_verdict "$CHURN_SPANS" "$CHURN_STACKS" | head -1)"
  [ -n "$CHURN_VERDICT" ] || CHURN_VERDICT="0 0"
  CHURN_STALLS="$(echo "$CHURN_VERDICT" | awk '{print $1}')"
  CHURN_STALLS_DRIVER="$(echo "$CHURN_VERDICT" | awk '{print $2}')"
  echo "  churn-stalls: ${CHURN_STALLS:-0} product over ${STALL_CEILING_MS}ms  (budget: 0)" \
       "; ${CHURN_STALLS_DRIVER:-0} attributed to the XCUITest driver (excluded, see S3)"
  if [ "${CHURN_STALLS:-0}" -gt 0 ]; then
    echo "$CHURN_SPANS" | grep -E "^perf-span nav-stall " || true
    check_count "churn-nav-stall" "${CHURN_STALLS}" 0
  fi

  # 7b. warm → churn → RELAUNCH: re-warm against the partially invalidated status cache.
  echo "==> post-churn relaunch (partially invalidated status cache)"
  CRLOG="build/sim-perf-churn-relaunch-$(echo "$DEVICE" | tr ' ()' '___').log"
  CR_START="$(date '+%Y-%m-%d %H:%M:%S')"
  ( xcrun simctl launch --console-pty "$UDID" "$BUNDLE_ID" \
      -StressSeed "$N" -StressSegs "$SEGS" -MainPreview -PerfLog >"$CRLOG" 2>&1 ) &
  CR_PID=$!
  for _ in $(seq 1 90); do
    grep -q "perf-span capture-status-warm" "$CRLOG" 2>/dev/null && break
    sleep 1
  done
  sleep 2
  xcrun simctl terminate "$UDID" "$BUNDLE_ID" 2>/dev/null || true
  kill "$CR_PID" 2>/dev/null || true
  wait "$CR_PID" 2>/dev/null || true
  rescue_spans "$CRLOG" "$CR_START"
  CR_MS="$(grep -oE "perf-span capture-status-warm[^ ]* ms=[0-9]+" "$CRLOG" \
           | grep -oE 'ms=[0-9]+' | grep -oE '[0-9]+' | sort -n | tail -1 || true)"
  check_budget "churn-rewarm" "$CR_MS" "$CHURN_REWARM_BUDGET_MS"
fi

echo ""
if [ -n "$WARNED" ]; then
  echo "KNOWN OPEN GAPS (tracked in $BASELINE_FILE — over budget, at or under baseline):$WARNED"
fi
if [ -n "$FAILED" ]; then
  echo "FAIL — budgets breached on '$DEVICE' @ N=$N segs≈$SEGS:$FAILED"
  exit 1
fi
echo "PASS — all budgets green on '$DEVICE' @ N=$N segs≈$SEGS"
[ -n "$WARNED" ] && echo "      (with tracked known gaps above — they are debt, not a pass)"
exit 0
