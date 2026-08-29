#!/usr/bin/env bash
# Validate the post-agent repository state and enforce publication policy.
# Agent-generated GitHub workflow files are never published automatically.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/repo.sh"
source "$SCRIPT_DIR/lib/workflow-push.sh"

TASK_FILE="${TASK_FILE:-$RUNNER_TEMP/task.json}"
mode="${DISPATCH_MODE:-same}"
default_branch="${DEFAULT_BRANCH:-}"

[ -f "$TASK_FILE" ] || fail_with "$CAT_INVALID_PAYLOAD" "task.json not found"
[ "$mode" = same ] || [ "$mode" = cross ] \
  || fail_with "$CAT_INVALID_PAYLOAD" "dispatch mode is invalid"

task_id="$(jq -r '.task_id // ""' "$TASK_FILE")"
target="$(canonicalize_repo "$(jq -r '.target_repository // ""' "$TASK_FILE")")"
remote="$(canonicalize_repo "$(repo_remote_url)")"
dispatcher="$(canonicalize_repo "${DISPATCHER_REPOSITORY:-${GITHUB_REPOSITORY:-$target}}")"
expected_branch="agent/$task_id"
branch="$(git branch --show-current)"

[ -n "$task_id" ] && [ -n "$target" ] && [ -n "$remote" ] \
  || fail_with "$CAT_INVALID_PAYLOAD" "task or target repository is empty"
[ "$target" = "$remote" ] \
  || fail_with "$CAT_REPO_MISMATCH" "target repository changed after agent execution"
[ "$branch" = "$expected_branch" ] \
  || fail_with "$CAT_REPO_MISMATCH" "agent branch changed after preparation"
[ -n "$default_branch" ] && git show-ref --verify --quiet "refs/heads/$default_branch" \
  || fail_with "$CAT_REPO_MISMATCH" "expected base branch is unavailable"
if [ "$mode" = same ] && [ "$target" != "$dispatcher" ]; then
  fail_with "$CAT_REPO_MISMATCH" "same-repository dispatcher identity changed"
fi

workflow_push_validate_paths
if workflow_push_diff_contains_workflows; then
  if [ "$mode" = cross ]; then
    fail_with "$CAT_CROSS_REPO_WORKFLOW_PUSH_UNSUPPORTED" \
      "agent-generated .github/workflows changes are intentionally unsupported"
  fi
  fail_with "$CAT_WORKFLOW_PUSH_AUTH_NOT_CONFIGURED" \
    "agent-generated .github/workflows changes require manual trusted review and publication"
fi

{
  echo "workflow_change=false"
  echo "result=pass"
} >> "${GITHUB_OUTPUT:-/dev/null}"
summary "| workflow-file diff | false |"
summary "| workflow publication | automatic agent publication disabled |"
log_info "publication policy validation: no workflow-file diff"
