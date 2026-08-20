#!/usr/bin/env bash
# Resume only the already-existing, validated PR head branch. This path is
# intentionally separate from prepare-branch.sh and never weakens its duplicate
# branch/open-PR guard.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/repo.sh"

TASK_FILE="${TASK_FILE:-$RUNNER_TEMP/task.json}"
repo="$(canonicalize_repo "$(jq -r '.target_repository' "$TASK_FILE")")"
branch="$(jq -r '.review.head_branch' "$TASK_FILE")"
expected_sha="$(jq -r '.review.head_sha' "$TASK_FILE")"
base_branch="$(jq -r '.review.base_branch' "$TASK_FILE")"
metadata_sha="$(jq -r '.metadata_sha256' "$TASK_FILE")"
review_id="$(jq -r '.review.id // ""' "$TASK_FILE")"
attempts_used="$(jq -r '.review.attempts_used // ((.review.attempt // 1) - 1)' "$TASK_FILE")"
target_token="${TARGET_GH_TOKEN:-}"

git_target() {
  if [ -n "$target_token" ]; then
    local basic
    basic="$(printf 'x-access-token:%s' "$target_token" | base64 | tr -d '\n')"
    git -c "http.https://github.com/.extraheader=AUTHORIZATION: basic $basic" "$@"
  else
    git "$@"
  fi
}

[ -z "$(git status --porcelain)" ] || fail_with "$CAT_DIRTY_TREE" "review target checkout is unexpectedly dirty"
case "$branch" in
  agent/*) ;;
  *) fail_with "$CAT_REPAIR_BRANCH" "review branch is outside agent/*" ;;
esac

default_branch="$(detect_default_branch "$repo")"
[ -n "$default_branch" ] || fail_with "$CAT_TARGET_DEFAULT_BRANCH" "could not detect target default branch"
[ "$base_branch" = "$default_branch" ] \
  || fail_with "$CAT_REPAIR_BRANCH" "PR base is not the target default branch"

remote_sha="$(git_target ls-remote --heads origin "refs/heads/$branch" | awk 'NR == 1 {print $1}')"
[ -n "$remote_sha" ] || fail_with "$CAT_REPAIR_BRANCH" "validated PR branch no longer exists"
[ "$remote_sha" = "$expected_sha" ] \
  || fail_with "$CAT_REPAIR_BRANCH" "PR head changed after review validation"

git_target fetch -q origin "refs/heads/$branch:refs/remotes/origin/$branch" \
  || fail_with "$CAT_REPAIR_BRANCH" "could not fetch validated PR branch"
git checkout -q -B "$branch" "refs/remotes/origin/$branch" \
  || fail_with "$CAT_REPAIR_BRANCH" "could not resume validated PR branch"
[ "$(git rev-parse HEAD)" = "$expected_sha" ] \
  || fail_with "$CAT_REPAIR_BRANCH" "checked-out head does not match reviewed head"

base_ref="$default_branch"
if ! git show-ref --verify --quiet "refs/heads/$default_branch"; then
  base_ref="refs/remotes/origin/$default_branch"
fi
git rev-parse --verify "$base_ref" >/dev/null 2>&1 \
  || fail_with "$CAT_REPAIR_BRANCH" "target default branch ref is unavailable"
if ! git log --format='%B' "$base_ref..HEAD" | grep -Fx "Agent-Task-Metadata-SHA256: $metadata_sha" >/dev/null; then
  fail_with "$CAT_REPAIR_METADATA" "task metadata is not bound to the agent branch history"
fi
if [ -n "$review_id" ] && git log --format='%B' "$base_ref..HEAD" | grep -Fx "Agent-Repair-Review-ID: $review_id" >/dev/null; then
  fail_with "$CAT_REPAIR_STATE" "review id is already present in branch history"
fi
commit_repairs="$(git log --format='%B' "$base_ref..HEAD" | grep -c '^Agent-Repair-Review-ID: ' || true)"
if [ "$commit_repairs" -gt "$attempts_used" ]; then
  fail_with "$CAT_REPAIR_STATE" "PR repair markers are missing relative to branch history"
fi

{
  echo "result=pass"
  echo "branch=$branch"
  echo "default_branch=$default_branch"
} >> "${GITHUB_OUTPUT:-/dev/null}"
summary "| resumed PR branch | \`$branch\` |"
summary "| reviewed head | \`$expected_sha\` |"
