#!/usr/bin/env bash
# Convert the committed public allowlist into a safe cross-repo job matrix.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/repo.sh"

allowlist="${ALLOWLIST_FILE:-$SCRIPT_DIR/../config/allowed-repositories.txt}"
dispatcher="$(canonicalize_repo "${DISPATCHER_REPOSITORY:-${GITHUB_REPOSITORY:-}}")"
tmp="${RUNNER_TEMP:-/tmp}/review-targets.jsonl"
: > "$tmp"

while IFS= read -r line || [ -n "$line" ]; do
  line="${line%%#*}"
  line="$(printf '%s' "$line" | xargs)"
  [ -n "$line" ] || continue
  repo="$(canonicalize_repo "$line")"
  [ "$repo" != "$dispatcher" ] || continue
  printf '%s' "$repo" | grep -Eq '^[a-z0-9_.-]+/[a-z0-9_.-]+$' \
    || fail_with "$CAT_TARGET_NOT_ALLOWED" "invalid allowlist entry"
  jq -cn --arg repository "$repo" --arg owner "${repo%%/*}" --arg name "${repo#*/}" \
    '{repository:$repository,owner:$owner,name:$name}' >> "$tmp"
done < "$allowlist"

matrix="$(jq -cs '.' "$tmp")"
echo "matrix=$matrix" >> "${GITHUB_OUTPUT:-/dev/null}"
log_info "cross-repo review matrix built: targets=$(jq 'length' <<<"$matrix")"
