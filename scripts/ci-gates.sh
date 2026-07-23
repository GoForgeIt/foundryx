#!/usr/bin/env bash
# ci-gates.sh — the permanent, non-regressable gates for FoundryX.
#
# WHY THIS FILE EXISTS
# --------------------
# Two things shipped through a green test run in the same week:
#
#   1. A 6.6-second main-thread freeze at ~175 conversations. Every perf gate measured only
#      the QUERY side (list rebuild / warm reads) of a STATIC, pre-warmed library. The
#      CQRS-invariant suites (`HangReproTests`, `RebuildBytesIndependenceTests`,
#      `ResidualMainActorWorkTests`) now encode the properties that pathology violates —
#      exact, machine-independent DECODE COUNTS, not flaky millisecond budgets.
#
#   2. `main` was UNBUILDABLE FOR iOS while 960 tests were green: a `MainTabs` call was
#      missing two arguments and the compiler misreported it as "unable to type-check this
#      expression in reasonable time" 90 lines away. `swift test` compiles only the SPM
#      package — it cannot see `App/` at all. A total shipping outage that cost nothing to
#      catch, if anyone had asked the app target to compile.
#
# Phases (all run by default; each can be run alone):
#
#   swift      package unit + Brine suite, incl. the three CQRS-invariant gate suites
#   gates      the CQRS-invariant suites ALONE, with proof they actually executed
#   compile    the iOS APP target Debug AND Release, plus build-for-testing so the TEST
#              targets (Tests/ and UITests/) compile too  ← would have caught (2)
#   leak       the Release binary carries NO harness seam — proven by a NEGATIVE CONTROL
#              against PerfRelease, which is known to contain every seam
#   flake      order/load-dependence probe (see the honest note in `phase_flake`)
#   lint       process-global test-state polluters
#
# EVERY PHASE MUST BE ABLE TO FAIL, and an unknown phase name is a hard error (exit 2) —
# not, as it once was, a silent zero-work "CI GATES PASS".
#
# WHERE THIS RUNS: the Concourse `foundryx-ios-publish` pipeline's `test` job invokes this
# script (foundry repo, ci/foundryx-ios-publish.yml), and `fastlane gates` / `fastlane beta`
# are the local entrypoints.
#
# Usage:
#   scripts/ci-gates.sh                 # everything
#   scripts/ci-gates.sh compile leak    # just those phases
set -uo pipefail
cd "$(dirname "$0")/.."

