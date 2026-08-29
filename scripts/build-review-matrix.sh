#!/usr/bin/env bash
# Build a safe cross-repo review-repair matrix from the dedicated polling target list.
# Every polling target must also remain in the ordinary dispatch allowlist.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/repo.sh"

allowlist="${ALLOWLIST_FILE:-$SCRIPT_DIR/../config/allowed-repositories.txt}"
review_targets="${REVIEW_TARGETS_FILE:-$SCRIPT_DIR/../config/review-repair-targets.txt}"
dispatcher="$(canonicalize_repo "${DISPATCHER_REPOSITORY:-${GITHUB_REPOSITORY:-}}")"
tmp_root="${RUNNER_TEMP:-/tmp}"
allowed_tmp="$tmp_root/review-allowed-repositories.txt"
matrix_tmp="$tmp_root/review-targets.jsonl"
seen_tmp="$tmp_root/review-targets-seen.txt"
NORMALIZED_REPO=""

[ -f "$allowlist" ] \
  || fail_with "$CAT_TARGET_NOT_ALLOWED" "dispatch allowlist is unavailable"
[ -f "$review_targets" ] \
  || fail_with "$CAT_TARGET_NOT_ALLOWED" "review-repair target list is unavailable"

: > "$allowed_tmp"
: > "$matrix_tmp"
: > "$seen_tmp"

normalize_line() {
  local line="$1"
  line="${line%%#*}"
  line="$(printf '%s' "$line" | xargs)"
  if [ -z "$line" ]; then
    NORMALIZED_REPO=""
    return 1
  fi
  NORMALIZED_REPO="$(canonicalize_repo "$line")"
  printf '%s' "$NORMALIZED_REPO" | grep -Eq '^[a-z0-9_.-]+/[a-z0-9_.-]+$' \
    || fail_with "$CAT_TARGET_NOT_ALLOWED" "invalid repository entry"
  return 0
}

while IFS= read -r line || [ -n "$line" ]; do
  normalize_line "$line" || continue
  repo="$NORMALIZED_REPO"
  grep -Fxq "$repo" "$allowed_tmp" 2>/dev/null || printf '%s\n' "$repo" >> "$allowed_tmp"
done < "$allowlist"

while IFS= read -r line || [ -n "$line" ]; do
  normalize_line "$line" || continue
  repo="$NORMALIZED_REPO"

  [ "$repo" != "$dispatcher" ] \
    || fail_with "$CAT_TARGET_NOT_ALLOWED" "review-repair polling targets must be cross-repository"
  grep -Fxq "$repo" "$allowed_tmp" \
    || fail_with "$CAT_TARGET_NOT_ALLOWED" "review-repair target is not in the dispatch allowlist"

  if grep -Fxq "$repo" "$seen_tmp" 2>/dev/null; then
    continue
  fi
  printf '%s\n' "$repo" >> "$seen_tmp"
  jq -cn --arg repository "$repo" --arg owner "${repo%%/*}" --arg name "${repo#*/}" \
    '{repository:$repository,owner:$owner,name:$name}' >> "$matrix_tmp"
done < "$review_targets"

matrix="$(jq -cs '.' "$matrix_tmp")"
echo "matrix=$matrix" >> "${GITHUB_OUTPUT:-/dev/null}"
log_info "cross-repo review matrix built: targets=$(jq 'length' <<<"$matrix")"
