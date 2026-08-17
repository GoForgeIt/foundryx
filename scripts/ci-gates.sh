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

VALID_PHASES=(swift gates compile leak flake lint iosbrine appscenarios uiproof)
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

# The suites that encode the invariants this repository will not regress. Named explicitly so
# that deleting or renaming one is a LOUD failure ("no tests executed") rather than a silent
# reduction in coverage.
#
# ProductionReachabilityRegisterTests is the REACHABILITY GATE. The first three prove the code
# behaves; it proves the code is REACHED — that a capability the scenarios drive through an
# injected fake is actually called by something that ships. Four capabilities reached `main` in
# one day fully implemented, fully tested and called by nothing outside `Tests/`, and every
# suite was green, because "correct" and "reached" are different facts and only the first had a
# gate. It runs HERE, inside an existing phase, rather than as a new phase name: the pre-push
# hook derives its phase list from `.github/workflows/ios-publish.yml` with
# `grep -oE 'bash scripts/ci-gates\.sh [a-z ]+'`, so a phase name carrying a hyphen or a digit
# truncates and turns every push into "UNKNOWN PHASE -> exit 2".
#
# CeremonyStateExitRegisterTests is the STATE-EXIT GATE — the same question one level in. The
# register above asks whether shipping code ever CALLS a capability; this asks whether a person
# standing in a particular STATE can REACH one. Six defects had that shape — implemented, tested,
# reachable from one state and orphaned from another the user actually lands in. The two worst:
# `.handshakeUnanswered` (a recorder that answers a wrong key with SILENCE) had no exits at all,
# and `.didNotFinish` (a recorder that REFUSED the key we hold) carried "Try again" as its FIRST,
# PRIMARY button while that title fell through the routing table's `default` arm and closed the
# whole connect sheet — under a body reading "Try again before you close this."
# It runs here for the same phase-name reason recorded above.
GATE_SUITES=(HangReproTests RebuildBytesIndependenceTests ResidualMainActorWorkTests
             ProductionReachabilityRegisterTests CeremonyStateExitRegisterTests)

# ---------------------------------------------------------------- swift: the whole package
#
# SWIFT_TEST_STALL is how long a single attempt may go WITHOUT WRITING A BYTE before
# it is declared deadlocked. Progress, not duration: both observed wedges (2026-08-11
# and 2026-08-12, 3h and 6h on two different workers) sat at 0.0% CPU holding
# `$TMPDIR/<mangled-path>_.build.lock` on their OWN fd, with a byte-static log — no
# error, no output, nothing. A slow attempt (cold compile, loaded box) keeps writing.
# The previous flat SWIFT_TEST_TIMEOUT could not tell those apart and misdiagnosed a
# healthy compiling run THREE times on 2026-08-12/13 — twice in CI (one killed at
# 1187/1370 tests passing) and once locally — each time reporting "deadlocked twice"
# about a process that was demonstrably working. Duration is bounded by the caller
# (CI's job-level timeout-minutes); this knob only detects wedges.
SWIFT_TEST_STALL="${SWIFT_TEST_STALL:-300}"

# The lock SwiftPM takes for THIS workspace. The name is the absolute .build path with
# '/' turned into '_', in TMPDIR. Deriving it (rather than globbing all of TMPDIR) means
# we never delete a lock belonging to another checkout building concurrently.
# NOTE: this script cd's to the repo root at the top, so $PWD IS the root. (There is no
# REPO_ROOT variable here — using one would silently derive the wrong path and delete
# nothing, leaving the deadlock in place.)
_swift_build_lock_path() {
  printf '%s/%s_.build.lock\n' "${TMPDIR:-/tmp}" "$(printf '%s' "$PWD" | tr '/' '_')"
}

