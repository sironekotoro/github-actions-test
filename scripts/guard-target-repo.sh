#!/usr/bin/env bash
# Second repository-identity guard for a separately checked-out target repo.
# Run from the target repository working directory after checkout.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/repo.sh"

TASK_FILE="${TASK_FILE:-$RUNNER_TEMP/task.json}"
[ -f "$TASK_FILE" ] || fail_with "$CAT_INVALID_PAYLOAD" "task.json not found"

expected="$(canonicalize_repo "$(jq -r '.target_repository // ""' "$TASK_FILE")")"
remote="$(canonicalize_repo "$(repo_remote_url)")"

if [ -z "$expected" ] || [ -z "$remote" ]; then
  fail_with "$CAT_REPO_MISMATCH" "target or checked-out remote is empty AGENT_NOT_STARTED"
fi

summary "### Target checkout identity"
summary "| check | value |"
summary "|-------|-------|"
summary "| target (payload) | \`$expected\` |"
summary "| target checkout remote | \`$remote\` |"

if [ "$expected" != "$remote" ]; then
  log_error "REPOSITORY IDENTITY MISMATCH"
  log_error "expected=$expected remote=$remote"
  log_error "AGENT_NOT_STARTED=REPOSITORY_IDENTITY_MISMATCH"
  fail_with "$CAT_REPO_MISMATCH" "expected=$expected remote=$remote AGENT_NOT_STARTED"
fi

log_info "target checkout identity OK ($expected)"
echo "result=pass" >> "${GITHUB_OUTPUT:-/dev/null}"
summary "**Target repository identity guard: PASS**"
