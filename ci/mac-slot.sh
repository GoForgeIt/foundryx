#!/usr/bin/env bash
# mac-slot.sh — a MACHINE-WIDE semaphore for GitHub Actions jobs that must run
# on the one physical Mac.
#
# ── WHY THIS FILE EXISTS ─────────────────────────────────────────────────────
# Every kit publish and the Foundry host build run on a self-hosted runner that
# is the owner's working machine. Each of those repositories declared
#
#     concurrency:
#       group: macos-build
#
# and that group reads as a machine-wide lock but is NOT one: a concurrency
# group is scoped to ONE repository. Eight repositories each holding their own
# `macos-build` group serialise nothing across repositories, which is how three
# publishes ran at once and the machine reached load 119 on 14 cores.
#
# The bound has to live where the contention is — on the machine — so it is a
# lock directory under /Users/Shared that every runner on this Mac shares. All
# eleven runners execute as the same user (verified: every Runner.Listener is
# owned by the same account), so one shared root is reachable by all of them.
#
# ── THIS IS NOT A NEW IDEA HERE. IT IS A RESTORED ONE ────────────────────────
# Concourse had exactly this bound and foundry's own tree still documents it, in
# ci/scripts/check-macos-build-lock.py:
#
#     WHY THIS EXISTS. `serial_groups` only serializes jobs inside ONE pipeline.
#     temper, lore, kiln, lantis and the app each have a mac lane on the same
#     builder, so nothing stopped two of them running concurrently — the
#     2026-05-29 jetsam OOM (build #108) was two concurrent LTO links on one
#     64GB Mac. The fix is a Concourse `pool` resource in a shared git repo,
#     acquired by every heavy mac job.
#
# The Actions migration replaced that shared pool resource with a per-repository
# `concurrency:` group, which has the same NAME and not the same SCOPE, and the
# machine has been overcommitting again ever since. So this file is the pool
# resource, in the form Actions can hold: acquired by the first heavy step,
# released by the last, machine-wide by construction.
#
# ── WHY IT IS COPIED INTO EACH REPO ──────────────────────────────────────────
# Guards belong at the narrowest common point, and the narrowest common point
# here IS the machine — which is exactly what the lock root is. This script is
# only the CLIENT of that lock. A single shared copy would have to be either a
# cross-repository composite action (every repo here is private, so a job in
# one repo cannot check out another without a PAT) or an unversioned file on
# the machine (a CI step depending on a file no commit produces). So the client
# is vendored, byte-identical, and the shared thing — the lock root — is the
# part that must not be duplicated. If you edit this file, edit every copy.
#
# ── MECHANISM ────────────────────────────────────────────────────────────────
# N slot directories. `mkdir` is atomic on POSIX, so exactly one contender can
# create a given slot; there is no read-then-write window to lose. A holder
# writes its identity and the pid of the runner's Runner.Worker process — the
# process that lives for the whole job and dies with it — so a slot orphaned by
# a cancelled or crashed job is reclaimed as soon as that pid is gone, not two
# hours later. When no Runner.Worker ancestor can be found the guard pid is
# recorded as 0 and the slot is held until the TTL expires: that errs toward
# holding a slot too long, never toward handing out more slots than exist.
#
# ── USAGE ────────────────────────────────────────────────────────────────────
#   ci/mac-slot.sh acquire <label>   # blocks until a slot is free; fails loud
#                                    # if the wait budget is exhausted
#   ci/mac-slot.sh release           # releases the slot this job holds
#   ci/mac-slot.sh status            # prints every slot and its holder
#
# Knobs (all optional):
#   MAC_SLOT_ROOT     lock root                (default /Users/Shared/foundry-ci/mac-slots)
#   MAC_SLOT_COUNT    slots                    (default: $ROOT/SLOTS, else 2)
#   MAC_SLOT_TTL      seconds before a slot is
#                     reclaimable on age alone (default 7200; job caps are 90m)
#   MAC_SLOT_WAIT     seconds to wait for a
#                     slot before failing loud (default 5400)
#
# There is no "give up and run anyway" path. A step that cannot get a slot
# fails; it never runs unbounded.

set -euo pipefail

ROOT="${MAC_SLOT_ROOT:-/Users/Shared/foundry-ci/mac-slots}"
TTL="${MAC_SLOT_TTL:-7200}"
WAIT_BUDGET="${MAC_SLOT_WAIT:-5400}"
POLL="${MAC_SLOT_POLL:-10}"
TOKEN=""

now() { date +%s; }

# Where this job remembers which slot it took. Keyed by run+job so two jobs of
# the same run on the same machine do not overwrite each other's record.
state_file() {
  printf '%s\n' "${MAC_SLOT_STATE_FILE:-$ROOT/.held-${GITHUB_RUN_ID:-shell}-${GITHUB_RUN_ATTEMPT:-1}-${GITHUB_JOB:-none}}"
}

