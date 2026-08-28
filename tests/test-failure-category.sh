#!/usr/bin/env bash
# Regression: the failure category must survive re-sourcing of common.sh
# across workflow steps (post-feedback runs in a separate step from guard).
# Also verifies the FAILURE_REASON file is preserved across re-sourcing.
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
  set_failure_reason NO_CHANGES
'
t "step1 category recorded" "REPOSITORY_IDENTITY_MISMATCH" "$(cat "$tmp/failure_category")"
t "step1 reason recorded" "NO_CHANGES" "$(cat "$tmp/failure_reason")"

# simulate step 2: feedback re-sources common.sh (must not truncate)
cat="$(RUNNER_TEMP="$tmp" bash -c '
  source "$ROOT/scripts/lib/common.sh"
  get_failure
')"
t "category survives re-source across steps" "REPOSITORY_IDENTITY_MISMATCH" "$cat"

reason="$(RUNNER_TEMP="$tmp" bash -c '
  source "$ROOT/scripts/lib/common.sh"
  get_failure_reason
')"
t "reason survives re-source across steps" "NO_CHANGES" "$reason"

# a new failure overwrites the old one
RUNNER_TEMP="$tmp" bash -c '
  source "$ROOT/scripts/lib/common.sh"
  set_failure TASK_ALREADY_RUNNING
  set_failure_reason PATCH_VALIDATION_FAILED
'
t "new failure overwrites" "TASK_ALREADY_RUNNING" "$(cat "$tmp/failure_category")"
t "new reason overwrites" "PATCH_VALIDATION_FAILED" "$(cat "$tmp/failure_reason")"

# clear_failure_reason works
RUNNER_TEMP="$tmp" bash -c '
  source "$ROOT/scripts/lib/common.sh"
  clear_failure_reason
'
t "clear_failure_reason clears" "" "$(cat "$tmp/failure_reason")"

finish