#!/usr/bin/env bash
# Deliver one trusted lifecycle notification to configured external channels.
# Delivery is best-effort and never changes the originating agent task result.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

payload="${AGENT_NOTIFICATION_PAYLOAD:-}"
if [ -n "${AGENT_NOTIFICATION_COMMENT:-}" ]; then
  payload="$(python3 - <<'PY'
import os, re
body = os.getenv('AGENT_NOTIFICATION_COMMENT', '')
matches = re.findall(r'<!-- agent-notification:v1 (\{[^\r\n]*\}) -->', body)
print(matches[-1] if matches else '')
PY
)"
fi

if [ -n "$payload" ]; then
  event="$(jq -r '.event // empty' <<<"$payload" 2>/dev/null)"
  task_id="$(jq -r '.task_id // "n/a"' <<<"$payload" 2>/dev/null)"
  target="$(jq -r '.target_repository // "n/a"' <<<"$payload" 2>/dev/null)"
  reason="$(jq -r '.reason // "none"' <<<"$payload" 2>/dev/null)"
  run_url="$(jq -r '.run_url // "n/a"' <<<"$payload" 2>/dev/null)"
  source_url="$(jq -r '.source_url // ""' <<<"$payload" 2>/dev/null)"
  title="$(jq -r '.title // "Agent Dispatch notification"' <<<"$payload" 2>/dev/null)"
else
  event="${NOTIFICATION_EVENT:-}"
  task_id="${NOTIFICATION_TASK_ID:-n/a}"
  target="${NOTIFICATION_TARGET_REPOSITORY:-n/a}"
  reason="${NOTIFICATION_REASON:-none}"
  run_url="${NOTIFICATION_RUN_URL:-n/a}"
  source_url="${NOTIFICATION_SOURCE_URL:-}"
  title="${NOTIFICATION_TITLE:-Agent Dispatch notification}"
fi

case "$event" in
  TASK_COMPLETED|TASK_FAILED|ACTION_REQUIRED) ;;
  *) log_warn "trusted notification payload has invalid event; ignoring"; exit 0 ;;
esac

safe_line() { printf '%s' "$1" | tr '\r\n\000' '   ' | cut -c1-500; }
task_id="$(safe_line "$task_id")"
target="$(safe_line "$target")"
reason="$(safe_line "$reason")"
run_url="$(safe_line "$run_url")"
source_url="$(safe_line "$source_url")"
title="$(safe_line "$title")"

summary "### Agent lifecycle notification"
summary "| field | value |"
summary "|-------|-------|"
summary "| Event | $event |"
summary "| Task | $task_id |"
summary "| Target | $target |"
summary "| Reason | $reason |"
summary "| Run | $run_url |"

NOTIFICATION_EVENT="$event" \
NOTIFICATION_TASK_ID="$task_id" \
NOTIFICATION_TARGET_REPOSITORY="$target" \
NOTIFICATION_REASON="$reason" \
NOTIFICATION_RUN_URL="$run_url" \
NOTIFICATION_SOURCE_URL="$source_url" \
NOTIFICATION_TITLE="$title" \
python3 "$SCRIPT_DIR/send-agent-notification.py" \
  || log_warn "agent notification email delivery did not complete"

if [ "${AGENT_NOTIFICATION_SLACK_ENABLED:-false}" = true ]; then
  webhook="${AGENT_NOTIFICATION_SLACK_WEBHOOK_URL:-}"
  if [ -z "$webhook" ]; then
    log_warn "agent notification Slack webhook is not configured"
  else
    text="[$event] $title\nTask: $task_id\nTarget: $target\nReason: $reason\nRun: $run_url"
    [ -n "$source_url" ] && text="$text\nSource: $source_url"
    slack_json="$(jq -cn --arg text "$text" '{text:$text}')"
    if [ "${AGENT_NOTIFICATION_SLACK_DRY_RUN:-false}" = true ]; then
      log_info "agent notification Slack dry-run: $event"
    else
      curl --fail --silent --show-error --max-time 15 \
        -H 'Content-Type: application/json' \
        --data "$slack_json" "$webhook" >/dev/null 2>&1 \
        || log_warn "agent notification Slack delivery failed"
    fi
  fi
fi

log_info "processed lifecycle notification event=$event task=$task_id"
exit 0
