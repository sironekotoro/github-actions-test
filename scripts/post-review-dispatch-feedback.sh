#!/usr/bin/env bash
# Record the hosted control-plane outcome without waiting for the executor.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

TASK_FILE="${TASK_FILE:-$RUNNER_TEMP/task.json}"
[ -f "$TASK_FILE" ] || exit 0

decision="${REPAIR_DECISION:-}"
repo="$(jq -r '.target_repository' "$TASK_FILE")"
dispatcher="$(jq -r '.dispatcher_repository' "$TASK_FILE")"
source_label="$(jq -r '.source' "$TASK_FILE")"
pr="$(jq -r '.review.pr_number' "$TASK_FILE")"
review="$(jq -r '.review.id' "$TASK_FILE")"
attempt="$(jq -r '.review.attempt' "$TASK_FILE")"
category="$(get_failure)"
status=""

if [ "$decision" = "limit-reached" ]; then
  status="limit"
elif [ "$decision" = "run" ] && [ "${RESERVE_OUTCOME:-}" = "success" ]; then
  if [ "${DISPATCH_OUTCOME:-}" = "success" ]; then
    status="dispatched"
  else
    status="failed"
  fi
fi

if [ -n "$status" ] && [ -n "${TARGET_GH_TOKEN:-}" ]; then
  GH_TOKEN="$TARGET_GH_TOKEN" REPAIR_STATUS="$status" \
    DETECTED_AT="$(jq -r '.request.detected_at // ""' "$TASK_FILE")" \
    DISPATCHED_AT="${DISPATCHED_AT:-}" \
    bash "$SCRIPT_DIR/mark-review-repair.sh" >/dev/null 2>&1 \
    || log_warn "could not post hosted dispatcher outcome"
fi

summary "### Review repair dispatch"
summary "| field | value |"
summary "|-------|-------|"
summary "| Target / PR | \`$repo\` / #$pr |"
summary "| Review / attempt | $review / $attempt |"
summary "| Detected | $(jq -r '.request.detected_at // "n/a"' "$TASK_FILE") |"
summary "| Dispatched | ${DISPATCHED_AT:-n/a} |"
summary "| Control-plane status | ${status:-not-dispatched} |"
summary "| Failure category | ${category:-none} |"
summary "| Waited for executor | no |"

if printf '%s' "$source_label" | grep -Eq '^issue#[1-9][0-9]*$' && [ -n "${DISPATCHER_GH_TOKEN:-}" ]; then
  issue_number="${source_label#issue#}"
  if [ "$status" = dispatched ]; then
    message="📨 Review repair attempt $attempt dispatched for $repo PR #$pr. The hosted dispatcher has finished; execution continues on self-hosted infrastructure."
  elif [ "$status" = limit ]; then
    message="⛔ Review repair limit reached for $repo PR #$pr; no executor was dispatched."
  else
    message="❌ Review repair dispatch failed for $repo PR #$pr (category: ${category:-unknown})."
  fi
  GH_TOKEN="$DISPATCHER_GH_TOKEN" gh issue comment "$issue_number" --repo "$dispatcher" \
    --body "$message
- Review ID: $review
- Detected: $(jq -r '.request.detected_at // "n/a"' "$TASK_FILE")
- Dispatched: ${DISPATCHED_AT:-n/a}
- Dispatcher run: ${GITHUB_SERVER_URL:-https://github.com}/$dispatcher/actions/runs/${GITHUB_RUN_ID:-0}" \
    >/dev/null 2>&1 || log_warn "could not post dispatch feedback to source issue"
fi