slot_count() {
  if [ -n "${MAC_SLOT_COUNT:-}" ]; then
    printf '%s\n' "$MAC_SLOT_COUNT"
    return
  fi
  # An operator knob that needs no commit: write a number into $ROOT/SLOTS to
  # widen or narrow the machine's build parallelism between runs.
  if [ -r "$ROOT/SLOTS" ]; then
    local n
    n="$(tr -dc '0-9' < "$ROOT/SLOTS")"
    if [ -n "$n" ] && [ "$n" -gt 0 ] 2>/dev/null; then
      printf '%s\n' "$n"
      return
    fi
  fi
  printf '%s\n' 2
}

# The pid that represents THIS JOB for as long as it runs. Steps come and go —
# the shell running `acquire` is gone before the build step starts — so the
# holder's liveness cannot be the shell's own pid. The runner spawns one
# Runner.Worker per job and kills it when the job ends, which is exactly the
# lifetime the slot must track.
guard_pid() {
  local pid ppid cmd hops
  pid="$$"
  hops=0
  while [ "$hops" -lt 24 ] && [ "$pid" -gt 1 ] 2>/dev/null; do
    cmd="$(ps -o comm= -p "$pid" 2>/dev/null || true)"
    case "$cmd" in
      *Runner.Worker*) printf '%s\n' "$pid"; return 0 ;;
    esac
    ppid="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d '[:space:]')"
    [ -n "$ppid" ] || break
    pid="$ppid"
    hops=$((hops + 1))
  done
  # No Runner.Worker ancestor (local shell, or a runner layout we do not know).
  # 0 means "no liveness guard" and the slot then lives out its full TTL.
  printf '%s\n' 0
}

owner_id() {
  printf '%s\n' "${MAC_SLOT_OWNER:-${GITHUB_REPOSITORY:-local}|${GITHUB_WORKFLOW:-shell}|${GITHUB_JOB:-none}|${GITHUB_RUN_ID:-unknown}|${GITHUB_RUN_ATTEMPT:-1}}"
}

# `started` is only believable as an epoch. An absent, empty or non-numeric
# value must NEVER read as "1970, therefore ancient, therefore reclaim" — that
# reading is what let a contender delete a slot another contender had held for
# a few milliseconds, and hand out four slots against a limit of two.
plausible_epoch() {
  case "${1:-}" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$1" -gt 1000000000 ] 2>/dev/null
}

# A slot is reclaimable when its guarding process is gone, or when it is older
# than the TTL. Both are read from the slot's own meta file; a slot whose meta
# is unreadable is treated as reclaimable ONLY on age, never on the unreadable
# meta itself — an unreadable holder is not proof of an absent holder.
reap_if_stale() {
  local slot="$1" meta pid started age
  meta="$slot/meta"
  [ -d "$slot" ] || return 1

  if [ -r "$meta" ]; then
    pid="$(sed -n 's/^pid=//p' "$meta" | head -1)"
    started="$(sed -n 's/^started=//p' "$meta" | head -1)"
  else
    # No meta yet. `meta` is renamed into place, never written in place, so the
    # only way to see this is the sliver between `mkdir` and that rename — i.e.
    # a slot someone acquired a moment ago, or one whose acquirer died inside
    # that sliver. Age it off the directory's own mtime and give it a grace
    # window; there is no liveness pid to consult.
    pid=0
    started="$(stat -f %m "$slot" 2>/dev/null || stat -c %Y "$slot" 2>/dev/null || true)"
    if plausible_epoch "${started:-}" && [ $(( $(now) - started )) -gt "${MAC_SLOT_GRACE:-120}" ]; then
      echo "==> mac-slot: reclaiming $(basename "$slot") — no meta ${MAC_SLOT_GRACE:-120}s after creation" >&2
      rm -rf "$slot"
      return 0
    fi
    return 1
  fi

  case "${pid:-}" in ''|*[!0-9]*) pid=0 ;; esac

  if [ "$pid" -gt 0 ] 2>/dev/null; then
    if ! kill -0 "$pid" 2>/dev/null; then
      echo "==> mac-slot: reclaiming $(basename "$slot") — guard pid $pid is gone" >&2
      rm -rf "$slot"
      return 0
    fi
    # A live guard pid outranks the clock: the job is demonstrably still there.
    return 1
  fi

  # No liveness guard, so the TTL is all there is. An unreadable or implausible
  # `started` is NOT evidence of age — refuse to reclaim on it.
  if ! plausible_epoch "${started:-}"; then
    echo "==> mac-slot: $(basename "$slot") has no usable start time — leaving it held (refusing to reclaim on an unread value)" >&2
    return 1
  fi
  age=$(( $(now) - started ))
  if [ "$age" -gt "$TTL" ] 2>/dev/null; then
    echo "==> mac-slot: reclaiming $(basename "$slot") — held ${age}s, past TTL ${TTL}s" >&2
    rm -rf "$slot"
    return 0
  fi
  return 1
}

