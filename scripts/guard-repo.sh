#!/usr/bin/env bash
# Repository identity guard.
#
# Compares the task's declared target repository against:
#   - $GITHUB_REPOSITORY (the repo the workflow is running in)
#   - the checked-out git remote.origin.url
#
# Any mismatch -> fail-safe stop BEFORE the agent starts.
# All comparisons use the canonical owner/name form (lowercase, .git stripped).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/repo.sh
source "$SCRIPT_DIR/lib/repo.sh"

TASK_FILE="${TASK_FILE:-$RUNNER_TEMP/task.json}"
if [ ! -f "$TASK_FILE" ]; then
  fail_with "$CAT_INVALID_PAYLOAD" "task.json not found at $TASK_FILE"
fi

expected="$(jq -r '.target_repository' "$TASK_FILE")"
actual="${GITHUB_REPOSITORY:-}"
remote="$(repo_remote_url)"

if [ -z "$expected" ]; then
  fail_with "$CAT_INVALID_PAYLOAD" "target_repository is empty in task.json"
fi
if [ -z "$actual" ]; then
  fail_with "$CAT_REPO_MISMATCH" "GITHUB_REPOSITORY is empty"
fi

exp_canon="$(canonicalize_repo "$expected")"
act_canon="$(canonicalize_repo "$actual")"
rem_canon="$(canonicalize_repo "$remote")"

summary "### Repository identity"
summary "| check | value |"
summary "|-------|-------|"
summary "| target (payload) | \`$exp_canon\` |"
summary "| actual (GITHUB_REPOSITORY) | \`$act_canon\` |"
summary "| checked-out remote | \`$rem_canon\` |"

if [ "$exp_canon" != "$act_canon" ] || [ "$exp_canon" != "$rem_canon" ]; then
  log_error "REPOSITORY IDENTITY MISMATCH"
  log_error "expected=$exp_canon actual=$act_canon remote=$rem_canon"
  log_error "AGENT_NOT_STARTED=REPOSITORY_IDENTITY_MISMATCH"
  fail_with "$CAT_REPO_MISMATCH" "expected=$exp_canon actual=$act_canon remote=$rem_canon AGENT_NOT_STARTED"
fi

log_info "repository identity OK ($exp_canon)"
echo "result=pass" >> "${GITHUB_OUTPUT:-/dev/null}"
summary "**Repository identity guard: PASS**"