#!/usr/bin/env bash
# Preflight only: verify that the GitHub App credentials required for a
# cross-repository installation token are configured. Never prints values.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

APP_ID="${GH_APP_ID:-}"
APP_KEY="${GH_APP_PRIVATE_KEY:-}"

if [ -z "$APP_ID" ] || [ -z "$APP_KEY" ]; then
  log_error "GitHub App credentials are not configured"
  log_error "LIVE_CROSS_REPO_E2E_BLOCKED_BY_APP_SETUP"
  fail_with "$CAT_CROSS_REPO_AUTH_UNAVAILABLE" "required GitHub App secrets are absent"
fi

# Only metadata about presence is emitted; never secret values.
echo "result=pass" >> "${GITHUB_OUTPUT:-/dev/null}"
summary "| cross-repo auth preflight | configured |"
log_info "GitHub App credential presence check: PASS"
