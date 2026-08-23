#!/usr/bin/env bash
# Validate the existing self-hosted Mac runner label set before selecting it
# for an ordinary Agent Dispatch. There is deliberately no hosted fallback.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

labels="${AGENT_DISPATCH_RUNNER_LABELS:-}"
[ -n "$labels" ] \
  || fail_with "$CAT_AGENT_EXECUTOR_UNAVAILABLE" "self-hosted runner labels are not configured"

if ! jq -e '
  type == "array" and
  length >= 2 and length <= 8 and
  all(.[]; type == "string" and test("^[A-Za-z0-9._-]+$")) and
  any(.[]; ascii_downcase == "self-hosted") and
  any(.[]; ascii_downcase == "review-repair")
' >/dev/null 2>&1 <<<"$labels"; then
  fail_with "$CAT_AGENT_EXECUTOR_UNAVAILABLE" \
    "runner labels must be a JSON array containing self-hosted and review-repair"
fi

echo "result=pass" >> "${GITHUB_OUTPUT:-/dev/null}"
summary "| Agent Dispatch executor | configured self-hosted Mac labels |"
log_info "Agent Dispatch self-hosted runner configuration: PASS"
