#!/usr/bin/env bash
# Validate and authorize the task target before any cross-repository credential
# is requested or any target checkout occurs.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/repo.sh"

TASK_FILE="${TASK_FILE:-$RUNNER_TEMP/task.json}"
ALLOWLIST_FILE="${ALLOWLIST_FILE:-$SCRIPT_DIR/../config/allowed-repositories.txt}"
DISPATCHER_REPOSITORY="${DISPATCHER_REPOSITORY:-${GITHUB_REPOSITORY:-}}"
CROSS_REPO_ENABLED="${CROSS_REPO_ENABLED:-false}"

[ -f "$TASK_FILE" ] || fail_with "$CAT_INVALID_PAYLOAD" "task.json not found"
[ -f "$ALLOWLIST_FILE" ] || fail_with "$CAT_TARGET_NOT_ALLOWED" "allowlist not found"

target_raw="$(jq -r '.target_repository // ""' "$TASK_FILE")"
target="$(canonicalize_repo "$target_raw")"
dispatcher="$(canonicalize_repo "$DISPATCHER_REPOSITORY")"

# Strict owner/name grammar after canonicalization. This prevents URLs, path
# traversal, shell metacharacters, and prompt-controlled checkout options.
if ! printf '%s' "$target" | grep -Eq '^[a-z0-9_.-]+/[a-z0-9_.-]+$'; then
  fail_with "$CAT_INVALID_PAYLOAD" "target_repository must be canonical owner/name"
fi

allowed=false
while IFS= read -r line || [ -n "$line" ]; do
  line="${line%%#*}"
  line="$(printf '%s' "$line" | xargs)"
  [ -z "$line" ] && continue
  [ "$(canonicalize_repo "$line")" = "$target" ] && { allowed=true; break; }
done < "$ALLOWLIST_FILE"

if [ "$allowed" != true ]; then
  fail_with "$CAT_TARGET_NOT_ALLOWED" "target=$target"
fi

owner="${target%%/*}"
name="${target#*/}"
mode="cross"
if [ "$target" = "$dispatcher" ]; then
  mode="same"
elif [ "$CROSS_REPO_ENABLED" != "true" ]; then
  fail_with "$CAT_CROSS_REPO_AUTH_UNAVAILABLE" "cross-repo dispatch is feature-disabled"
fi

{
  echo "result=pass"
  echo "mode=$mode"
  echo "target_repository=$target"
  echo "target_owner=$owner"
  echo "target_name=$name"
} >> "${GITHUB_OUTPUT:-/dev/null}"

summary "| target repository | \`$target\` |"
summary "| dispatch mode | \`$mode\` |"
log_info "target authorized: $target mode=$mode"
