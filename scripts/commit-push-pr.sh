#!/usr/bin/env bash
# Run repository tests, then commit, push and create a PR for the agent's
# changes on the target repository. Works in same-repo and cross-repo modes.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/repo.sh"

TASK_FILE="${TASK_FILE:-$RUNNER_TEMP/task.json}"
task_id="$(jq -r '.task_id' "$TASK_FILE")"
title="$(jq -r '.title' "$TASK_FILE")"
source_label="$(jq -r '.source' "$TASK_FILE")"
model="$(jq -r '.requested_model // ""' "$TASK_FILE")"
[ -z "$model" ] && model="${OPENROUTER_MODEL:-openrouter/deepseek/deepseek-v4-flash}"
branch="$(git branch --show-current)"
default_branch="${DEFAULT_BRANCH:-master}"
repo="$(canonicalize_repo "$(jq -r '.target_repository' "$TASK_FILE")")"
dispatcher_repo="${DISPATCHER_REPOSITORY:-${GITHUB_REPOSITORY:-$repo}}"
mode="${DISPATCH_MODE:-same}"
run_url="${GITHUB_SERVER_URL:-https://github.com}/${dispatcher_repo}/actions/runs/${GITHUB_RUN_ID:-0}"

if [ "$(jq -r '.dry_run // false' "$TASK_FILE")" = true ]; then
  log_info "dry_run=true; skipping tests/commit/push/PR"
  summary "| commit / push / PR | skipped (dry run) |"
  echo "result=pass" >> "${GITHUB_OUTPUT:-/dev/null}"
  exit 0
fi

if [ -f package.json ] && [ "${AGENT_TESTS_ALREADY_RAN:-false}" != "true" ]; then
  log_info "running repository tests"
  if ! npm test >"$RUNNER_TEMP/npm-test.log" 2>&1; then
    log_error "FAILURE_CATEGORY=$CAT_TEST repository tests failed"
    tail -n 40 "$RUNNER_TEMP/npm-test.log" >&2
    set_failure "$CAT_TEST"
    exit 1
  fi
  summary "| tests | pass |"
elif [ -f package.json ]; then
  # Self-hosted dispatch runs untrusted repository tests inside its isolated
  # container. Do not re-execute target code in the trusted outer executor.
  summary "| tests | pass (isolated agent container) |"
else
  summary "| tests | none (no package.json) |"
fi

if [ -z "$(git status --porcelain)" ]; then
  log_warn "no changes to commit; skipping push/PR"
  summary "| commit | none (no changes) |"
  echo "result=pass" >> "${GITHUB_OUTPUT:-/dev/null}"
  exit 0
fi

git config user.name  'github-actions[bot]'
git config user.email '41898282+github-actions[bot]@users.noreply.github.com'

# Persist the original task context in the bot-owned PR and bind it to the
# initial agent commit with a SHA-256 trailer. Review repair will reject a PR
# unless the PR author, metadata, target, branch, and commit trailer agree.
writer_login="${DISPATCH_PRINCIPAL:-github-actions[bot]}"
if [ -z "$writer_login" ]; then
  if [ "$mode" = cross ]; then
    fail_with "$CAT_TARGET_PR" "target-scoped token principal is missing"
  else
    fail_with "$CAT_PR" "workflow token principal is missing"
  fi
fi
printf '%s' "$writer_login" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9-]*\[bot\]$' \
  || fail_with "$CAT_PR" "dispatcher principal must be a GitHub bot login"
metadata_file="$RUNNER_TEMP/agent-task-metadata.json"
jq -cS \
  --arg dispatcher_repository "$(canonicalize_repo "$dispatcher_repo")" \
  --arg writer_login "$writer_login" \
  '{schema:"agent-dispatch-task/v1", task_id, target_repository, source,
    title, prompt, created_at, requested_model, max_runtime, dry_run,
    dispatcher_repository:$dispatcher_repository, writer_login:$writer_login}' \
  "$TASK_FILE" > "$metadata_file" \
  || fail_with "$CAT_INVALID_PAYLOAD" "could not serialize agent task metadata"
metadata_sha="$(sha256_of "$metadata_file")"
metadata_b64="$(node -e 'const fs=require("fs"); process.stdout.write(fs.readFileSync(process.argv[1]).toString("base64"))' "$metadata_file")"

git add -A
if ! git diff --cached --check >"$RUNNER_TEMP/git-check.log" 2>&1; then
  tail -n 20 "$RUNNER_TEMP/git-check.log" >&2
  set_failure "$CAT_TEST"
  exit 1
fi

git commit -m "AI: ${title}" \
  -m "Agent-Task-Metadata-SHA256: $metadata_sha" \
  -m "Agent-Task-ID: $task_id" \
  -m "Agent-Target-Repository: $repo" >/dev/null 2>&1 || {
  [ "$mode" = cross ] && fail_with "$CAT_TARGET_PUSH" "git commit failed" || fail_with "$CAT_PUSH" "git commit failed"
}
commit_sha="$(git rev-parse HEAD)"
summary "| commit | \`$commit_sha\` |"

if ! git push --set-upstream origin "$branch" >"$RUNNER_TEMP/push.log" 2>&1; then
  tail -n 20 "$RUNNER_TEMP/push.log" >&2
  [ "$mode" = cross ] && set_failure "$CAT_TARGET_PUSH" || set_failure "$CAT_PUSH"
  exit 1
fi
log_info "pushed $branch to $repo"

existing_pr="$(gh pr list --repo "$repo" --head "$branch" --state open --json number --jq '.[0].number' 2>/dev/null || true)"
if [ -n "$existing_pr" ]; then
  pr_url="${GITHUB_SERVER_URL:-https://github.com}/${repo}/pull/${existing_pr}"
  summary "| PR | [#$existing_pr]($pr_url) |"
  echo "pr_number=$existing_pr" >> "${GITHUB_OUTPUT:-/dev/null}"
  echo "pr_url=$pr_url" >> "${GITHUB_OUTPUT:-/dev/null}"
  echo "result=pass" >> "${GITHUB_OUTPUT:-/dev/null}"
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
  "| Dispatcher run | $run_url |" \
  "| Dispatcher principal | \`$writer_login\` |" \
  "" \
  "- Tests: pass" \
  "- \`git diff --check\`: pass" \
  "" \
  "<!-- agent-dispatch-task:v1:$metadata_b64 -->")"

if gh pr create --repo "$repo" --base "$default_branch" --head "$branch" \
  --title "AI: ${title}" --body "$pr_body" >"$RUNNER_TEMP/pr-create.log" 2>&1; then
  pr_url="$(tail -n 1 "$RUNNER_TEMP/pr-create.log")"
  pr_number="$(printf '%s' "$pr_url" | sed -E 's#.*/pull/([0-9]+)/?$#\1#')"
  [ -z "$pr_number" ] && pr_number="$(gh pr view --repo "$repo" "$branch" --json number --jq '.number' 2>/dev/null || true)"
  log_info "PR created: $pr_url"
  summary "| PR | [$pr_url]($pr_url) |"
  echo "pr_number=$pr_number" >> "${GITHUB_OUTPUT:-/dev/null}"
  echo "pr_url=$pr_url" >> "${GITHUB_OUTPUT:-/dev/null}"
  echo "result=pass" >> "${GITHUB_OUTPUT:-/dev/null}"
else
  tail -n 20 "$RUNNER_TEMP/pr-create.log" >&2
  [ "$mode" = cross ] && set_failure "$CAT_TARGET_PR" || set_failure "$CAT_PR"
  exit 1
fi