VALID_PHASES=(swift gates compile leak flake lint uiproof)
PHASES=("$@")
[ ${#PHASES[@]} -eq 0 ] && PHASES=("${VALID_PHASES[@]}")
DD="${CI_GATES_DD:-build/ci-gates-dd}"
FAILED=""
have() { for p in "${PHASES[@]}"; do [ "$p" = "$1" ] && return 0; done; return 1; }
fail() { echo "GATE FAIL — $1"; FAILED="$FAILED $1"; }

# ---------------------------------------------------------------- B1: unknown phase = ERROR
# An unrecognised phase name used to be a SILENT FULL PASS: the dispatch loop at the bottom
# iterates the KNOWN phases and asks `have` about each, so `ci-gates.sh complie` matched
# nothing, ran zero work and printed "CI GATES PASS" with rc=0. A typo, a rename, or a
# capitalisation drift in a CI invocation therefore became a permanent green. Argument
# validation is now the first thing this script does, and it exits NON-ZERO.
UNKNOWN=""
for p in "${PHASES[@]}"; do
  known=0
  for v in "${VALID_PHASES[@]}"; do [ "$p" = "$v" ] && known=1; done
  [ $known -eq 1 ] || UNKNOWN="$UNKNOWN $p"
done
if [ -n "$UNKNOWN" ]; then
  echo "ci-gates: UNKNOWN PHASE(S):$UNKNOWN"
  echo "ci-gates: valid phases: ${VALID_PHASES[*]}"
  echo "ci-gates: (phase names are case-sensitive; no arguments runs all of them)"
  exit 2
fi
if [ ${#PHASES[@]} -eq 0 ]; then
  echo "ci-gates: EMPTY PHASE LIST — refusing to report a pass for zero work"
  echo "ci-gates: valid phases: ${VALID_PHASES[*]}"
  exit 2
fi
# Counted by the dispatch loop; a run that executed nothing must never print PASS.
RAN=0

# The three suites that encode the CQRS invariants this wave established. Named explicitly so
# that deleting or renaming one is a LOUD failure ("no tests executed") rather than a silent
# reduction in coverage.
GATE_SUITES=(HangReproTests RebuildBytesIndependenceTests ResidualMainActorWorkTests)

# ---------------------------------------------------------------- swift: the whole package
phase_swift() {
  echo "==> [swift] swift test (full package)"
  local out; out="build/ci-gates-swift.log"
  mkdir -p build
  if ! swift test >"$out" 2>&1; then
    tail -40 "$out"
    fail "swift-test"
  fi
  grep -E "^\s+Executed [0-9]+ tests" "$out" | tail -1 || true
}

# ---------------------------------------------- gates: the CQRS invariants, proven to run
# The point of running them AGAIN in isolation is the executed-count assertion: a gate suite
# that silently stops existing (deleted file, renamed class, `swift test` filter drift) is
# indistinguishable from a green run unless somebody counts.
phase_gates() {
  echo "==> [gates] CQRS-invariant suites (decode-count properties)"
  local filter; filter="$(IFS='|'; echo "${GATE_SUITES[*]}")"
  local out; out="build/ci-gates-invariants.log"
  mkdir -p build
  if ! swift test --filter "($filter)" >"$out" 2>&1; then
    tail -60 "$out"
    fail "cqrs-invariant-suites"
  fi
  # Every named suite must have actually run — AND the two ways it can not-pass are different
  # facts that deserve different names (N3). The old code printed `gate-suite-missing(X)` when
  # the suite RAN AND FAILED, which is the single most important failure this script can
  # report and it was labelled as if the file had been deleted.
  for s in "${GATE_SUITES[@]}"; do
    if grep -q "Test Suite '$s' passed" "$out"; then continue; fi
    if grep -q "Test Suite '$s' failed" "$out"; then
      grep -E "^Test Case '-\[$s .*' failed" "$out" | head -10
      fail "gate-suite-FAILED($s)"
    elif grep -q "Test Suite '$s' started" "$out"; then
      fail "gate-suite-did-not-finish($s)"
    else
      fail "gate-suite-missing($s)"
    fi
  done
  # LAST line = the run total (the earlier ones are per-suite subtotals).
  local n; n="$(grep -oE "Executed [0-9]+ tests" "$out" | tail -1 | grep -oE '[0-9]+' || echo 0)"
  echo "  invariant tests executed: ${n:-0}"
  [ "${n:-0}" -lt 8 ] && fail "gate-suites-too-few-tests(${n:-0})"
}

# -------------------------------------------------- compile: the APP TARGET, Debug + Release
# `swift test` cannot see App/. This is the gate that would have caught the unbuildable main.
# Release matters independently: the DEBUG-gated harness seams (-SyntheticMic, -BrainSetupFailed,
# -StressSeed, -StressChurn) are `#if DEBUG`-conditioned, so Release compiles DIFFERENT code —
# a Debug-only build gate cannot prove the shipping configuration even parses.

# Which configurations this invocation has actually (re)built. The leak phase consults this
# so that `ci-gates.sh leak` run ALONE cannot validate a stale `.app` left on disk by a build
# of some other commit (S10) — it builds what it needs itself.
BUILT_CFGS=""
built() { case " $BUILT_CFGS " in *" $1 "*) return 0;; *) return 1;; esac; }

# One place that knows how to build the app target for a configuration. Returns non-zero and
# prints the compiler errors on failure; records success in BUILT_CFGS.
build_cfg() {
  local cfg="$1"
  local out; out="build/ci-gates-compile-$cfg.log"
  mkdir -p build
  command -v xcodegen >/dev/null || { fail "compile(xcodegen-missing)"; return 1; }
  xcodegen generate >/dev/null 2>&1 || { fail "compile(xcodegen-failed)"; return 1; }
  if xcodebuild build -project FoundryX.xcodeproj -scheme FoundryX -configuration "$cfg" \
      -destination 'generic/platform=iOS Simulator' -derivedDataPath "$DD" \
      CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO >"$out" 2>&1; then
    BUILT_CFGS="$BUILT_CFGS $cfg"
    return 0
  fi
  grep -aE "error:" "$out" | head -20
  return 1
}

phase_compile() {
  for cfg in Debug Release; do
    echo "==> [compile] iOS app target — $cfg"
    if build_cfg "$cfg"; then echo "  $cfg: BUILD SUCCEEDED"; else fail "app-compile($cfg)"; fi
  done
  # S2 — `build` on the FoundryX scheme compiles the APP ONLY. A syntax error in a TEST
  # target (`UITests/PerfBudgetNavUITests.swift`, `Tests/…`) was caught by nothing here: the
  # UITest sources are compiled only by the perf harness, which nobody runs per-commit. Given
  # this gate exists BECAUSE main shipped unbuildable, the test targets get the same treatment.
  # FoundryX/test → FoundryXiOSTests; FoundryXUIProof/test → FoundryXUITests.
  for pair in "FoundryX:iOS-test-target" "FoundryXUIProof:UITest-target"; do
    local scheme; scheme="${pair%%:*}"
    local what;   what="${pair##*:}"
    echo "==> [compile] build-for-testing — $scheme ($what)"
    local out; out="build/ci-gates-compile-fortest-$scheme.log"
    if xcodebuild build-for-testing -project FoundryX.xcodeproj -scheme "$scheme" \
        -configuration Debug -destination 'generic/platform=iOS Simulator' \
        -derivedDataPath "$DD" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
        >"$out" 2>&1; then
      echo "  $scheme: BUILD-FOR-TESTING SUCCEEDED"
    else
      grep -aE "error:" "$out" | head -20
      fail "test-target-compile($scheme)"
    fi
  done
}

# ------------------------------------------ leak: no DEBUG-only harness seam in the Release app
#
# WHY THE MECHANISM CHANGED (adversarial review B2).
# -------------------------------------------------
# The first version of this gate scanned `strings -a` for the harness LAUNCH-ARGUMENT literals.
# It could not fail for most of them. Swift's small-string optimisation stores any literal of
# ≤15 UTF-8 bytes INLINE in the instruction stream (two immediates, not contiguous ASCII), so
# `strings` never sees it. Measured against a PerfRelease binary that PROVABLY compiles those
# seams in: `-StressSeed` 0 hits, `-StressSegs` 0, `-MainPreview` 0. The three that did hit
# (`-StressChurn`, `-SyntheticMic`, `-StallDemo`) hit only because unrelated LONG `NSLog`
# format strings happen to quote the flag text — reword one log line and the detection goes
# vacuous. The "positive control" (`capture-hydrate`) was itself a ≤15-byte small string that
# matched only as a prefix of the longer `capture-hydrate-n…`, so all it proved was that the
# gate can read LONG literals: precisely the class the banned tokens are NOT in.
#
# THE REPLACEMENT — three independent detections, each with a control that can fail:
#
#   1. SYMBOLS (`nm -a`), with a NEGATIVE CONTROL. Harness-only TYPES (DemoSeed, StressChurn,
#      SyntheticMicFrameSource, BenchModel) leave dozens of symbols in a binary that compiles
#      them. The identical detection is run first against the PerfRelease binary — which is
#      KNOWN to contain every seam — and every seam MUST be found there. If the control comes
#      up empty the gate declares ITSELF broken and fails; it never prints "clean" on a
#      detection it has not just proven works. (Measured: PerfRelease 36/61/80/23 symbol hits
#      for the four seams; Release 0/0/0/0.)
#
#   2. SOURCE GATING. `nm` cannot see a harness REGION inside a production type (the
#      `-MainPreview` branch in RootView is not its own symbol). So every read of a banned
#      launch-argument literal anywhere in App/ Sources/ Widget/ must sit inside a
#      `#if DEBUG` / `#if DEBUG || PERF_HARNESS` region — checked by tracking the
#      conditional-compilation nesting, including `#else` (the NOT-debug branch).
#
#   3. BUILD CONFIGURATION. The shipping configuration must not define the flags that would
#      re-enable every one of those regions. Read back from `xcodebuild -showBuildSettings`,
#      not from project.yml, so an override anywhere in the chain is caught.
#
# S10: `leak` run ALONE used to validate whatever stale `.app` happened to be on disk. It now
# builds what it inspects.
LEAK_SEAM_TYPES=(DemoSeed StressChurn SyntheticMicFrameSource BenchModel)
# NB: `-PerfLog` is deliberately NOT on this list — PerfMetricsSubscriber reads it in
# PRODUCTION code (it suppresses the launch-cost window when the harness owns the sensor),
# so its presence in Release is correct, not a leak.
LEAK_SEAM_ARGS=(-SyntheticMic -BrainSetupFailed -StressSeed -StressSegs -StressChurn -StallDemo -MainPreview
                -WelcomePreview -Screen -RemoteChat -SyntheticOmi)
# -WelcomePreview / -Screen / -RemoteChat were found SHIPPING IN RELEASE alongside -MainPreview.
# They are listed here, not merely fixed at the call site, because fixing an instance without
# policing the class is how the first one survived: a seam nobody is checking for is a seam that
# comes back. If a new dev harness needs a launch argument, it belongs on this list on day one.

# Count symbols naming a seam type in a Mach-O.
leak_symcount() { nm -a "$1" 2>/dev/null | grep -cF "$2" || true; }

# Every non-comment source line that reads "<arg>" OUTSIDE a DEBUG/PERF_HARNESS region.
# Tracks #if/#elseif/#else/#endif nesting: an `#else` arm of a DEBUG conditional is the
# SHIPPING arm, so it does NOT count as gated.
leak_ungated_reads() {
  local arg="$1"; shift
  awk -v arg="\"$arg\"" '
    function gated(   i) { for (i = 1; i <= depth; i++) if (cond[i]) return 1; return 0 }
    /^[[:space:]]*#if/    { depth++; cond[depth] = ($0 ~ /DEBUG|PERF_HARNESS/) ? 1 : 0; next }
    /^[[:space:]]*#elseif/ { if (depth > 0) cond[depth] = ($0 ~ /DEBUG|PERF_HARNESS/) ? 1 : 0; next }
    /^[[:space:]]*#else/  { if (depth > 0) cond[depth] = 0; next }
    /^[[:space:]]*#endif/ { if (depth > 0) depth--; next }
    /^[[:space:]]*\/\// { next }
    index($0, arg) > 0 && !gated() { printf "%s:%d\n", FILENAME, FNR }
  ' "$@"
}

phase_leak() {
  mkdir -p build
  local rel; rel="$DD/Build/Products/Release-iphonesimulator/FoundryX.app/FoundryX"
  local perf; perf="$DD/Build/Products/PerfRelease-iphonesimulator/FoundryX.app/FoundryX"

  # ---- S10: inspect a binary THIS run produced, never a stale one on disk.
  if ! built Release; then
    echo "==> [leak] building Release (fresh — a stale .app proves nothing)"
    build_cfg Release || { fail "release-leak(release-build-failed)"; return; }
  fi
  echo "==> [leak] building PerfRelease (the NEGATIVE CONTROL binary)"
  build_cfg PerfRelease || { fail "release-leak(perfrelease-build-failed)"; return; }
  [ -f "$rel" ]  || { fail "release-leak(no-release-binary)"; return; }
  [ -f "$perf" ] || { fail "release-leak(no-perfrelease-binary)"; return; }

  # ---- 1a. NEGATIVE CONTROL: the detection must FIND every seam in the binary that has them.
  echo "==> [leak] negative control — the same scan must find every seam in PerfRelease"
  local blind=""
  local sym
  for sym in "${LEAK_SEAM_TYPES[@]}"; do
    local n; n="$(leak_symcount "$perf" "$sym")"
    echo "    control $sym: $n symbol(s) in PerfRelease"
    [ "${n:-0}" -gt 0 ] || blind="$blind $sym"
  done
  if [ -n "$blind" ]; then
    echo "  THE LEAK GATE IS BLIND to:$blind — it cannot see these seams even in a binary"
    echo "  that provably contains them, so a 'clean' Release verdict would be meaningless."
    fail "leak-gate-broken(control-blind:$blind)"
    return
  fi

  # ---- 1b. The actual assertion.
  echo "==> [leak] Release binary carries no harness seam"
  local leaked=""
  for sym in "${LEAK_SEAM_TYPES[@]}"; do
    local n; n="$(leak_symcount "$rel" "$sym")"
    [ "${n:-0}" -eq 0 ] || { echo "    LEAKED $sym: $n symbol(s) in Release"; leaked="$leaked $sym"; }
  done
  [ -n "$leaked" ] && fail "release-leak(symbols:$leaked)"

  # ---- 2. SOURCE GATING of the launch-argument seams.
  echo "==> [leak] every harness launch-argument read is #if-gated"
  local ungated=""
  local a
  local srcs; srcs="$(find App Sources Widget -name '*.swift' 2>/dev/null | sort)"
  for a in "${LEAK_SEAM_ARGS[@]}"; do
    local hits; hits="$(leak_ungated_reads "$a" $srcs)"
    if [ -n "$hits" ]; then
      echo "    UNGATED $a:"
      echo "$hits" | sed 's/^/      /'
      ungated="$ungated $a"
    fi
  done
  [ -n "$ungated" ] && fail "release-leak(ungated-source:$ungated)"

  # ---- 3. The shipping configuration must not define the flags.
  echo "==> [leak] Release build settings define no harness compilation condition"
  local conds; conds="$(xcodebuild -project FoundryX.xcodeproj -target FoundryX \
      -configuration Release -showBuildSettings 2>/dev/null \
      | grep -E '^\s*SWIFT_ACTIVE_COMPILATION_CONDITIONS' | head -1 | cut -d= -f2- | tr -d ' ')"
  echo "    Release SWIFT_ACTIVE_COMPILATION_CONDITIONS='${conds}'"
  case " $conds " in
    *DEBUG*|*PERF_HARNESS*) fail "release-leak(release-defines-harness-condition:$conds)" ;;
  esac

  case "$FAILED" in *release-leak*) ;; *) echo "  clean (symbols + source gating + build config)";; esac
}

