#!/usr/bin/env bash
# Validate the configured executor labels before reserving or dispatching a
# review. Missing/invalid configuration must never fall back to a hosted runner.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

labels="${REVIEW_REPAIR_RUNNER_LABELS:-}"
[ -n "$labels" ] \
  || fail_with "$CAT_REPAIR_EXECUTOR_UNAVAILABLE" "REVIEW_REPAIR_RUNNER_LABELS is not configured"

if ! jq -e '
  type == "array" and
  length >= 2 and length <= 8 and
  all(.[]; type == "string" and test("^[A-Za-z0-9._-]+$")) and
  any(.[]; ascii_downcase == "self-hosted") and
  any(.[]; ascii_downcase == "review-repair")
' >/dev/null 2>&1 <<<"$labels"; then
  fail_with "$CAT_REPAIR_EXECUTOR_UNAVAILABLE" \
    "runner labels must be a JSON array containing self-hosted and review-repair"
fi

echo "result=pass" >> "${GITHUB_OUTPUT:-/dev/null}"
summary "| review executor | configured self-hosted labels |"
log_info "review executor configuration: PASS"