# One attempt, supervised by PROGRESS. Returns 124 only after the attempt has written
# nothing for SWIFT_TEST_STALL seconds — the deadlock's actual signature — which the
# caller distinguishes from a genuine test failure. There is deliberately NO overall
# duration bound here: a run that is still writing is still working, however slow the
# box, and killing it discards compile progress the retry then pays for again.
_swift_test_once() {
  local out="$1"
  swift test >"$out" 2>&1 & local p=$!
  local last=-1 size idle=0
  while kill -0 "$p" 2>/dev/null; do
    sleep 10
    size=$(wc -c <"$out" 2>/dev/null | tr -d ' ') || size=0
    if [ "${size:-0}" != "$last" ]; then
      last="$size"; idle=0
    else
      idle=$((idle + 10))
      if [ "$idle" -ge "$SWIFT_TEST_STALL" ]; then
        kill -TERM "$p" 2>/dev/null; sleep 20; kill -KILL "$p" 2>/dev/null
        wait "$p" 2>/dev/null
        return 124
      fi
    fi
  done
  wait "$p"
}

# Print WHICH tests failed. Without this the gate reported `tail -40`, which on a 1345-test
# run is the summary and the tail of an unrelated suite — CI recorded 21 of 1345 lines and
# never named the failing test. Finding it cost three separate investigations on 2026-08-12.
_report_swift_failures() {
  local out="$1"
  echo "--- failing tests ---"
  grep -aE "Test Case.*' failed|\.swift:[0-9]+: error:" "$out" \
    | sed 's/\x1b\[[0-9;]*m//g' | grep -viE 'warning:|note:' | head -25 || true
  echo "--- scenario-level detail (Brine/conformance runners report here) ---"
  grep -aE '^\[failed\]' "$out" | sed 's/\x1b\[[0-9;]*m//g' | head -15 || true
  echo "--- summary ---"
  grep -aE "^\s+Executed [0-9]+ tests" "$out" | tail -2 || true
  echo "(full log: $out)"
}

