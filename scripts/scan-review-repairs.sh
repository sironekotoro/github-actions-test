#!/usr/bin/env bash
# Poll one allowlisted target using only its target-scoped token. Select at
# most one current authorized CHANGES_REQUESTED review per invocation.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/repo.sh"

repo="$(canonicalize_repo "${TARGET_REPOSITORY:-}")"
real_output="${GITHUB_OUTPUT:-/dev/null}"
scan_dir="${REVIEW_CONTEXT_DIR:-$RUNNER_TEMP/review-scan}"
mkdir -p "$scan_dir"

printf '%s' "$repo" | grep -Eq '^[a-z0-9_.-]+/[a-z0-9_.-]+$' \
  || fail_with "$CAT_REPAIR_METADATA" "target repository is invalid"

gh api --paginate --slurp "repos/$repo/pulls?state=open&per_page=100" \
  | jq 'add // []' > "$scan_dir/pulls.json" \
  || fail_with "$CAT_REPAIR_METADATA" "could not list open target PRs"

while IFS= read -r pr_number; do
  [ -n "$pr_number" ] || continue
  pr_dir="$scan_dir/pr-$pr_number"
  mkdir -p "$pr_dir"
  gh api "repos/$repo/pulls/$pr_number" > "$pr_dir/pr.json" || continue

  # Cheaply reject unrelated PRs before making further API calls.
  jq -e '.state == "open" and .draft == false and .user.type == "Bot" and (.body | contains("<!-- agent-dispatch-task:v1:"))' \
    "$pr_dir/pr.json" >/dev/null 2>&1 || continue

  review_decision="$(gh pr view "$pr_number" --repo "$repo" --json reviewDecision --jq .reviewDecision 2>/dev/null || true)"
  [ "$review_decision" = "CHANGES_REQUESTED" ] || continue

  head_sha="$(jq -r '.head.sha // ""' "$pr_dir/pr.json")"
  gh api --paginate --slurp "repos/$repo/pulls/$pr_number/reviews?per_page=100" \
    | jq 'add // []' > "$pr_dir/reviews.json" || continue

  review_id=""
  while IFS=$'\t' read -r candidate_id candidate_login; do
    [ -n "$candidate_id" ] || continue
    case "|${ACTOR_ALLOWLIST:-sironekotoro}|" in
      *"|$candidate_login|"*) review_id="$candidate_id"; break ;;
    esac
  done < <(jq -r --arg sha "$head_sha" \
    '[.[] | select(.state == "CHANGES_REQUESTED" and .commit_id == $sha)]
     | sort_by(.submitted_at, .id) | reverse[] | [.id, .user.login] | @tsv' \
    "$pr_dir/reviews.json")
  [ -n "$review_id" ] || continue

  jq --argjson id "$review_id" '.[] | select(.id == $id)' "$pr_dir/reviews.json" > "$pr_dir/review.json"
  gh api --paginate --slurp "repos/$repo/issues/$pr_number/comments?per_page=100" \
    | jq 'add // []' > "$pr_dir/comments.json" || continue

  candidate_output="$pr_dir/output"
  : > "$candidate_output"
  GITHUB_OUTPUT="$candidate_output" PR_FILE="$pr_dir/pr.json" \
    REVIEW_FILE="$pr_dir/review.json" COMMENTS_FILE="$pr_dir/comments.json" \
    REVIEW_DECISION="$review_decision" STRICT_REVIEWER=false node "$SCRIPT_DIR/parse-review-repair.mjs" \
    > "$pr_dir/parser.log" 2> "$pr_dir/parser.err" || {
      cat "$pr_dir/parser.err" >&2
      exit 1
    }
  candidate_decision="$(sed -n 's/^decision=//p' "$candidate_output" | tail -n 1)"
  case "$candidate_decision" in
    run|limit-reached)
      cat "$candidate_output" >> "$real_output"
      log_info "selected review repair candidate repo=$repo pr=$pr_number decision=$candidate_decision"
      exit 0
      ;;
  esac
done < <(jq -r 'sort_by(.number)[] | .number' "$scan_dir/pulls.json")

{
  echo "decision=none"
  echo "result=skip"
} >> "$real_output"
log_info "no eligible review repair candidate for $repo"
