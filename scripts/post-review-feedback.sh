#!/usr/bin/env bash
# Finalize target PR and originating dispatcher Issue feedback. The target App
# token and central GITHUB_TOKEN remain separate and are never printed.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

TASK_FILE="${TASK_FILE:-$RUNNER_TEMP/task.json}"
decision="${REPAIR_DECISION:-}"
[ -f "$TASK_FILE" ] || exit 0

repo="$(jq -r '.target_repository' "$TASK_FILE")"
dispatcher="$(jq -r '.dispatcher_repository' "$TASK_FILE")"
source_label="$(jq -r '.source' "$TASK_FILE")"
pr="$(jq -r '.review.pr_number' "$TASK_FILE")"
review="$(jq -r '.review.id' "$TASK_FILE")"
attempt="$(jq -r '.review.attempt' "$TASK_FILE")"
category="$(get_failure)"
run_url="${GITHUB_SERVER_URL:-https://github.com}/$dispatcher/actions/runs/${GITHUB_RUN_ID:-0}"
final_status=""

if [ "$decision" = "limit-reached" ]; then
  final_status="limit"
elif [ "$decision" = "run" ] && { [ "${EXECUTOR_STARTED:-}" = "true" ] || [ "${START_OUTCOME:-}" = "success" ]; }; then
  if [ "${COMMIT_OUTCOME:-}" = "success" ] && { [ -z "$category" ] || [ "$category" = "$CAT_REPAIR_LIMIT" ]; }; then
    final_status="completed"
  else
    final_status="failed"
  fi
fi

marker_already_written=false
[ "$final_status" = limit ] && [ "${LIMIT_OUTCOME:-}" = success ] && marker_already_written=true
if [ -n "$final_status" ] && [ "$marker_already_written" = false ] && [ -n "${TARGET_GH_TOKEN:-}" ]; then
  original_category="$category"
  GH_TOKEN="$TARGET_GH_TOKEN" REPAIR_STATUS="$final_status" \
    EXECUTOR_STARTED_AT="${EXECUTOR_STARTED_AT:-}" \
    EXECUTOR_FINISHED_AT="${EXECUTOR_FINISHED_AT:-}" \
    AGENT_RUNTIME_SECONDS="${AGENT_RUNTIME_SECONDS:-}" \
    EXECUTOR_RUN_URL="${EXECUTOR_RUN_URL:-}" \
    bash "$SCRIPT_DIR/mark-review-repair.sh" >/dev/null 2>&1 || log_warn "could not post final review repair marker"
  [ -n "$original_category" ] && set_failure "$original_category"
fi

summary "### Review repair report"
summary "| field | value |"
summary "|-------|-------|"
summary "| Target repository | \`$repo\` |"
summary "| PR / review | #$pr / $review |"
summary "| Attempt | $attempt |"
summary "| Decision | ${decision:-unknown} |"
summary "| Final status | ${final_status:-not-started} |"
summary "| Failure category | ${category:-none} |"
summary "| Detected | $(jq -r '.request.detected_at // "n/a"' "$TASK_FILE") |"
summary "| Dispatched | $(jq -r '.request.dispatched_at // "n/a"' "$TASK_FILE") |"
summary "| Executor started | ${EXECUTOR_STARTED_AT:-n/a} |"
summary "| Executor finished | ${EXECUTOR_FINISHED_AT:-n/a} |"
summary "| Agent runtime | ${AGENT_RUNTIME_SECONDS:+${AGENT_RUNTIME_SECONDS}s}${AGENT_RUNTIME_SECONDS:-n/a} |"
summary "| New PR | no |"

if printf '%s' "$source_label" | grep -Eq '^issue#[1-9][0-9]*$'; then
    issue_number="${source_label#issue#}"
    if [ -n "${DISPATCHER_GH_TOKEN:-}" ]; then
      if [ "$final_status" = completed ]; then
        message="✅ Review repair attempt $attempt completed for $repo PR #$pr on the same branch."
      elif [ "$final_status" = limit ]; then
        message="⛔ Review repair limit reached for $repo PR #$pr; no agent was started."
      elif [ "$final_status" = failed ]; then
        message="❌ Review repair attempt $attempt failed for $repo PR #$pr (category: ${category:-unknown})."
      else
        message="ℹ️ Review repair event for $repo PR #$pr was not started (decision: ${decision:-unknown})."
      fi
      GH_TOKEN="$DISPATCHER_GH_TOKEN" gh issue comment "$issue_number" --repo "$dispatcher" \
        --body "$message
- Review ID: $review
- Executor started: ${EXECUTOR_STARTED_AT:-n/a}
- Executor finished: ${EXECUTOR_FINISHED_AT:-n/a}
- Agent runtime: ${AGENT_RUNTIME_SECONDS:+${AGENT_RUNTIME_SECONDS}s}${AGENT_RUNTIME_SECONDS:-n/a}
- Run: $run_url" >/dev/null 2>&1 \
        || log_warn "could not post review repair feedback to source issue"
    fi
fi
