#!/usr/bin/env bash
# Non-mutating target inspection used by dry-run mode. Run from the target
# checkout working directory after the target identity guard passes.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/repo.sh"

TASK_FILE="${TASK_FILE:-$RUNNER_TEMP/task.json}"
repo="$(canonicalize_repo "$(jq -r '.target_repository // ""' "$TASK_FILE")")"

[ -z "$(git status --porcelain)" ] || fail_with "$CAT_DIRTY_TREE" "target checkout is unexpectedly dirty"

default_branch="$(detect_default_branch "$repo")"
if [ -z "$default_branch" ]; then
  fail_with "$CAT_TARGET_DEFAULT_BRANCH" "could not determine target default branch"
fi

# Build the exact prompt that a live agent run would receive, but do not start
# the agent, create a branch, push, or create a PR.
"$SCRIPT_DIR/build-agent-prompt.sh" || fail_with "$CAT_AGENT_START" "prompt build failed"

{
  echo "result=pass"
  echo "default_branch=$default_branch"
} >> "${GITHUB_OUTPUT:-/dev/null}"
summary "| dry run | true |"
summary "| target default branch | \`$default_branch\` |"
summary "| mutations | none |"
log_info "dry-run target inspection PASS (repo=$repo default_branch=$default_branch)"
