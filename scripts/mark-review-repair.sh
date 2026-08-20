#!/usr/bin/env bash
# Persist an auditable review-id marker on the existing PR. A started marker is
# written before agent invocation so the same review is never passed twice.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

TASK_FILE="${TASK_FILE:-$RUNNER_TEMP/task.json}"
status="${REPAIR_STATUS:-started}"
repo="$(jq -r '.target_repository' "$TASK_FILE")"
pr="$(jq -r '.review.pr_number' "$TASK_FILE")"
review="$(jq -r '.review.id' "$TASK_FILE")"
attempt="$(jq -r '.review.attempt' "$TASK_FILE")"

case "$status" in started|dispatched|executor-started|completed|failed|limit) ;; *) fail_with "$CAT_REPAIR_STATE" "invalid repair marker status" ;; esac
printf '%s' "$pr:$review:$attempt" | grep -Eq '^[1-9][0-9]*:[1-9][0-9]*:[1-9][0-9]*$' \
  || fail_with "$CAT_REPAIR_STATE" "invalid repair marker identifiers"

case "$status" in
  started) message="Automated review repair attempt $attempt was reserved by the hosted dispatcher." ;;
  dispatched) message="Automated review repair attempt $attempt was dispatched to the self-hosted executor." ;;
  executor-started) message="Self-hosted review repair executor started attempt $attempt." ;;
  completed) message="Automated review repair attempt $attempt completed on the same PR branch." ;;
  failed) message="Automated review repair attempt $attempt stopped. See the dispatcher run failure category." ;;
  limit) message="Automatic review repair limit reached; no agent was started. A maintainer must continue manually or submit a new task." ;;
esac
detected_at="${DETECTED_AT:-$(jq -r '.request.detected_at // ""' "$TASK_FILE")}"
dispatched_at="${DISPATCHED_AT:-$(jq -r '.request.dispatched_at // ""' "$TASK_FILE")}"
executor_started_at="${EXECUTOR_STARTED_AT:-}"
executor_finished_at="${EXECUTOR_FINISHED_AT:-}"
runtime_seconds="${AGENT_RUNTIME_SECONDS:-}"
run_url="${EXECUTOR_RUN_URL:-${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-}/actions/runs/${GITHUB_RUN_ID:-0}}"
body="$message

Review ID: \`$review\`
Detected: ${detected_at:-n/a}
Dispatched: ${dispatched_at:-n/a}
Executor started: ${executor_started_at:-n/a}
Executor finished: ${executor_finished_at:-n/a}
Agent runtime: ${runtime_seconds:+${runtime_seconds}s}${runtime_seconds:-n/a}
Run: $run_url
<!-- agent-review-repair:v1 status=$status review_id=$review attempt=$attempt -->"

gh pr comment "$pr" --repo "$repo" --body "$body" >/dev/null 2>&1 \
  || fail_with "$CAT_REPAIR_STATE" "could not persist review repair state on PR"
echo "result=pass" >> "${GITHUB_OUTPUT:-/dev/null}"
log_info "persisted review repair marker repo=$repo pr=$pr review=$review status=$status attempt=$attempt"
