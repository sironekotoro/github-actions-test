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

case "$status" in started|completed|failed|limit) ;; *) fail_with "$CAT_REPAIR_STATE" "invalid repair marker status" ;; esac
printf '%s' "$pr:$review:$attempt" | grep -Eq '^[1-9][0-9]*:[1-9][0-9]*:[1-9][0-9]*$' \
  || fail_with "$CAT_REPAIR_STATE" "invalid repair marker identifiers"

case "$status" in
  started) message="Automated review repair attempt $attempt started." ;;
  completed) message="Automated review repair attempt $attempt completed on the same PR branch." ;;
  failed) message="Automated review repair attempt $attempt stopped. See the dispatcher run failure category." ;;
  limit) message="Automatic review repair limit reached; no agent was started. A maintainer must continue manually or submit a new task." ;;
esac
body="$message

Review ID: \`$review\`
<!-- agent-review-repair:v1 status=$status review_id=$review attempt=$attempt -->"

gh pr comment "$pr" --repo "$repo" --body "$body" >/dev/null 2>&1 \
  || fail_with "$CAT_REPAIR_STATE" "could not persist review repair state on PR"
echo "result=pass" >> "${GITHUB_OUTPUT:-/dev/null}"
log_info "persisted review repair marker repo=$repo pr=$pr review=$review status=$status attempt=$attempt"
