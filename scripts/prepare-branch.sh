#!/usr/bin/env bash
# Branch preparation: dirty-tree check, duplicate guard, default branch,
# and creation of agent/<task_id>.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/repo.sh
source "$SCRIPT_DIR/lib/repo.sh"

TASK_FILE="${TASK_FILE:-$RUNNER_TEMP/task.json}"
task_id="$(jq -r '.task_id' "$TASK_FILE")"
repo="$(jq -r '.target_repository' "$TASK_FILE")"

# --- dirty working tree safety ---
if [ -n "$(git status --porcelain)" ]; then
  log_error "working tree is not clean:"
  git status --porcelain | head -20
  fail_with "$CAT_DIRTY_TREE" "working tree has unexpected changes"
fi

# --- duplicate execution guard ---
branch="agent/${task_id}"
if branch_exists_remote "$branch"; then
  log_error "branch $branch already exists on origin; duplicate execution blocked"
  fail_with "$CAT_ALREADY_RUNNING" "branch $branch already exists"
fi
if open_pr_for_branch "$branch"; then
  log_error "an open PR for $branch already exists; duplicate execution blocked"
  fail_with "$CAT_ALREADY_RUNNING" "open PR already exists for $branch"
fi

# --- default branch detection ---
default_branch="$(detect_default_branch "$repo")"
log_info "default branch: $default_branch"

if git show-ref --verify --quiet "refs/heads/$default_branch"; then
  git checkout -q "$default_branch"
else
  git checkout -q -B "$default_branch" "origin/$default_branch" 2>/dev/null \
    || git checkout -q -B "$default_branch" "origin/master" 2>/dev/null \
    || fail_with "$CAT_CHECKOUT" "cannot find default branch $default_branch"
fi

# --- create the agent branch ---
git checkout -q -b "$branch" || fail_with "$CAT_CHECKOUT" "could not create branch $branch"

echo "branch=$branch" >> "${GITHUB_OUTPUT:-/dev/null}"
echo "default_branch=$default_branch" >> "${GITHUB_OUTPUT:-/dev/null}"
summary "| agent branch | \`$branch\` |"
summary "| default branch | \`$default_branch\` |"