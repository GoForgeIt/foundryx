#!/usr/bin/env bash
# worktree-triage.sh — decide whether a worktree and its branch can be deleted, SAFELY.
#
# WHY THIS EXISTS. On 2026-08-21 a cleanup of this repository destroyed two files and nearly lost
# five more. The method used was: compare the worktree's working tree against origin/main, and if
# it deletes far more than it adds, it is a stale snapshot and can go. That method is careful,
# reads as rigorous, and is STRUCTURALLY BLIND to the thing that matters:
#
#     `git diff` DOES NOT REPORT UNTRACKED FILES.
#
# So a worktree holding brand-new source that has never been added shows a clean, reassuring diff.
# `git worktree remove --force` then deletes it without asking — and `--force` exists precisely to
# override the refusal that would otherwise have saved it. THE REFUSAL WAS THE CHECK.
#
# Files actually destroyed that day: Sources/FoundryXKit/CaptureDiagLine.swift and
# Tests/FoundryXBrineTests/CaptureDiagNamesTheRecorderTests.swift. Not in any git object, not on
# disk. Five others survived only because a dangling stash commit happened to still exist.
#
# USAGE:  scripts/worktree-triage.sh                 # report on every worktree
#         scripts/worktree-triage.sh <path>          # report on one
#
# It NEVER deletes anything. It answers "is this safe to delete", and it refuses to say yes on
# anything it cannot establish.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 1
git fetch -q origin 2>/dev/null || true

verdict_for() {
  local wt="$1" main="origin/main"
  local br; br=$(git -C "$wt" symbolic-ref --quiet --short HEAD 2>/dev/null || echo "(detached)")
  printf '\n=== %s  [%s]\n' "$wt" "$br"

  # 1. THE ONE THAT WAS MISSED. Untracked and unignored files are invisible to every diff below.
  local untracked; untracked=$(git -C "$wt" status --porcelain 2>/dev/null | grep '^??' || true)
  if [ -n "$untracked" ]; then
    echo "  REFUSE — $(echo "$untracked" | wc -l | tr -d ' ') UNTRACKED file(s). These appear in NO diff."
    echo "$untracked" | sed 's/^/      /'
    echo "  Resolve each (commit, move, or confirm disposable) before removing this worktree."
    return
  fi

  # 2. A stash whose base is THIS branch. `refs/stash` is REPO-WIDE, not per-worktree — the first
  #    version of this check ran `git stash list` per worktree and refused on all seven because
  #    one shared entry reported against every one. A check that always refuses is as useless as
  #    one that never does; it just fails in the safe direction, which is easy to mistake for
  #    working. Match the branch name instead.
  if [ "$br" != "(detached)" ]; then
    local mine; mine=$(git stash list 2>/dev/null | grep -c " on ${br}:" || true)
    [ "${mine:-0}" -gt 0 ] && { echo "  REFUSE — $mine stash entr(y/ies) based on $br."; return; }
  fi

  # 3. Only now is a diff meaningful, and only for TRACKED content.
  local add del
  add=$(git -C "$wt" diff "$main" --numstat 2>/dev/null | awk '{a+=$1} END{print a+0}')
  del=$(git -C "$wt" diff "$main" --numstat 2>/dev/null | awk '{d+=$2} END{print d+0}')
  echo "  tracked working tree vs $main: +$add / -$del"

  if [ "$br" != "(detached)" ]; then
    if git merge-base --is-ancestor "$br" "$main" 2>/dev/null; then
      echo "  branch tip is an ANCESTOR of $main — the commits are on main"
    else
      echo "  branch tip is NOT on $main — $(git -C "$wt" rev-list --count "$main".."$br" 2>/dev/null) commit(s) ahead"
    fi
  fi

  if [ "${add:-0}" -eq 0 ] && [ "${del:-0}" -eq 0 ]; then
    echo "  SAFE TO REMOVE — no untracked files, no stashes, working tree identical to $main"
  else
    echo "  REVIEW BY HAND — content differs. A large deletion count usually means a STALE snapshot"
    echo "     whose restoration would REGRESS main; confirm by reading, not by the ratio."
  fi
}

if [ $# -ge 1 ]; then verdict_for "$1"; else
  git worktree list --porcelain | awk '$1=="worktree"{print $2}' | while read -r wt; do
    [ "$wt" = "$(git rev-parse --show-toplevel)" ] && continue
    verdict_for "$wt"
  done
fi
echo
echo "This script never deletes. Nothing here authorises --force."
