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
HYDRATE_BUDGET_MS="${HYDRATE_BUDGET_MS:-800}"
BUNDLE_ID="com.goforgeit.foundryx"
DD="build/sim-perf-dd"        # dedicated DerivedData so the .app path is predictable

echo "==> sim-perf: device='$DEVICE'  N=$N  hydrate-budget=${HYDRATE_BUDGET_MS}ms"

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
APP="$DD/Build/Products/Debug-iphonesimulator/FoundryX.app"
if [ ! -d "$APP" ]; then
  echo "==> building FoundryX (Debug, simulator) into $DD"
  xcodegen generate >/dev/null
  xcodebuild build -project FoundryX.xcodeproj -scheme FoundryX -configuration Debug \
    -destination "id=$UDID" -derivedDataPath "$DD" CODE_SIGNING_ALLOWED=NO >/dev/null
fi
[ -d "$APP" ] || { echo "build produced no .app at $APP"; exit 2; }

# 3. Fresh install (uninstall first so the seeded library is the ONLY content).
xcrun simctl uninstall "$UDID" "$BUNDLE_ID" 2>/dev/null || true
xcrun simctl install "$UDID" "$APP"

# 4. Launch with the stress seed + perf-log mirror; capture the console.
LOG="build/sim-perf-$(echo "$DEVICE" | tr ' ()' '___')-N$N.log"
echo "==> launching (stress-seed $N) — console → $LOG"
# --console-pty streams the app's stdout/NSLog until it exits or we time out.
( xcrun simctl launch --console-pty "$UDID" "$BUNDLE_ID" \
    -StressSeed "$N" -MainPreview -PerfLog >"$LOG" 2>&1 ) &
LAUNCH_PID=$!
# Give hydration time to run + emit, then stop the app.
sleep 20
xcrun simctl terminate "$UDID" "$BUNDLE_ID" 2>/dev/null || true
kill "$LAUNCH_PID" 2>/dev/null || true
wait "$LAUNCH_PID" 2>/dev/null || true

# 5. Pull the perf spans back out and check the budget.
echo ""
echo "==> perf spans (device='$DEVICE', N=$N):"
grep -oE "perf-span [a-z0-9-]+ ms=[0-9]+" "$LOG" | sort -u || true

HYDRATE_MS="$(grep -oE "perf-span capture-hydrate[^ ]* ms=[0-9]+" "$LOG" \
              | grep -oE 'ms=[0-9]+' | grep -oE '[0-9]+' | sort -n | tail -1 || true)"
FIRSTPAINT_MS="$(grep -oE "perf-span capture-list-first-paint ms=[0-9]+" "$LOG" \
                 | grep -oE 'ms=[0-9]+' | grep -oE '[0-9]+' | sort -n | tail -1 || true)"

echo ""
[ -n "$FIRSTPAINT_MS" ] && echo "  first-paint : ${FIRSTPAINT_MS}ms"
if [ -z "$HYDRATE_MS" ]; then
  echo "  hydrate     : (no span captured — did the app launch + hydrate? see $LOG)"
  exit 2
fi
echo "  hydrate     : ${HYDRATE_MS}ms  (budget ${HYDRATE_BUDGET_MS}ms)"
if [ "$HYDRATE_MS" -gt "$HYDRATE_BUDGET_MS" ]; then
  echo ""
  echo "FAIL — hydrate ${HYDRATE_MS}ms > ${HYDRATE_BUDGET_MS}ms on '$DEVICE' @ N=$N"
  exit 1
fi
echo ""
echo "PASS — hydrate within budget on '$DEVICE' @ N=$N"
