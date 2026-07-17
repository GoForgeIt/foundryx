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
WARM_BUDGET_MS="${WARM_BUDGET_MS:-5000}"               # capture-status-warm, cold status cache
REWARM_BUDGET_MS="${REWARM_BUDGET_MS:-500}"            # SECOND launch: cache hit, no re-scan
# Nav budgets. tab-switch gates the WARMED lap (the UITest's first cycle builds each
# tab once; steady-state is what users feel all day — measured 34-90ms vs 150-200ms
# first-build). record-start is a RATCHET at today's truth: the 384ms is entirely
# SwiftUI fullScreenCover presentation (record-start-sync measures our begin work at
# 0ms) — the <200ms goal needs presentation pre-warm (named next target, track
# 20260717T0759). The stall ceiling is tied to the record budget because the record
# present IS the one known >250ms main-thread turn; tighten both together.
TAB_BUDGET_MS="${TAB_BUDGET_MS:-100}"                  # nav phase: tab-switch (warmed lap)
RECORD_BUDGET_MS="${RECORD_BUDGET_MS:-450}"            # nav phase: record-start (goal: 200)
STALL_CEILING_MS="${STALL_CEILING_MS:-450}"            # nav phase: no stall above this
NAV="${NAV:-1}"               # NAV=0 skips the UITest-driven nav-budget phase
BUNDLE_ID="com.goforgeit.foundryx"
DD="build/sim-perf-dd"        # dedicated DerivedData so the .app path is predictable

echo "==> sim-perf: device='$DEVICE'  N=$N  segs≈$SEGS  budgets: hydrate<${HYDRATE_BUDGET_MS} first-paint<${FIRSTPAINT_BUDGET_MS} warm<${WARM_BUDGET_MS} tab<${TAB_BUDGET_MS} record<${RECORD_BUDGET_MS}"

# 1. Resolve (create if absent) the simulator UDID for this device type.
UDID="$(xcrun simctl list devices available | grep -F "$DEVICE (" | head -1 \
        | grep -oE '[0-9A-F-]{36}' | head -1 || true)"
if [ -z "$UDID" ]; then
  echo "==> creating simulator '$DEVICE'"
  RUNTIME="$(xcrun simctl list runtimes | grep -oE 'com.apple.CoreSimulator.SimRuntime.iOS[^ ]*' | tail -1)"
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
if [ ! -d "$APP" ]; then
  echo "==> building FoundryX (Debug, simulator) into $DD"
  xcodegen generate >/dev/null
  xcodebuild build -project FoundryX.xcodeproj -scheme FoundryX -configuration PerfRelease \
    -destination "id=$UDID" -derivedDataPath "$DD" CODE_SIGNING_ALLOWED=NO >/dev/null
fi
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
  xcrun simctl spawn "$UDID" log show --start "$2" --style compact \
      --predicate 'eventMessage CONTAINS "perf-span"' 2>/dev/null \
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
check_budget() {   # label value budget  (empty value = missing span → fail)
  local label="$1" value="$2" budget="$3"
  if [ -z "$value" ]; then
    echo "  $label : (no span captured — see $LOG)"
    FAILED="$FAILED $label(missing)"
    return
  fi
  echo "  $label : ${value}ms  (budget ${budget}ms)"
  if [ "$value" -gt "$budget" ]; then FAILED="$FAILED $label(${value}>${budget})"; fi
}

echo ""
check_budget "hydrate    " "$HYDRATE_MS"    "$HYDRATE_BUDGET_MS"
check_budget "first-paint" "$FIRSTPAINT_MS" "$FIRSTPAINT_BUDGET_MS"
check_budget "status-warm" "$WARM_MS"       "$WARM_BUDGET_MS"
check_budget "re-warm    " "$REWARM_MS"     "$REWARM_BUDGET_MS"

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
      -only-testing:FoundryXUITests/PerfBudgetNavUITests \
      CODE_SIGNING_ALLOWED=NO >"$NAVLOG" 2>&1; then
    echo "FAIL — nav drive itself failed (see $NAVLOG)"
    exit 1
  fi
  SPANS="$(xcrun simctl spawn "$UDID" log show --start "$NAV_START" --style compact \
             --predicate 'eventMessage CONTAINS "perf-span"' 2>/dev/null \
           | grep -oE "perf-span [a-z0-9-]+ ms=[0-9]+" || true)"
  span_max() { echo "$SPANS" | grep -E "^perf-span $1 " | grep -oE '[0-9]+$' | sort -n | tail -1; }
  # Warmed-lap tab switches = the LAST 4 spans chronologically (lap 2 of 2).
  TAB_MS="$(echo "$SPANS" | grep -E "^perf-span tab-switch " | grep -oE '[0-9]+$' | tail -4 | sort -n | tail -1 || true)"
  TAB_COLD_MS="$(span_max tab-switch || true)"
  RECORD_MS="$(span_max record-start || true)"
  STALLS="$(echo "$SPANS" | grep -E "^perf-span nav-stall " | grep -oE '[0-9]+$' \
            | awk -v c="$STALL_CEILING_MS" '$1 > c' | wc -l | tr -d ' ')"
  echo ""
  check_budget "tab-switch " "$TAB_MS"    "$TAB_BUDGET_MS"
  [ -n "$TAB_COLD_MS" ] && echo "  tab-cold    : ${TAB_COLD_MS}ms  (first-build, informational)"
  check_budget "record-st  " "$RECORD_MS" "$RECORD_BUDGET_MS"
  echo "  nav-stalls  : ${STALLS:-0} over ${STALL_CEILING_MS}ms  (budget: 0)"
  if [ "${STALLS:-0}" -gt 0 ]; then
    echo "$SPANS" | grep -E "^perf-span nav-stall " || true
    FAILED="$FAILED nav-stall(${STALLS})"
  fi
fi

echo ""
if [ -n "$FAILED" ]; then
  echo "FAIL — budgets breached on '$DEVICE' @ N=$N segs≈$SEGS:$FAILED"
  exit 1
fi
echo "PASS — all budgets green on '$DEVICE' @ N=$N segs≈$SEGS"
