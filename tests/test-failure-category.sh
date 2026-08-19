#!/usr/bin/env bash
# Regression: the failure category must survive re-sourcing of common.sh
# across workflow steps (post-feedback runs in a separate step from guard).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/helpers.sh
source "$ROOT/tests/lib/helpers.sh"
export ROOT

tmp="$(make_temp)"

# simulate step 1: guard writes the category
RUNNER_TEMP="$tmp" bash -c '
  source "$ROOT/scripts/lib/common.sh"
  set_failure REPOSITORY_IDENTITY_MISMATCH
'
t "step1 category recorded" "REPOSITORY_IDENTITY_MISMATCH" "$(cat "$tmp/failure_category")"

# simulate step 2: feedback re-sources common.sh (must not truncate)
cat="$(RUNNER_TEMP="$tmp" bash -c '
  source "$ROOT/scripts/lib/common.sh"
  get_failure
')"
t "category survives re-source across steps" "REPOSITORY_IDENTITY_MISMATCH" "$cat"

# a new failure overwrites the old one
RUNNER_TEMP="$tmp" bash -c '
  source "$ROOT/scripts/lib/common.sh"
  set_failure TASK_ALREADY_RUNNING
'
t "new failure overwrites" "TASK_ALREADY_RUNNING" "$(cat "$tmp/failure_category")"

finish