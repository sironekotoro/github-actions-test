#!/usr/bin/env bash
# Test 1-4, 8: repository identity guard
# Test 5-6: default branch detection
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/helpers.sh
source "$ROOT/tests/lib/helpers.sh"

GUARD="$ROOT/scripts/guard-repo.sh"

run_guard_repo() { # <expected> <actual> <remote>
  local tmp; tmp="$(make_temp)"
  printf '{"target_repository":"%s"}' "$1" > "$tmp/task.json"
  git init -q "$tmp/repo"
  git -C "$tmp/repo" remote add origin "$3"
  ( cd "$tmp/repo" \
      && RUNNER_TEMP="$tmp" GITHUB_OUTPUT="$tmp/out.txt" TASK_FILE="$tmp/task.json" \
         GITHUB_REPOSITORY="$2" bash "$GUARD" >"$tmp/stdout.log" 2>"$tmp/stderr.log" )
  local code=$?
  local cat=""; [ -f "$tmp/failure_category" ] && cat="$(cat "$tmp/failure_category")"
  local out=""; [ -f "$tmp/out.txt" ] && out="$(tr -d '\n' < "$tmp/out.txt")"
  echo "$code|$cat|$out"
}

# T1: exact match -> pass
res="$(run_guard_repo sironekotoro/github-actions-test sironekotoro/github-actions-test https://github.com/sironekotoro/github-actions-test.git)"
t "T1 target matches actual+remote -> pass" "0||result=pass" "$res"

# T2: owner differs -> reject
res="$(run_guard_repo other/github-actions-test sironekotoro/github-actions-test https://github.com/sironekotoro/github-actions-test.git)"
t "T2 owner mismatch -> REPOSITORY_IDENTITY_MISMATCH" "1|REPOSITORY_IDENTITY_MISMATCH" "$(echo "$res" | cut -d'|' -f1-2)"

# T3: repo name differs -> reject
res="$(run_guard_repo sironekotoro/zengin-pl sironekotoro/github-actions-test https://github.com/sironekotoro/github-actions-test.git)"
t "T3 repo mismatch -> REPOSITORY_IDENTITY_MISMATCH" "1|REPOSITORY_IDENTITY_MISMATCH" "$(echo "$res" | cut -d'|' -f1-2)"

# T4: git remote differs -> reject
res="$(run_guard_repo sironekotoro/github-actions-test sironekotoro/github-actions-test https://github.com/sironekotoro/other-repo.git)"
t "T4 remote mismatch -> REPOSITORY_IDENTITY_MISMATCH" "1|REPOSITORY_IDENTITY_MISMATCH" "$(echo "$res" | cut -d'|' -f1-2)"

# canonical forms must all match
res="$(run_guard_repo 'sironekotoro/GitHub-Actions-Test' 'sironekotoro/github-actions-test' 'git@github.com:sironekotoro/github-actions-test.git')"
t "T4b canonical forms (case/url/ssh) -> pass" "0||result=pass" "$res"

# T8: missing target repo -> INVALID_PAYLOAD
res="$(run_guard_repo "" sironekotoro/github-actions-test https://github.com/sironekotoro/github-actions-test.git)"
t "T8 missing target_repository -> INVALID_PAYLOAD" "1|INVALID_PAYLOAD" "$(echo "$res" | cut -d'|' -f1-2)"

# --- default branch detection (T5 main / T6 master) ---
source "$ROOT/scripts/lib/repo.sh"

make_bare() { # <branch> -> prints work clone path
  local tmp; tmp="$(make_temp)"
  git init --bare -q "$tmp/bare.git"
  git init -q "$tmp/work"
  git -C "$tmp/work" config user.email t@example.com
  git -C "$tmp/work" config user.name t
  git -C "$tmp/work" checkout -q -b "$1"
  touch "$tmp/work/x"; git -C "$tmp/work" add x; git -C "$tmp/work" commit -qm init
  git -C "$tmp/work" remote add origin "$tmp/bare.git"
  git -C "$tmp/work" push -q -u origin "$1"
  echo "$tmp/work"
}

w="$(make_bare master)"
t "T6 default branch master" "master" "$(cd "$w" && detect_default_branch sironekotoro/github-actions-test)"

w="$(make_bare main)"
t "T5 default branch main" "main" "$(cd "$w" && detect_default_branch sironekotoro/github-actions-test)"

finish