try_acquire_one() {
  local label="$1" n i slot staged
  n="$(slot_count)"
  # Everything the meta file will say is computed BEFORE the mkdir, and the
  # file itself is renamed into place rather than written in place. A reader
  # therefore sees either no meta at all or a complete one — never the empty
  # file that a plain `> meta` redirection publishes the instant it opens.
  staged="$ROOT/.meta.$$.${RANDOM}"
  {
    printf 'owner=%s\n' "$(owner_id)"
    printf 'token=%s\n' "$TOKEN"
    printf 'label=%s\n' "$label"
    printf 'pid=%s\n' "$(guard_pid)"
    printf 'started=%s\n' "$(now)"
    printf 'host=%s\n' "${RUNNER_NAME:-$(hostname)}"
  } > "$staged"

  i=1
  while [ "$i" -le "$n" ]; do
    slot="$ROOT/slot.$i"
    if mkdir "$slot" 2>/dev/null; then
      mv "$staged" "$slot/meta"
      printf '%s\n' "$slot"
      return 0
    fi
    i=$((i + 1))
  done
  rm -f "$staged"
  return 1
}

cmd_acquire() {
  local label="${1:-unlabelled}" deadline slot n
  mkdir -p "$ROOT"
  chmod 1777 "$ROOT" 2>/dev/null || true
  n="$(slot_count)"
  # A one-shot secret written into both the slot and this job's state file.
  # Release deletes a slot only on a token match, so it can never delete the
  # slot of the job that took over after this one's was reclaimed — and the
  # match does not depend on any pid, which differs between the acquiring
  # step's shell and the releasing step's shell.
  TOKEN="$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
  deadline=$(( $(now) + WAIT_BUDGET ))
  echo "==> mac-slot: acquiring 1 of $n machine-wide mac build slots for '$label' (root $ROOT)"
  while :; do
    if slot="$(try_acquire_one "$label")"; then
      echo "==> mac-slot: HELD $(basename "$slot") by $(owner_id)"
      if [ -n "${GITHUB_ENV:-}" ]; then
        printf 'MAC_SLOT_HELD=%s\n' "$slot" >> "$GITHUB_ENV"
        printf 'MAC_SLOT_TOKEN=%s\n' "$TOKEN" >> "$GITHUB_ENV"
      fi
      printf '%s\n%s\n' "$slot" "$TOKEN" > "$(state_file)"
      return 0
    fi
    # Nothing free. Reap anything whose holder is provably gone, then wait.
    local i=1
    while [ "$i" -le "$n" ]; do
      reap_if_stale "$ROOT/slot.$i" || true
      i=$((i + 1))
    done
    if [ "$(now)" -ge "$deadline" ]; then
      echo "ERROR: mac-slot: no slot free after ${WAIT_BUDGET}s. Current holders:" >&2
      cmd_status >&2
      echo "  This job did NOT run. It is not permitted to proceed unbounded —" >&2
      echo "  that is the exact failure this lock exists to prevent." >&2
      return 1
    fi
    sleep "$(( POLL + (RANDOM % 5) ))"
  done
}

cmd_release() {
  local slot="${MAC_SLOT_HELD:-}" token="${MAC_SLOT_TOKEN:-}" state
  state="$(state_file)"
  if [ -z "$slot" ] || [ -z "$token" ]; then
    if [ -r "$state" ]; then
      slot="$(sed -n 1p "$state")"
      token="$(sed -n 2p "$state")"
    fi
  fi
  if [ -z "${slot:-}" ] || [ ! -d "$slot" ]; then
    echo "==> mac-slot: nothing to release (no slot recorded for this job)"
    return 0
  fi
  local held_token
  held_token="$(sed -n 's/^token=//p' "$slot/meta" 2>/dev/null | head -1 || true)"
  if [ -z "$token" ] || [ "$held_token" != "$token" ]; then
    # The slot in the state file is now held by SOMEONE ELSE — ours was
    # reclaimed and reissued. Deleting it here would hand a third job a slot
    # that is legitimately taken, which is the bug this whole file exists to
    # prevent. Say so loudly and touch nothing.
    echo "==> mac-slot: NOT releasing $(basename "$slot") — its token does not match ours; it belongs to '$(sed -n 's/^owner=//p' "$slot/meta" 2>/dev/null | head -1)'" >&2
    rm -f "$state"
    return 0
  fi
  rm -rf "$slot"
  rm -f "$state"
  echo "==> mac-slot: released $(basename "$slot")"
}

cmd_status() {
  local n i slot
  n="$(slot_count)"
  echo "mac-slot root: $ROOT  slots: $n  ttl: ${TTL}s"
  i=1
  while [ "$i" -le "$n" ]; do
    slot="$ROOT/slot.$i"
    if [ -d "$slot" ]; then
      echo "  slot.$i HELD"
      sed 's/^/    /' "$slot/meta" 2>/dev/null || echo "    (meta unreadable)"
    else
      echo "  slot.$i free"
    fi
    i=$((i + 1))
  done
}

case "${1:-}" in
  acquire) shift; cmd_acquire "$@" ;;
  release) shift; cmd_release "$@" ;;
  status)  shift; cmd_status "$@" ;;
  *)
    echo "usage: $0 {acquire <label>|release|status}" >&2
    exit 2
    ;;
esac
