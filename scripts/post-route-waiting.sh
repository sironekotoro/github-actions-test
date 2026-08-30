#!/usr/bin/env bash
# Record a non-failing control-plane defer decision for ordinary Agent Dispatch.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

reason="${WAIT_REASON:-}"
decision="${ROUTE_DECISION:-}"
repo="${GITHUB_REPOSITORY:-}"
issue_number="${ISSUE_NUMBER:-}"
run_url="${GITHUB_SERVER_URL:-https://github.com}/$repo/actions/runs/${GITHUB_RUN_ID:-0}"

case "$decision" in
  wait-budget) label="agent:waiting-budget"; message="Paid inference was deferred by the provider budget gate." ;;
  wait-runner) label="agent:waiting-runner"; message="Agent execution was deferred because no compatible self-hosted runner is currently available." ;;
  *) exit 0 ;;
esac

summary "### Agent routing deferred"
summary "| field | value |"
summary "|-------|-------|"
summary "| Decision | $decision |"
summary "| Reason | ${reason:-unknown} |"
summary "| Run | [$run_url]($run_url) |"

[ -n "$issue_number" ] || exit 0
[ -n "${GH_TOKEN:-}" ] || { log_warn "waiting feedback has no GitHub token"; exit 0; }

body="⏸️ Agent task deferred; no paid model inference was started.
- Reason: \`${reason:-unknown}\`
- Run: $run_url
- Resume: correct the budget/runner condition, then add \`agent:ready\` again."

gh issue comment "$issue_number" --repo "$repo" --body "$body" >/dev/null 2>&1 \
  || log_warn "could not post waiting feedback to issue #$issue_number"

gh issue edit "$issue_number" --repo "$repo" --remove-label 'agent:ready' >/dev/null 2>&1 || true
gh issue edit "$issue_number" --repo "$repo" --remove-label 'opencode-run' >/dev/null 2>&1 || true
gh issue edit "$issue_number" --repo "$repo" --add-label "$label" >/dev/null 2>&1 \
  || log_warn "could not apply waiting label $label"