phase_swift() {
  echo "==> [swift] swift test (full package)"
  local out; out="build/ci-gates-swift.log"
  mkdir -p build
  local rc=0
  _swift_test_once "$out" || rc=$?

  if [ "$rc" -eq 124 ]; then
    # SELF-HEAL, ONCE. 124 now means the attempt wrote NOTHING for SWIFT_TEST_STALL
    # seconds — the workspace-lock deadlock's real signature, not mere slowness.
    # Clear only THIS workspace's lock, then retry. The heal used to also
    # `pkill swift-*` MACHINE-WIDE (murdering concurrent jobs' builds) and
    # `rm -rf .build` (forcing the retry to recompile cold, which is how a retry
    # got SLOWER than the attempt it replaced). The supervisor already killed our
    # own process tree; the lock file is the only wedge left to clear.
    local lock; lock="$(_swift_build_lock_path)"
    echo "    swift test wrote nothing for ${SWIFT_TEST_STALL}s — the SwiftPM workspace-lock deadlock."
    echo "    clearing this workspace's lock and retrying ONCE: $lock"
    rm -f "$lock" 2>/dev/null || true
    rc=0
    _swift_test_once "$out" || rc=$?
    if [ "$rc" -eq 124 ]; then
      echo "    STILL deadlocked after clearing the lock — not retrying again."
      _report_swift_failures "$out"
      # `fail` RECORDS a failure and returns; it does not exit. Without this return the
      # function fell through and reported swift-test failed TWICE, with a misleading
      # "retry completed" line printed after it had already given up. (Caught by running
      # this path with a forced stall before trusting it.)
      fail "swift-test (deadlocked twice on the SwiftPM workspace lock)"
      return 1
    fi
    echo "    retry completed after the lock was cleared."
  fi

  if [ "$rc" -ne 0 ]; then
    _report_swift_failures "$out"
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
  # DID THE BUILD FAIL, OR WAS IT NEVER RUN? xcodebuild refuses to start when another
  # build holds this derivedData's build.db ("unable to attach DB ... database is locked")
  # and reports that refusal through the same non-zero exit as a genuine compile error.
  # On 2026-08-13 two xcodebuild processes orphaned by cancelled CI runs (5h and 1h42m old,
  # both reparented to launchd) held the lock, and this gate reported FIVE compile failures
  # against a tree that builds clean — blocking a push on a red it had manufactured. A gate
  # must be able to say "I could not run" rather than "your code is broken"; those want
  # opposite responses from whoever reads them.
  if grep -aq 'unable to attach DB\|database is locked' "$out"; then
    echo "  BUILD DID NOT RUN — this derivedData's build database is held by another build."
    echo "  This says NOTHING about the code. Find the holder:"
    echo "    ps -eo pid,etime,ppid,command | grep '[x]codebuild'"
    echo "  ppid 1 means orphaned (its CI job was cancelled) and is safe to kill; then re-run."
    fail "compile($cfg: build-db-contended — NOT a code failure)"
    return 1
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
#      SyntheticMicFrameSource, SyntheticTranscriptLiveTranscriber, BenchModel) leave symbols
#      in a binary that compiles
#      them. The identical detection is run first against the PerfRelease binary — which is
#      KNOWN to contain every seam — and every seam MUST be found there. If the control comes
#      up empty the gate declares ITSELF broken and fails; it never prints "clean" on a
#      detection it has not just proven works.
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
LEAK_SEAM_TYPES=(DemoSeed StressChurn SyntheticMicFrameSource SyntheticTranscriptLiveTranscriber BenchModel)
# NB: `-PerfLog` is deliberately NOT on this list — PerfMetricsSubscriber reads it in
# PRODUCTION code (it suppresses the launch-cost window when the harness owns the sensor),
# so its presence in Release is correct, not a leak.
LEAK_SEAM_ARGS=(-SyntheticMic -BrainSetupFailed -StressSeed -StressSegs -StressChurn -StallDemo -MainPreview
                -WelcomePreview -Screen -RemoteChat -SyntheticOmi -SyntheticTranscript -Onboarding)
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

# ---- ATS: the encryption floor must stay ON for everything but the named relay.
# `NSAllowsArbitraryLoads: true` removed it from EVERY request the app makes. It was
# a one-line entry that read like a scoped exception and was not one, and it sat next
# to a comment explaining why it had to be the only key — which is exactly how it
# survived. This asserts the BUILT plist, because project.yml is not what ships.
ats_gate() {
  local plist="$1" label="$2"
  if [ ! -f "$plist" ]; then
    echo "  [ats] no Info.plist at $plist"
    fail "ats-no-plist"
    return
  fi
  if plutil -extract NSAppTransportSecurity.NSAllowsArbitraryLoads raw -o - "$plist" >/dev/null 2>&1; then
    echo "  [ats] $label: NSAllowsArbitraryLoads IS PRESENT — the encryption floor is"
    echo "        removed for EVERY endpoint, not just the relay. Scope it to the one"
    echo "        host that needs plaintext (NSExceptionDomains) instead."
    fail "ats-arbitrary-loads"
    return
  fi
  # The relay exception is expected TODAY (it has no hostname or certificate and does
  # not answer TLS). This prints it so it stays visible rather than becoming permanent
  # by being forgotten.
  local hosts
  hosts=$(plutil -extract NSAppTransportSecurity.NSExceptionDomains xml1 -o - "$plist" 2>/dev/null \
          | grep -oE "<key>[^<]+</key>" | sed "s/<[^>]*>//g" | grep -E "^[0-9]+\." || true)
  if [ -n "$hosts" ]; then
    echo "  [ats] $label: plaintext still permitted for: $(echo "$hosts" | tr "\n" " ")"
    echo "        (tracked: relay needs a hostname + certificate; the id_token crosses"
    echo "        this leg in the clear until then)"
  fi
  echo "  [ats] $label: no app-wide arbitrary loads ✓"
}

phase_leak() {
  mkdir -p build
  local rel; rel="$DD/Build/Products/Release-iphonesimulator/FoundryX.app/FoundryX"
  local perf; perf="$DD/Build/Products/PerfRelease-iphonesimulator/FoundryX.app/FoundryX"

  ats_gate "$DD/Build/Products/Release-iphonesimulator/FoundryX.app/Info.plist" "Release"

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

# ------------------------------------------------- appscenarios: scenarios INSIDE the application
# What `iosbrine` above proves and what it cannot.
#
# `iosbrine` runs `Tests/FoundryXBrineTests` on the iOS RUNTIME, which is a real and valuable
# difference from macOS — it is what caught the keychain entitlement divergence. But the target
# it runs (`FoundryXiOSTests`) is HOSTLESS and depends on the FoundryXKit LIBRARY: it cannot
# import `App/` at all. So every scenario in it asserts against an object graph the test built,
# and passes identically whether or not the application reaches that graph.
#
# That is measured, not suspected. Of 17 `*FeatureTests.swift` files sampled across capture,
# chat, account, pocket, vault, device, sync, onboarding and search, 17 of 17 hand-build the
# seam and 0 of 17 drive a production entry point; 7 of the 73 feature suites hold any App-side
# fact and all 7 hold it by scanning App source as TEXT; and 345 of the 660 public types in
# `Sources/FoundryXKit` are never named in `App/` or `Widget/` at all. `PocketBLEClient.download`
# and `RecordingDeviceAdoption.remember` each shipped complete, covered and callerless.
#
# This phase runs the scenarios that are about the APPLICATION, inside it: a bundle hosted by
# `FoundryX.app` that `@testable import`s the app module. Deleting a call site in `App/` turns
# it red — verified by mutation, twice, on the commit that added it. Both mutations left this
# script's other phases, and the hostless pocket suites, entirely green.
phase_appscenarios() {
  echo "==> [appscenarios] scenarios driving App/ inside the real app process"
  command -v xcodegen >/dev/null || { fail "appscenarios(xcodegen-missing)"; return; }
  xcodegen generate >/dev/null 2>&1 || { fail "appscenarios(xcodegen-failed)"; return; }
  local udid
  udid=$(xcrun simctl list devices available 2>/dev/null | grep -E "iPhone" | grep -Eo "[0-9A-F-]{36}" | head -1)
  if [ -z "$udid" ]; then
    echo "  no available iPhone simulator runtime — the app-hosted lane cannot run"
    fail "appscenarios-no-simulator"
    return
  fi
  local out="build/ci-gates-appscenarios.log"
  mkdir -p build
  if ! xcodebuild test -project FoundryX.xcodeproj -scheme FoundryXAppScenarios \
       -configuration Debug -destination "id=$udid" -derivedDataPath "$DD" \
       CODE_SIGNING_ALLOWED=NO >"$out" 2>&1; then
    grep -aE '^\[failed\]|Failing tests|error:.*XCTAssert' "$out" | head -20
    fail "appscenarios-suite"
    return
  fi
  # A LANE THAT RAN NOTHING IS NOT A LANE THAT PASSED. `xcodebuild test` exits 0 for a bundle
  # whose only suite was renamed out of existence, and this is the one phase whose whole value
  # is that it exists — so the count is asserted, not printed.
  local n; n="$(grep -aoE 'Executed [0-9]+ tests?' "$out" | grep -oE '[0-9]+' | sort -n | tail -1)"
  echo "  appscenarios: executed ${n:-0} app-hosted test(s) on the iOS runtime, 0 failures"
  [ "${n:-0}" -lt 1 ] && fail "appscenarios-ran-nothing(${n:-0})"
}

# ---------------------------------------------------------------- uiproof: the recording SURFACE, on a simulator
# The layer the logic suite CANNOT see: the actual SwiftUI render + navigation of the
# capture surface, driven through the REAL pipeline. RecordingProof exercises the phone-mic
# Record button; AmbientRecordingProof exercises the OMI AMBIENT path — a speech onset opens
# a conversation with no button tap, the "Listening" hero tile carries it, and TAPPING that
# tile opens the recording page. ForegroundRestoreProof then switches apps mid-conversation
# and proves the same controls, elapsed clock, and transcript remain live on return. Those
# ambient flows shipped BROKEN and green because nothing rendered their lifecycle; this phase
# is the guard so they cannot recur. -SyntheticMic / -SyntheticOmi feed real Opus packets
# through the whole pipeline; -SyntheticTranscript substitutes only LiveTranscriber with a
# PCM-driven deterministic word source, leaving the real view/binding/restore path intact.
# A missing simulator is a LOUD failure, never a silent skip.
#
# RecorderPageProofUITests is the RECORDER PAGE — the screen a person opens to see what their
# recorder is holding, in each of the three states it can be in. No build had ever rendered it:
# reaching it in life needs a remembered record-then-sync recorder, a Bluetooth radio and the
# recorder on the desk, so the one screen that cannot be reached without hardware was also the
# one screen nobody could look at. It is mounted through the registered `-Screen recorder
# <state>` seam. `RecorderPageRenderedFeatureTests` fails if this line is removed.
phase_uiproof() {
  echo "==> [uiproof] recording-surface UI E2E on a simulator (phone-mic + Omi ambient + foreground restore + recorder page + recorder attribution)"
  local udid
  udid=$(xcrun simctl list devices available 2>/dev/null | grep -E "iPhone" | grep -Eo "[0-9A-F-]{36}" | head -1)
  if [ -z "$udid" ]; then
    echo "  no available iPhone simulator runtime — the capture-surface E2E cannot run"
    fail "uiproof-no-simulator"
    return
  fi
  xcrun simctl boot "$udid" >/dev/null 2>&1 || true
  # ------------------------------------------------ the proof must read state THIS run seeded
  # (review round 13, H13-1.) These proofs assert on a library `DemoSeed` writes into the app's
  # own container on launch, and that container SURVIVES between runs — this lane runs on
  # persistent native macOS workers whose simulators are never erased. Deleting the seed
  # outright therefore left the recorder-attribution proof PASSING on the previous run's
  # leftovers: the reviewer removed `CaptureDeviceSidecar.write(…)` from `DemoSeed` and the
  # case still passed in 8.5s, and only red once the app was uninstalled by hand. A proof whose
  # ability to fail is a property of the machine is not a gate. So: every run starts from a
  # container this run created. `simctl uninstall` is a no-op (rc=0) when nothing is installed,
  # so the outcome is CHECKED rather than assumed — a container that survives the uninstall is
  # a loud failure, not a quiet return to the state this exists to prevent.
  xcrun simctl uninstall "$udid" com.goforgeit.foundryx >/dev/null 2>&1 || true
  if xcrun simctl get_app_container "$udid" com.goforgeit.foundryx >/dev/null 2>&1; then
    echo "  the app is STILL INSTALLED after uninstall — this run would read the last run's seeded library"
    fail "uiproof-stale-app-container"
    return
  fi
  local out="build/ci-gates-uiproof.log"
  mkdir -p build
  if xcodebuild test -project FoundryX.xcodeproj -scheme FoundryXUIProof \
       -configuration Debug -destination "platform=iOS Simulator,id=$udid" \
       -derivedDataPath "$DD" \
       -only-testing:FoundryXUITests/ActionsProofUITests \
       -only-testing:FoundryXUITests/DeletionChoiceProofUITests \
       -only-testing:FoundryXUITests/RecordingProofUITests/testPhoneMicRecordingTimerAndSurface \
       -only-testing:FoundryXUITests/AmbientRecordingProofUITests/testAmbientSpeechOpensATappableRecordingConversation \
       -only-testing:FoundryXUITests/ForegroundRestoreProofUITests/testListeningSurfaceSurvivesBackgroundingAndStaysUsable \
       -only-testing:FoundryXUITests/ForegroundRestoreProofUITests/testLiveTranscriptRendersAndSurvivesBackgrounding \
       -only-testing:FoundryXUITests/VaultFunnelReachableProofUITests/testOwnerCanReachVaultSetupFromSettings \
       -only-testing:FoundryXUITests/RecordingDeviceProofUITests/testTheRecorderIsNamedOnTheConversationRowAndInItsDetail \
       -only-testing:FoundryXUITests/RecorderPageProofUITests \
       -only-testing:FoundryXUITests/PlaceRestoreProofUITests \
       -only-testing:FoundryXUITests/RecordingDevicesPageProofUITests \
       -only-testing:FoundryXUITests/RecordingDevicePageProofUITests \
       -only-testing:FoundryXUITests/PocketListenProofUITests \
       -only-testing:FoundryXUITests/RecorderClearingProofUITests \
       >"$out" 2>&1; then
    echo "  uiproof: recording surface (phone-mic + Omi ambient + foreground restore + place restore + recorder attribution) PASSED"
  else
    tail -50 "$out"
    fail "uiproof-recording-surface"
  fi
}

# ---------------------------------------------------------------- iosbrine: the same suite, on the iOS RUNTIME
# `swift test` runs the logic suite on macOS. That is NOT the platform we ship, and the
# two genuinely disagree: on 2026-07-25 the account-scope resolver read the keychain, which
# answers errSecMissingEntitlement (-34018) in the iOS test host but succeeds on macOS — so
# the free on-device tier fail-closed to an unwritable root on iOS while macOS was 1029/0
# green and this script printed CI GATES PASS. Only the pipeline's iOS lane caught it.
# This phase pulls that lane local so a green ci-gates cannot mean a red iOS runtime.
phase_iosbrine() {
  echo "==> [iosbrine] the logic suite on the iOS simulator runtime (not macOS)"
  command -v xcodegen >/dev/null || {
    fail "iosbrine(xcodegen-missing)"
    return
  }
  xcodegen generate >/dev/null 2>&1 || {
    fail "iosbrine(xcodegen-failed)"
    return
  }
  local udid
  udid=$(xcrun simctl list devices available 2>/dev/null | grep -E "iPhone" | grep -Eo "[0-9A-F-]{36}" | head -1)
  if [ -z "$udid" ]; then
    echo "  no available iPhone simulator runtime — the iOS Brine lane cannot run"
    fail "iosbrine-no-simulator"
    return
  fi
  local out="build/ci-gates-iosbrine.log"
  mkdir -p build
  if xcodebuild test -project FoundryX.xcodeproj -scheme FoundryX \
       -destination "id=$udid" CODE_SIGNING_ALLOWED=NO \
       >"$out" 2>&1; then
    # Report the WHOLE-suite line, not whichever per-suite summary happens to print
    # last — a trailing 5-test sub-suite reads like the run was tiny.
    local total
    total=$(grep -Eo 'Executed [0-9]+ tests' "$out" | grep -Eo '[0-9]+' | sort -n | tail -1)
    echo "  iosbrine: executed ${total:-?} tests on the iOS runtime, 0 failures — PASSED"
  else
    grep -E "Failing tests|error:.*XCTAssert" "$out" | head -20
    fail "iosbrine-suite"
  fi

  echo "==> [iosbrine] signed minimal host — real account-qualified iOS Keychain"
  local keychain_out="build/ci-gates-ios-keychain.log"
  if xcodebuild test -project FoundryX.xcodeproj \
       -scheme FoundryXKeychainProof \
       -destination "id=$udid" \
       -only-testing:PairingKeychainIntegrationTests \
       >"$keychain_out" 2>&1; then
    if grep -q "Executed 1 test, with 0 failures" "$keychain_out"; then
      echo "  ios-keychain: executed 1 hosted real-Keychain test, 0 failures — PASSED"
    else
      echo "  hosted Keychain command returned success without the required test"
      fail "ios-keychain-test-missing"
    fi
  else
    grep -E "Failing tests|error:|Signing" "$keychain_out" | head -20
    fail "ios-keychain-hosted-proof"
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
