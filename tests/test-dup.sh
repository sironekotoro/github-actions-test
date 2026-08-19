#!/usr/bin/env bash
# Test 7: duplicate execution guard
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/helpers.sh
source "$ROOT/tests/lib/helpers.sh"

PREPARE="$ROOT/scripts/prepare-branch.sh"

make_repo() { # -> prints work clone path
  local tmp; tmp="$(make_temp)"
  git init --bare -q "$tmp/bare.git"
  git init -q "$tmp/work"
  git -C "$tmp/work" config user.email t@example.com
  git -C "$tmp/work" config user.name t
  git -C "$tmp/work" checkout -q -b master
  touch "$tmp/work/x"; git -C "$tmp/work" add x; git -C "$tmp/work" commit -qm init
  git -C "$tmp/work" remote add origin "$tmp/bare.git"
  git -C "$tmp/work" push -q -u origin master
  echo "$tmp"
}

run_prepare() { # <tmp> <task_id>
  local tmp="$1" task_id="$2"
  printf '{"task_id":"%s","target_repository":"sironekotoro/github-actions-test"}' "$task_id" > "$tmp/task.json"
  ( cd "$tmp/work" \
      && RUNNER_TEMP="$tmp" GITHUB_OUTPUT="$tmp/out.txt" TASK_FILE="$tmp/task.json" \
         GH_TOKEN="" bash "$PREPARE" >"$tmp/stdout.log" 2>"$tmp/stderr.log" )
  local code=$?
  local cat=""; [ -f "$tmp/failure_category" ] && cat="$(cat "$tmp/failure_category")"
  local br=""; grep '^branch=' "$tmp/out.txt" >/dev/null 2>&1 && br="$(grep '^branch=' "$tmp/out.txt")"
  local ok=""; grep '^result=' "$tmp/out.txt" >/dev/null 2>&1 && ok="$(grep '^result=' "$tmp/out.txt")"
  echo "$code|$cat|$br|$ok"
}

# T7: existing remote branch -> duplicate blocked
tmp="$(make_repo)"
git -C "$tmp/work" checkout -q -b agent/dup-task
git -C "$tmp/work" push -q -u origin agent/dup-task
git -C "$tmp/work" checkout -q master
res="$(run_prepare "$tmp" "dup-task")"
t "T7 existing branch -> TASK_ALREADY_RUNNING" "1|TASK_ALREADY_RUNNING||" "$res"

# new task -> branch created + result=pass
tmp="$(make_repo)"
res="$(run_prepare "$tmp" "new-task")"
t "T7b new task -> branch created + result=pass" "0||branch=agent/new-task|result=pass" "$res"

# dirty working tree -> blocked
tmp="$(make_repo)"
printf 'dirty' > "$tmp/work/x"
res="$(run_prepare "$tmp" "dirty-task")"
t "T7c dirty working tree -> DIRTY_WORKING_TREE" "1|DIRTY_WORKING_TREE" "$(echo "$res" | cut -d'|' -f1-2)"

finish