# ----------------------------------------------------------------- flake: order/load probe
# HONEST NOTE ON WHAT THIS CAN AND CANNOT DO.
#
# Four order/load-dependent tests were found in this wave; every one passed alone and failed
# under real conditions. Both root patterns were "waiting on a signal ADJACENT to the one the
# code reads" — `hydration complete` != `memos warm`, `snapshot() fresh` != `@Published status`.
#
# XCTest under SwiftPM has NO randomized execution ordering (that facility exists only in an
# Xcode .xctestplan, which needs a simulator run — far too slow for a per-commit gate). So this
# phase does the two cheapest things that actually surface the class:
#
#   (a) run the suite a SECOND time under heavy CPU load — the load-dependent half of the
#       class (a test that waits on a timer/hop instead of the signal) goes red under
#       contention and stays green on an idle laptop;
#   (b) run each known process-global-state-touching suite ALONE and then LAST, so a suite
#       that only passes because an alphabetically-earlier suite left the right global value
#       behind is caught.
#
# It does NOT achieve true random ordering. That is stated here rather than implied away.
phase_flake() {
  echo "==> [flake] second full run under CPU load"
  mkdir -p build
  local ncpu; ncpu="$(sysctl -n hw.ncpu)"
  local pids=()
  local i
  for ((i=0; i<ncpu; i++)); do ( while :; do :; done ) & pids+=($!); done
  swift test >build/ci-gates-flake-load.log 2>&1
  local rc=$?
  for p in "${pids[@]}"; do kill "$p" 2>/dev/null || true; done
  wait 2>/dev/null || true
  if [ $rc -ne 0 ]; then
    # Name the TESTS, not the log noise: the first version of this printed twenty lines of
    # unrelated `CoreData: error: Failed to create NSXPCConnection` and never said which test
    # went red.
    grep -E "^Test Case '.*' failed" build/ci-gates-flake-load.log | head -10
    grep -E ": error: -\[" build/ci-gates-flake-load.log | head -10
    fail "flake-under-load"
  else
    echo "  green under ${ncpu}-way CPU load"
  fi

  echo "==> [flake] process-global-state suites run in isolation"
  for s in CapturePersistenceTests SpeechGatedCaptureTests CaptureLiveActivityFeatureTests \
           CaptureAmbientTests RecordingSessionClockTests CaptureLiveActivityTests \
           MainThreadStallWatchdogTests; do
    if ! swift test --filter "$s" >"build/ci-gates-flake-$s.log" 2>&1; then
      grep -E "error:|failed" "build/ci-gates-flake-$s.log" | head -10
      fail "flake-isolated($s)"
    fi
  done
  echo "  each isolated suite green"
}

