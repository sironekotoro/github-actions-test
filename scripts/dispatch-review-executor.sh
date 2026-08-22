#!/usr/bin/env bash
# Submit one workflow_dispatch request and return immediately after GitHub
# accepts it. This script never polls, sleeps, watches, or waits for completion.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/repo.sh"

TASK_FILE="${TASK_FILE:-$RUNNER_TEMP/task.json}"
dispatcher="$(canonicalize_repo "${DISPATCHER_REPOSITORY:-}")"
dispatcher_ref="${DISPATCHER_REF:-}"
workflow="${REVIEW_EXECUTOR_WORKFLOW:-review-repair-executor.yml}"
repo="$(canonicalize_repo "$(jq -r '.target_repository' "$TASK_FILE")")"
pr="$(jq -r '.review.pr_number' "$TASK_FILE")"
review="$(jq -r '.review.id' "$TASK_FILE")"
head_sha="$(jq -r '.review.head_sha' "$TASK_FILE")"
attempt="$(jq -r '.review.attempt' "$TASK_FILE")"
detected_at="$(jq -r '.request.detected_at // ""' "$TASK_FILE")"
dispatched_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
request_id="review-${review}-attempt-${attempt}"

printf '%s' "$dispatcher" | grep -Eq '^[a-z0-9_.-]+/[a-z0-9_.-]+$' \
  || fail_with "$CAT_REPAIR_REQUEST" "dispatcher repository is invalid"
printf '%s' "$dispatcher_ref" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._/-]*$' \
  || fail_with "$CAT_REPAIR_REQUEST" "dispatcher default branch is invalid"
printf '%s' "$pr:$review:$attempt" | grep -Eq '^[1-9][0-9]*:[1-9][0-9]*:[1-9][0-9]*$' \
  || fail_with "$CAT_REPAIR_REQUEST" "executor identifiers are invalid"
printf '%s' "$head_sha" | grep -Eq '^[0-9a-f]{40}$' \
  || fail_with "$CAT_REPAIR_REQUEST" "reviewed head SHA is invalid"

if ! gh workflow run "$workflow" --repo "$dispatcher" --ref "$dispatcher_ref" \
  --raw-field "target_repository=$repo" \
  --raw-field "pr_number=$pr" \
  --raw-field "review_id=$review" \
  --raw-field "reviewed_head_sha=$head_sha" \
  --raw-field "attempt=$attempt" \
  --raw-field "detected_at=$detected_at" \
  --raw-field "dispatched_at=$dispatched_at" \
  --raw-field "dispatcher_run_id=${GITHUB_RUN_ID:-0}" \
  >/dev/null 2>"$RUNNER_TEMP/review-executor-dispatch.log"; then
  fail_with "$CAT_REPAIR_DISPATCH" "GitHub did not accept the executor dispatch"
fi

{
  echo "result=pass"
  echo "dispatched_at=$dispatched_at"
  echo "request_id=$request_id"
} >> "${GITHUB_OUTPUT:-/dev/null}"
summary "| executor dispatch | accepted |"
summary "| executor request | \`$request_id\` |"
log_info "executor dispatch accepted repo=$repo pr=$pr review=$review attempt=$attempt"
