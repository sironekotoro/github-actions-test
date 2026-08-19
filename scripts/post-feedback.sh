#!/usr/bin/env bash
# Post feedback to the originating issue and finalize the step summary.
# Never includes prompt contents or secrets; only metadata.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

TASK_FILE="${TASK_FILE:-$RUNNER_TEMP/task.json}"
repo="${GITHUB_REPOSITORY:-}"
run_url="${GITHUB_SERVER_URL:-https://github.com}/${repo}/actions/runs/${GITHUB_RUN_ID:-0}"
issue_number="${ISSUE_NUMBER:-}"
branch="${AGENT_BRANCH:-}"
pr_url="${PR_URL:-}"
pr_number="${PR_NUMBER:-}"

category="$(get_failure)"
[ -n "$category" ] || category=""

summary "### Run report"
summary "| field | value |"
summary "|-------|-------|"
summary "| Task ID | $(jq -r '.task_id' "$TASK_FILE") |"
summary "| Target repository | $(jq -r '.target_repository' "$TASK_FILE") |"
summary "| Actual repository | \`$repo\` |"
summary "| Branch | \`${branch:-n/a}\` |"
summary "| Run | [$run_url]($run_url) |"
summary "| Failure category | ${category:-none} |"
[ -n "$pr_number" ] && summary "| PR | #$pr_number |"
summary ""

if [ -n "$issue_number" ]; then
  if [ -z "$category" ]; then
    body="✅ Agent task completed.
- Run: $run_url
- Branch: \`${branch:-n/a}\`
${pr_url:+- PR: $pr_url}"
  else
    body="❌ Agent task failed.
- Run: $run_url
- Failure category: \`$category\`"
  fi
  gh issue comment "$issue_number" --repo "$repo" --body "$body" >/dev/null 2>&1 \
    || log_warn "could not post comment on issue #$issue_number"
  log_info "posted feedback to issue #$issue_number (category=${category:-none})"
fi