# ------------------------------------------------- lint: process-global test-state polluters
# `CaptureSettings` is UserDefaults-backed, i.e. PROCESS-GLOBAL across the whole test binary,
# and 20+ suites construct a `CaptureManager` whose `init` READS it. One polluter can flip the
# initial state of every later suite. The fix is at the SOURCE: any suite that mutates it
# inherits `ProcessGlobalStateTestCase`, which snapshots and restores it around every test.
#
# WHY THE MATCHER CHANGED (review S1 + N1 + N2).
# ---------------------------------------------
# The first version matched two hand-listed SYNTAX forms — `.pause()` and a direct
# `CaptureSettings.x =`. It therefore missed the two most common polluting call sites,
# `CaptureManager.setSilenceGap` (CaptureManager.swift:2489) and `resume()` (:3722), which
# both persist to UserDefaults. NINE suites were evading it, including
# `ResidualMainActorWorkTests` — one of the three PROTECTED gate suites — which left
# `silenceGapSeconds = 9999` persisted for every suite that ran after it. It also fired on
# `dog.pause()` (a MainThreadStallWatchdog, not a CaptureManager), which is why
# `MainThreadStallWatchdogTests` was made to inherit a base class it has no need for.
#
# The matcher is now derived from the PRODUCTION WRITERS, not from a syntax list:
#
#   1. Scan Sources/ for every function whose body assigns a `CaptureSettings.*` key. That IS
#      the writer set, by construction — adding a fifth writer tomorrow extends the lint with
#      no edit here. An EMPTY derived set is itself a failure (a rename must not silently
#      disarm the lint).
#   2. In each test file, resolve which identifiers are CaptureManager-typed (bound from
#      `CaptureManager(…)`/`makeManager(…)`, or declared `: CaptureManager`), and flag calls to
#      a derived writer ON ONE OF THOSE. `cont.resume()` on a CheckedContinuation and
#      `dog.pause()` on a watchdog are correctly ignored — they are not writers of this state.
#   3. N2: the exemption now requires a real inheritance declaration
#      (`class X: ProcessGlobalStateTestCase`). A file that merely MENTIONS the name in a
#      comment used to satisfy `grep -q`.
phase_lint() {
  echo "==> [lint] process-global capture-settings polluters"

  # 1. Derive the production writer set from the source of truth.
  local writers
  writers="$(awk '
    /^[ \t]*(public |private |internal |fileprivate |open )*(static |class )?func [A-Za-z_]/ {
      if (match($0, /func [A-Za-z_][A-Za-z0-9_]*/)) cur = substr($0, RSTART + 5, RLENGTH - 5)
    }
    /CaptureSettings\.[A-Za-z]+[ \t]*=[^=]/ { if (cur != "") print cur }
  ' Sources/FoundryXKit/*.swift | sort -u)"
  if [ -z "$writers" ]; then
    echo "  found NO production writer of CaptureSettings — the lint has nothing to match on,"
    echo "  which means it can no longer fail. Treating that as a gate defect."
    fail "lint-broken(no-derived-writers)"
    return
  fi
  local wpat; wpat="$(echo "$writers" | tr '\n' '|' | sed 's/|$//')"
  echo "  production writers of process-global CaptureSettings: $(echo "$writers" | tr '\n' ' ')"

  # 2. Flag test files that call one of those on a CaptureManager, or assign the settings.
  local hits; hits="$(awk -v WRITERS="$wpat" '
    BEGIN { n = split(WRITERS, w, "|"); for (i = 1; i <= n; i++) isWriter[w[i]] = 1 }
    FNR == 1 { delete isMgr }
    # (a) bound from a CaptureManager-producing expression
    match($0, /(let|var)[ \t]+[A-Za-z_][A-Za-z0-9_]*[ \t]*(:[ \t]*[A-Za-z_][A-Za-z0-9_]*[?!]?)?[ \t]*=/) {
      head = substr($0, RSTART, RLENGTH); rest = substr($0, RSTART + RLENGTH)
      if (rest ~ /CaptureManager\(/ || rest ~ /[Mm]akeManager\(/ || rest ~ /(await[ \t]+)?[A-Za-z_.]*manager\(/) {
        split(head, p, /[ \t]+/); name = p[2]; sub(/[ \t]*[:=].*/, "", name); isMgr[name] = 1
      }
    }
    # (b) declared `: CaptureManager`, with or without an initialiser
    match($0, /(let|var)[ \t]+[A-Za-z_][A-Za-z0-9_]*[ \t]*:[ \t]*CaptureManager[?!]?/) {
      d = substr($0, RSTART, RLENGTH); split(d, p, /[ \t]+/); name = p[2]
      sub(/[ \t]*:.*/, "", name); isMgr[name] = 1
    }
    {
      line = $0; sub(/\/\/.*/, "", line)
      if (line ~ /CaptureSettings\.[A-Za-z]+[ \t]*=[^=]/) print FILENAME ":" FNR ": CaptureSettings assigned directly"
      while (match(line, /[A-Za-z_][A-Za-z0-9_]*\.[A-Za-z_][A-Za-z0-9_]*\(/)) {
        call = substr(line, RSTART, RLENGTH); line = substr(line, RSTART + RLENGTH)
        split(call, cp, "."); recv = cp[1]; meth = cp[2]; sub(/\($/, "", meth)
        if (isMgr[recv] && isWriter[meth]) print FILENAME ":" FNR ": " recv "." meth "() persists CaptureSettings"
      }
    }
  ' Tests/FoundryXBrineTests/*.swift)"

  local bad=""
  local f
  for f in $(echo "$hits" | cut -d: -f1 | sort -u); do
    [ -n "$f" ] || continue
    # ProcessGlobalStateTestCase.swift IS the fix; it legitimately touches the settings.
    [ "$(basename "$f")" = "ProcessGlobalStateTestCase.swift" ] && continue
    # N2: a real inheritance declaration, not a passing mention in a comment.
    grep -qE 'class[ \t]+[A-Za-z0-9_]+[ \t]*:[ \t]*ProcessGlobalStateTestCase' "$f" || bad="$bad $(basename "$f")"
  done
  if [ -n "$bad" ]; then
    echo "  suites mutate process-global CaptureSettings without inheriting"
    echo "  ProcessGlobalStateTestCase (which restores it in tearDown):$bad"
    echo "$hits" | grep -E "^($(echo "$bad" | tr ' ' '\n' | grep . | sed 's|^|Tests/FoundryXBrineTests/|' | tr '\n' '|' | sed 's/|$//'))" | sed 's/^/    /'
    fail "process-global-polluter($bad)"
  else
    echo "  clean — every writer call site is inside a ProcessGlobalStateTestCase subclass"
  fi
}

# ---------------------------------------------------------------- uiproof: the recording SURFACE, on a simulator
# The layer the logic suite CANNOT see: the actual SwiftUI render + navigation of the
# capture surface, driven through the REAL pipeline. RecordingProof exercises the phone-mic
# Record button; AmbientRecordingProof exercises the OMI AMBIENT path — a speech onset opens
# a conversation with no button tap, the "Listening" hero tile carries it, and TAPPING that
# tile opens the recording page. That ambient flow shipped BROKEN and green on 2026-07-23
# because nothing rendered it; this phase is the guard so it can't recur. -SyntheticMic /
# -SyntheticOmi feed real Opus packets through the whole pipeline, so only the radio is
# stood in for. A missing simulator is a LOUD failure, never a silent skip.
phase_uiproof() {
  echo "==> [uiproof] recording-surface UI E2E on a simulator (phone-mic + Omi ambient)"
  local udid
  udid=$(xcrun simctl list devices available 2>/dev/null | grep -E "iPhone" | grep -Eo "[0-9A-F-]{36}" | head -1)
  if [ -z "$udid" ]; then
    echo "  no available iPhone simulator runtime — the capture-surface E2E cannot run"
    fail "uiproof-no-simulator"
    return
  fi
  xcrun simctl boot "$udid" >/dev/null 2>&1 || true
  local out="build/ci-gates-uiproof.log"
  mkdir -p build
  if xcodebuild test -project FoundryX.xcodeproj -scheme FoundryXUIProof \
       -configuration Debug -destination "platform=iOS Simulator,id=$udid" \
       -derivedDataPath "$DD" \
       -only-testing:FoundryXUITests/RecordingProofUITests/testPhoneMicRecordingTimerAndSurface \
       -only-testing:FoundryXUITests/AmbientRecordingProofUITests/testAmbientSpeechOpensATappableRecordingConversation \
       >"$out" 2>&1; then
    echo "  uiproof: recording surface (phone-mic + Omi ambient tap-through) PASSED"
  else
    tail -50 "$out"
    fail "uiproof-recording-surface"
  fi
}

for p in "${VALID_PHASES[@]}"; do have "$p" && { RAN=$((RAN + 1)); "phase_$p"; }; done

echo ""
if [ "$RAN" -eq 0 ]; then
  echo "ci-gates: RESOLVED PHASE LIST RAN NOTHING — this is a gate bug, not a pass"
  exit 2
fi
echo "ci-gates: phases executed: $RAN"
if [ -n "$FAILED" ]; then
  echo "CI GATES FAILED:$FAILED"
  exit 1
fi
echo "CI GATES PASS"
