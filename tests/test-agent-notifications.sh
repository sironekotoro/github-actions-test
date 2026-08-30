#!/usr/bin/env bash
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
pass=0
fail=0
ok() { echo "PASS: $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1"; fail=$((fail + 1)); }
check() { if "$@"; then ok "$*"; else bad "$*"; fi; }

export RUNNER_TEMP="$TMP"
export GITHUB_STEP_SUMMARY="$TMP/summary.md"

out="$TMP/disabled.out"
NOTIFICATION_EVENT=TASK_COMPLETED \
NOTIFICATION_TASK_ID=test-task \
NOTIFICATION_TARGET_REPOSITORY=sironekotoro/github-actions-test \
NOTIFICATION_REASON=none \
NOTIFICATION_RUN_URL=https://github.com/example/run \
NOTIFICATION_TITLE='test complete' \
AGENT_NOTIFICATION_EMAIL_ENABLED=false \
AGENT_NOTIFICATION_SLACK_ENABLED=false \
bash "$ROOT/scripts/deliver-agent-notification.sh" >"$out" 2>&1
[ $? -eq 0 ] && ok 'disabled external channels are a successful no-op' || bad 'disabled external channels are a successful no-op'
grep -q 'processed lifecycle notification event=TASK_COMPLETED' "$out" && ok 'completion event is classified' || bad 'completion event is classified'

secret='smtp-super-secret-value'
email_out="$TMP/email.out"
AGENT_NOTIFICATION_EMAIL_ENABLED=true \
AGENT_NOTIFICATION_EMAIL_DRY_RUN=true \
AGENT_NOTIFICATION_EMAIL_TO=owner@example.invalid \
BILLING_SMTP_HOST=smtp.example.invalid \
BILLING_SMTP_PORT=587 \
BILLING_SMTP_FROM=agent@example.invalid \
BILLING_SMTP_USER=test-user \
BILLING_SMTP_PASSWORD="$secret" \
NOTIFICATION_EVENT=ACTION_REQUIRED \
NOTIFICATION_TASK_ID=test-task \
NOTIFICATION_TARGET_REPOSITORY=sironekotoro/github-actions-test \
NOTIFICATION_REASON=RUNNER_UNAVAILABLE \
NOTIFICATION_RUN_URL=https://github.com/example/run \
NOTIFICATION_TITLE='attention required' \
python3 "$ROOT/scripts/send-agent-notification.py" >"$email_out" 2>&1
[ $? -eq 0 ] && ok 'email notifier supports network-free dry-run' || bad 'email notifier supports network-free dry-run'
! grep -Fq "$secret" "$email_out" && ok 'SMTP password is never logged' || bad 'SMTP password is never logged'

slack_secret='https://hooks.example.invalid/services/secret-value'
slack_out="$TMP/slack.out"
AGENT_NOTIFICATION_EMAIL_ENABLED=false \
AGENT_NOTIFICATION_SLACK_ENABLED=true \
AGENT_NOTIFICATION_SLACK_DRY_RUN=true \
AGENT_NOTIFICATION_SLACK_WEBHOOK_URL="$slack_secret" \
NOTIFICATION_EVENT=TASK_FAILED \
NOTIFICATION_TASK_ID=test-task \
NOTIFICATION_TARGET_REPOSITORY=sironekotoro/github-actions-test \
NOTIFICATION_REASON=TEST_FAILED \
NOTIFICATION_RUN_URL=https://github.com/example/run \
NOTIFICATION_TITLE='test failed' \
bash "$ROOT/scripts/deliver-agent-notification.sh" >"$slack_out" 2>&1
[ $? -eq 0 ] && ok 'Slack notifier supports network-free dry-run' || bad 'Slack notifier supports network-free dry-run'
! grep -Fq "$slack_secret" "$slack_out" && ok 'Slack webhook is never logged' || bad 'Slack webhook is never logged'

workflow="$ROOT/.github/workflows/agent-notification.yml"
grep -q '^  workflow_run:' "$workflow" && ok 'gateway is event-driven by workflow_run' || bad 'gateway is event-driven by workflow_run'
! grep -qE '^  (schedule|issue_comment|repository_dispatch):' "$workflow" && ok 'gateway does not poll or depend on token-created comments' || bad 'gateway does not poll or depend on token-created comments'
grep -q 'actions: read' "$workflow" && ok 'gateway uses read-only Actions inspection' || bad 'gateway uses read-only Actions inspection'
grep -q 'Agent Dispatch' "$workflow" && grep -q 'Agent Review Repair Dispatcher' "$workflow" && grep -q 'Agent Review Repair Executor' "$workflow" && ok 'all production agent workflows are watched' || bad 'all production agent workflows are watched'
grep -q 'Notification state TASK_COMPLETED' "$ROOT/.github/workflows/agent-dispatch.yml" && ok 'ordinary dispatch exposes completion marker' || bad 'ordinary dispatch exposes completion marker'
grep -q 'Notification state ACTION_REQUIRED' "$ROOT/.github/workflows/agent-dispatch.yml" && ok 'ordinary dispatch exposes action-required marker' || bad 'ordinary dispatch exposes action-required marker'
grep -q 'Notification state ACTION_REQUIRED' "$ROOT/.github/workflows/review-repair.yml" && ok 'review dispatcher exposes action-required marker' || bad 'review dispatcher exposes action-required marker'
grep -q 'Notification state TASK_COMPLETED' "$ROOT/.github/workflows/review-repair-executor.yml" && ok 'review executor exposes completion marker' || bad 'review executor exposes completion marker'

if grep -q 'AGENT_NOTIFICATION_SLACK_WEBHOOK_URL\|AGENT_NOTIFICATION_EMAIL_ENABLED' "$ROOT/.github/workflows/agent-dispatch.yml" "$ROOT/.github/workflows/review-repair.yml" "$ROOT/.github/workflows/review-repair-executor.yml"; then
  bad 'notification credentials stay out of source agent workflows'
else
  ok 'notification credentials stay out of source agent workflows'
fi

printf '%s\n' '----'
printf 'PASS=%d FAIL=%d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
