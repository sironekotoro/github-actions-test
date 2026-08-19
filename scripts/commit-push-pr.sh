#!/usr/bin/env bash
# Run repository tests, then commit, push and create a PR for the agent's
# changes on the agent/<task_id> branch.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

TASK_FILE="${TASK_FILE:-$RUNNER_TEMP/task.json}"
task_id="$(jq -r '.task_id' "$TASK_FILE")"
title="$(jq -r '.title' "$TASK_FILE")"
source_label="$(jq -r '.source' "$TASK_FILE")"
model="$(jq -r '.requested_model // ""' "$TASK_FILE")"
[ -z "$model" ] && model="${OPENROUTER_MODEL:-openrouter/deepseek/deepseek-v4-flash}"
branch="$(git branch --show-current)"
default_branch="${DEFAULT_BRANCH:-master}"
repo="${GITHUB_REPOSITORY:-}"
run_url="${GITHUB_SERVER_URL:-https://github.com}/${repo}/actions/runs/${GITHUB_RUN_ID:-0}"

# --- tests ---
if [ -f package.json ]; then
  log_info "running repository tests"
  if ! npm test >"$RUNNER_TEMP/npm-test.log" 2>&1; then
    log_error "FAILURE_CATEGORY=$CAT_TEST repository tests failed"
    tail -n 40 "$RUNNER_TEMP/npm-test.log" >&2
    set_failure "$CAT_TEST"
    exit 1
  fi
  summary "| tests | pass |"
else
  summary "| tests | none (no package.json) |"
fi

# --- commit ---
if [ -z "$(git status --porcelain)" ]; then
  log_warn "no changes to commit; skipping push/PR"
  summary "| commit | none (no changes) |"
  exit 0
fi

git config user.name  'github-actions[bot]'
git config user.email '41898282+github-actions[bot]@users.noreply.github.com'

git add -A
if ! git diff --cached --check >"$RUNNER_TEMP/git-check.log" 2>&1; then
  log_error "git diff --check failed"
  tail -n 20 "$RUNNER_TEMP/git-check.log" >&2
  set_failure "$CAT_TEST"
  exit 1
fi

commit_msg="AI: ${title}"
git commit -m "$commit_msg" >/dev/null 2>&1 \
  || fail_with "$CAT_PUSH" "git commit failed"
commit_sha="$(git rev-parse HEAD)"

summary "| commit | \`$commit_sha\` |"

# --- push ---
if ! git push --set-upstream origin "$branch" >"$RUNNER_TEMP/push.log" 2>&1; then
  log_error "FAILURE_CATEGORY=$CAT_PUSH push failed"
  tail -n 20 "$RUNNER_TEMP/push.log" >&2
  set_failure "$CAT_PUSH"
  exit 1
fi
log_info "pushed $branch"

# --- PR ---
existing_pr="$(gh pr list --head "$branch" --state open --json number --jq '.[0].number' 2>/dev/null || true)"
if [ -n "$existing_pr" ]; then
  log_info "PR #$existing_pr already exists for $branch"
  summary "| PR | [#$existing_pr](${GITHUB_SERVER_URL}/${repo}/pull/$existing_pr) |"
  echo "pr_number=$existing_pr" >> "${GITHUB_OUTPUT:-/dev/null}"
  exit 0
fi

pr_body="$(printf '%s\n' \
  "Automated agent implementation." \
  "" \
  "| field | value |" \
  "|-------|-------|" \
  "| Agent task ID | \`$task_id\` |" \
  "| Target repository | \`$repo\` |" \
  "| Source | $source_label |" \
  "| Model | \`$model\` |" \
  "| Branch | \`$branch\` |" \
  "| Run | $run_url |" \
  "" \
  "- Tests: pass" \
  "- \`git diff --check\`: pass")"

if gh pr create \
  --base "$default_branch" \
  --head "$branch" \
  --title "AI: ${title}" \
  --body "$pr_body" >"$RUNNER_TEMP/pr-create.log" 2>&1; then
  pr_url="$(tail -n 1 "$RUNNER_TEMP/pr-create.log")"
  pr_number="$(printf '%s' "$pr_url" | sed -E 's#.*/pull/([0-9]+)/?$#\1#')"
  [ -z "$pr_number" ] && pr_number="$(gh pr view "$branch" --json number --jq '.number' 2>/dev/null || true)"
  log_info "PR created: $pr_url"
  summary "| PR | [$pr_url]($pr_url) |"
  echo "pr_number=$pr_number" >> "${GITHUB_OUTPUT:-/dev/null}"
  echo "pr_url=$pr_url" >> "${GITHUB_OUTPUT:-/dev/null}"
else
  log_error "FAILURE_CATEGORY=$CAT_PR PR creation failed"
  tail -n 20 "$RUNNER_TEMP/pr-create.log" >&2
  set_failure "$CAT_PR"
  exit 1
fi