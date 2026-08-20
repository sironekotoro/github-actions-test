#!/usr/bin/env bash
# Fetch authoritative PR/review/comment records for one review event, then
# validate them without exposing review or task bodies in logs.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/repo.sh"

repo="$(canonicalize_repo "${TARGET_REPOSITORY:-}")"
pr_number="${PR_NUMBER:-}"
review_id="${REVIEW_ID:-}"
context_dir="${REVIEW_CONTEXT_DIR:-$RUNNER_TEMP/review-context}"

printf '%s' "$repo" | grep -Eq '^[a-z0-9_.-]+/[a-z0-9_.-]+$' \
  || fail_with "$CAT_REPAIR_METADATA" "target repository is invalid"
printf '%s' "$pr_number" | grep -Eq '^[1-9][0-9]*$' \
  || fail_with "$CAT_REPAIR_METADATA" "PR number is invalid"
printf '%s' "$review_id" | grep -Eq '^[1-9][0-9]*$' \
  || fail_with "$CAT_REPAIR_METADATA" "review id is invalid"

mkdir -p "$context_dir"
gh api "repos/$repo/pulls/$pr_number" > "$context_dir/pr.json" \
  || fail_with "$CAT_REPAIR_METADATA" "could not fetch PR metadata"
gh api "repos/$repo/pulls/$pr_number/reviews/$review_id" > "$context_dir/review.json" \
  || fail_with "$CAT_REPAIR_METADATA" "could not fetch submitted review"
review_decision="$(gh pr view "$pr_number" --repo "$repo" --json reviewDecision --jq .reviewDecision 2>/dev/null)" \
  || fail_with "$CAT_REPAIR_METADATA" "could not verify current PR review decision"
[ -n "$review_decision" ] \
  || fail_with "$CAT_REPAIR_METADATA" "current PR review decision is unavailable"
gh api --paginate --slurp "repos/$repo/issues/$pr_number/comments?per_page=100" \
  | jq 'add // []' > "$context_dir/comments.json" \
  || fail_with "$CAT_REPAIR_METADATA" "could not fetch PR repair markers"

PR_FILE="$context_dir/pr.json" REVIEW_FILE="$context_dir/review.json" \
  COMMENTS_FILE="$context_dir/comments.json" \
  REVIEW_DECISION="$review_decision" \
  node "$SCRIPT_DIR/parse-review-repair.mjs"
