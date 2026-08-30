#!/usr/bin/env bash
# Trusted control-plane budget notification. No provider secret or prompt content
# is accepted by this script.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

state="${BUDGET_STATE:-disabled}"
provider="${BUDGET_PROVIDER:-unknown}"
repo="${GITHUB_REPOSITORY:-}"
[ "$state" = disabled ] && exit 0
[ -n "$repo" ] || { log_warn "budget notifier has no repository"; exit 0; }
[ -n "${GH_TOKEN:-}" ] || { log_warn "budget notifier has no GitHub token"; exit 0; }

case "$provider" in openrouter|openai|anthropic) ;; *) provider=unknown ;; esac
case "$state" in ok|warning|blocked|unknown) ;; *) log_warn "unknown budget state"; exit 0 ;; esac

prefix="[Billing] $provider budget"
current_title="$prefix $state"
run_url="${GITHUB_SERVER_URL:-https://github.com}/$repo/actions/runs/${GITHUB_RUN_ID:-0}"
task_id="${TASK_ID:-n/a}"
available="${BUDGET_AVAILABLE_USD:-}"
floor="${BUDGET_HARD_FLOOR_USD:-}"
reserve="${BUDGET_REQUIRED_JOB_RESERVE_USD:-}"
alerts_file="${RUNNER_TEMP:-/tmp}/budget-alerts-$$.tsv"
trap 'rm -f "$alerts_file"' EXIT

list_alerts() {
  gh issue list --repo "$repo" --state open --limit 100 --json number,title 2>/dev/null \
    | jq -r --arg prefix "$prefix" '.[] | select(.title | startswith($prefix)) | [.number,.title] | @tsv'
}
list_alerts > "$alerts_file" 2>/dev/null || : > "$alerts_file"

if [ "$state" = ok ]; then
  closed=0
  while IFS=$'\t' read -r number title; do
    [ -n "$number" ] || continue
    gh issue close "$number" --repo "$repo" --comment "✅ Budget recovered above the configured runnable threshold. Run: $run_url" >/dev/null 2>&1 || true
    closed=1
  done < "$alerts_file"
  if [ "$closed" -eq 1 ] && [ "${BILLING_ALERT_RECOVERY_EMAIL:-false}" = true ]; then
    BILLING_EMAIL_DRY_RUN="${BILLING_EMAIL_DRY_RUN:-false}" \
    BUDGET_STATE=recovered BUDGET_PROVIDER="$provider" BUDGET_AVAILABLE_USD="$available" \
    BUDGET_HARD_FLOOR_USD="$floor" BUDGET_REQUIRED_JOB_RESERVE_USD="$reserve" \
    TASK_ID="$task_id" RUN_URL="$run_url" BILLING_ALERT_URL="$run_url" \
      python3 "$SCRIPT_DIR/send-billing-alert.py" || log_warn "$CAT_BILLING_ALERT_FAILED recovery email failed"
  fi
  exit 0
fi

current_number=""
while IFS=$'\t' read -r number title; do
  [ -n "$number" ] || continue
  if [ "$title" = "$current_title" ]; then
    current_number="$number"
  else
    gh issue close "$number" --repo "$repo" --comment "Budget state changed to $state. Superseded by the current alert." >/dev/null 2>&1 || true
  fi
done < "$alerts_file"

if [ -n "$current_number" ]; then
  log_info "budget alert already open for $provider/$state; email deduplicated"
  exit 0
fi

body="Provider budget control entered **$state**.

- Provider: \`$provider\`
- Observed available/budget USD: \`${available:-unknown}\`
- Protected hard floor USD: \`${floor:-unknown}\`
- Required per-job reserve USD: \`${reserve:-unknown}\`
- Task ID: \`$task_id\`
- Workflow run: $run_url

Phase A starts paid inference only when the protected floor remains intact and the full configured per-job reserve is available above it. Paid inference is not started when the state is blocked or unknown. This issue is also the deduplication record for billing email notifications. Do not paste credentials or prompts here."

alert_url="$(gh issue create --repo "$repo" --title "$current_title" --body "$body" 2>/dev/null || true)"
if [ -z "$alert_url" ]; then
  log_warn "$CAT_BILLING_ALERT_FAILED could not create GitHub billing alert"
  alert_url="$run_url"
fi

BUDGET_PROVIDER="$provider" BUDGET_STATE="$state" BUDGET_AVAILABLE_USD="$available" \
BUDGET_HARD_FLOOR_USD="$floor" BUDGET_REQUIRED_JOB_RESERVE_USD="$reserve" \
TASK_ID="$task_id" RUN_URL="$run_url" BILLING_ALERT_URL="$alert_url" \
  python3 "$SCRIPT_DIR/send-billing-alert.py" || {
    log_warn "$CAT_BILLING_ALERT_FAILED billing email failed"
    if printf '%s' "$alert_url" | grep -q '/issues/[0-9][0-9]*$'; then
      alert_number="${alert_url##*/}"
      gh issue comment "$alert_number" --repo "$repo" --body "⚠️ \`$CAT_BILLING_ALERT_FAILED\`: billing email delivery failed. GitHub alert remains authoritative." >/dev/null 2>&1 || true
    fi
  }
