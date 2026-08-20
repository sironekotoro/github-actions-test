#!/usr/bin/env bash
# Test, commit, and push a review repair to the same validated PR branch.
# This script deliberately contains no PR create or merge path.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/repo.sh"

TASK_FILE="${TASK_FILE:-$RUNNER_TEMP/task.json}"
title="$(jq -r '.title' "$TASK_FILE")"
branch="$(jq -r '.review.head_branch' "$TASK_FILE")"
review_id="$(jq -r '.review.id' "$TASK_FILE")"
attempt="$(jq -r '.review.attempt' "$TASK_FILE")"
metadata_sha="$(jq -r '.metadata_sha256' "$TASK_FILE")"
expected_sha="$(jq -r '.review.head_sha' "$TASK_FILE")"
mode="${DISPATCH_MODE:-same}"
repo="$(canonicalize_repo "$(jq -r '.target_repository' "$TASK_FILE")")"
push_token="${PUSH_TOKEN:-}"
# Repository tests and commit hooks must not inherit a write credential.
unset PUSH_TOKEN GH_TOKEN TARGET_GH_TOKEN

git_push_target() {
  if [ -n "$push_token" ]; then
    local basic
    basic="$(printf 'x-access-token:%s' "$push_token" | base64 | tr -d '\n')"
    git -c "http.https://github.com/.extraheader=AUTHORIZATION: basic $basic" push "$@"
  else
    git push "$@"
  fi
}

[ "$(git branch --show-current)" = "$branch" ] \
  || fail_with "$CAT_REPAIR_BRANCH" "current branch is not the validated PR branch"
[ "$(git rev-parse HEAD)" = "$expected_sha" ] \
  || fail_with "$CAT_REPAIR_BRANCH" "local branch moved before repair commit"
[ "$(canonicalize_repo "$(repo_remote_url)")" = "$repo" ] \
  || fail_with "$CAT_REPO_MISMATCH" "target remote changed before repair commit"

if [ -f package.json ]; then
  npm test > "$RUNNER_TEMP/npm-test.log" 2>&1 || {
    tail -n 40 "$RUNNER_TEMP/npm-test.log" >&2
    fail_with "$CAT_TEST" "repository tests failed"
  }
  summary "| tests | pass |"
fi

if [ -z "$(git status --porcelain)" ]; then
  summary "| repair changes | none |"
  {
    echo "result=pass"
    echo "changed=false"
  } >> "${GITHUB_OUTPUT:-/dev/null}"
  exit 0
fi

git config user.name 'github-actions[bot]'
git config user.email '41898282+github-actions[bot]@users.noreply.github.com'
git add -A
git diff --cached --check > "$RUNNER_TEMP/git-check.log" 2>&1 || {
  tail -n 20 "$RUNNER_TEMP/git-check.log" >&2
  fail_with "$CAT_TEST" "git diff --check failed"
}

remote_sha="$(git ls-remote --heads origin "refs/heads/$branch" | awk 'NR == 1 {print $1}')"
[ "$remote_sha" = "$expected_sha" ] \
  || fail_with "$CAT_REPAIR_BRANCH" "remote PR branch moved during repair"

git commit -m "AI review repair: $title" \
  -m "Agent-Repair-Review-ID: $review_id" \
  -m "Agent-Repair-Attempt: $attempt" \
  -m "Agent-Task-Metadata-SHA256: $metadata_sha" >/dev/null 2>&1 \
  || {
    if [ "$mode" = cross ]; then
      fail_with "$CAT_TARGET_PUSH" "repair commit failed"
    else
      fail_with "$CAT_PUSH" "repair commit failed"
    fi
  }

commit_sha="$(git rev-parse HEAD)"
git_push_target origin "HEAD:refs/heads/$branch" > "$RUNNER_TEMP/repair-push.log" 2>&1 || {
  tail -n 20 "$RUNNER_TEMP/repair-push.log" >&2
  if [ "$mode" = cross ]; then
    fail_with "$CAT_TARGET_PUSH" "repair push failed"
  else
    fail_with "$CAT_PUSH" "repair push failed"
  fi
}

{
  echo "result=pass"
  echo "changed=true"
  echo "commit_sha=$commit_sha"
} >> "${GITHUB_OUTPUT:-/dev/null}"
summary "| repair commit | \`$commit_sha\` |"
summary "| PR update | same branch; no new PR |"
