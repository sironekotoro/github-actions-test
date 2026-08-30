#!/usr/bin/env bash
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/lib/helpers.sh"
TMP="$(make_temp)"
trap 'rm -rf "$TMP"' EXIT

BILLING_EMAIL_ENABLED=false python3 "$ROOT/scripts/send-billing-alert.py" > "$TMP/disabled.out" 2> "$TMP/disabled.err"
t "disabled billing email is a no-op" "0" "$?"

set +e
BILLING_EMAIL_ENABLED=true BILLING_EMAIL_DRY_RUN=true \
  python3 "$ROOT/scripts/send-billing-alert.py" > "$TMP/missing.out" 2> "$TMP/missing.err"
missing_status=$?
set -e
t "enabled email with missing transport config fails closed" "2" "$missing_status"

BILLING_EMAIL_ENABLED=true BILLING_EMAIL_DRY_RUN=true \
BILLING_SMTP_HOST='smtp.example.invalid' BILLING_SMTP_PORT=587 \
BILLING_SMTP_FROM='agent@example.com' BILLING_ALERT_EMAIL_TO='owner@example.com' \
BILLING_SMTP_USER='fixture-user' BILLING_SMTP_PASSWORD='fixture-password-secret' \
BUDGET_PROVIDER=openrouter BUDGET_STATE=blocked BUDGET_AVAILABLE_USD=0.20 \
BUDGET_HARD_FLOOR_USD=0.25 TASK_ID='fixture-task' RUN_URL='https://example.invalid/run' \
BILLING_ALERT_URL='https://example.invalid/issue' \
  python3 "$ROOT/scripts/send-billing-alert.py" > "$TMP/dry.out" 2> "$TMP/dry.err"
t "configured billing email supports network-free dry-run" "0" "$?"
t "dry-run reports blocked subject" "yes" "$(grep -q 'budget blocked' "$TMP/dry.out" && echo yes || echo no)"
combined="$(cat "$TMP/dry.out" "$TMP/dry.err")"
t "SMTP password is never logged" "absent" "$(printf '%s' "$combined" | grep -q 'fixture-password-secret' && echo present || echo absent)"

finish
