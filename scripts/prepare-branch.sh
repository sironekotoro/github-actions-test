#!/usr/bin/env bash
# Branch preparation: dirty-tree check, duplicate guard, default branch,
# and creation of agent/<task_id>. Works for same-repo and a separately
# checked-out cross-repo target, depending on the current working directory.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/repo.sh"

TASK_FILE="${TASK_FILE:-$RUNNER_TEMP/task.json}"
task_id="$(jq -r '.task_id' "$TASK_FILE")"
repo="$(canonicalize_repo "$(jq -r '.target_repository' "$TASK_FILE")")"
mode="${DISPATCH_MODE:-same}"

if [ -n "$(git status --porcelain)" ]; then
  log_error "working tree is not clean:"
  git status --porcelain | head -20
  fail_with "$CAT_DIRTY_TREE" "working tree has unexpected changes"
fi

branch="agent/${task_id}"
if branch_exists_remote "$branch"; then
  fail_with "$CAT_ALREADY_RUNNING" "branch $branch already exists"
fi
if open_pr_for_branch "$branch"; then
  fail_with "$CAT_ALREADY_RUNNING" "open PR already exists for $branch"
fi

default_branch="$(detect_default_branch "$repo")"
if [ -z "$default_branch" ]; then
  [ "$mode" = cross ] \
    && fail_with "$CAT_TARGET_DEFAULT_BRANCH" "cannot determine target default branch" \
    || fail_with "$CAT_CHECKOUT" "cannot determine default branch"
fi
log_info "default branch: $default_branch"

if git show-ref --verify --quiet "refs/heads/$default_branch"; then
  git checkout -q "$default_branch"
elif git show-ref --verify --quiet "refs/remotes/origin/$default_branch"; then
  git checkout -q -B "$default_branch" "origin/$default_branch"
else
  [ "$mode" = cross ] \
    && fail_with "$CAT_TARGET_DEFAULT_BRANCH" "cannot find target default branch $default_branch" \
    || fail_with "$CAT_CHECKOUT" "cannot find default branch $default_branch"
fi

git checkout -q -b "$branch" || {
  [ "$mode" = cross ] \
    && fail_with "$CAT_TARGET_CHECKOUT" "could not create target branch $branch" \
    || fail_with "$CAT_CHECKOUT" "could not create branch $branch"
}

{
  echo "branch=$branch"
  echo "default_branch=$default_branch"
  echo "result=pass"
} >> "${GITHUB_OUTPUT:-/dev/null}"
summary "| agent branch | \`$branch\` |"
summary "| default branch | \`$default_branch\` |"
