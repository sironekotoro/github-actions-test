#!/usr/bin/env bash
# Unit tests for the shared apply_agent_patch helper. All cases exercise the
# exact post-agent transport classification/apply sequence used by both
# run-agent-dispatch-container.sh and run-review-repair-agent-container.sh.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/lib/helpers.sh"
COMMON="$ROOT/scripts/lib/common.sh"
DISPATCH="$ROOT/scripts/run-agent-dispatch-container.sh"
REPAIR="$ROOT/scripts/run-review-repair-agent-container.sh"

make_target_repo() { # <tmp>
  local tmp="$1"
  git init -q "$tmp/repo"
  git -C "$tmp/repo" config user.name test
  git -C "$tmp/repo" config user.email test@example.com
  git -C "$tmp/repo" checkout -q -b master
  printf 'original\n' > "$tmp/repo/file.txt"
  git -C "$tmp/repo" add file.txt
  git -C "$tmp/repo" commit -qm base
}

# Call apply_agent_patch in a subshell so exit 1 is captured.
run_apply() { # <tmp> <target_dir> <patch_file> <diff_status>
  local tmp="$1" target_dir="$2" patch_file="$3" diff_status="$4"
  RUNNER_TEMP="$tmp" FAILURE_REASON_FILE="$tmp/failure_reason" \
    source "$COMMON"
  apply_agent_patch "$target_dir" "$patch_file" "$diff_status" 2>/dev/null
}
export -f run_apply

# ---- 1. NO_CHANGES: diff_status=0 ----
tmp="$(make_temp)"
make_target_repo "$tmp"
code="$(
  RUNNER_TEMP="$tmp" FAILURE_REASON_FILE="$tmp/failure_reason" \
    bash -c 'source "$0"; apply_agent_patch "$1" /dev/null 0' "$COMMON" \
    "$tmp/repo" 2>/dev/null; echo $?
)"
cat="$(cat "$tmp/failure_category")"
reason="$(cat "$tmp/failure_reason")"
t "no changes: exit code" "1" "$code"
t "no changes: category" "AGENT_PATCH_INVALID" "$cat"
t "no changes: reason" "NO_CHANGES" "$reason"

# ---- 2. EMPTY_PATCH: diff_status=1, zero-byte patch ----
tmp="$(make_temp)"
make_target_repo "$tmp"
: > "$tmp/empty.patch"
code="$(
  RUNNER_TEMP="$tmp" FAILURE_REASON_FILE="$tmp/failure_reason" \
    bash -c 'source "$0"; apply_agent_patch "$1" "$2" 1' "$COMMON" \
    "$tmp/repo" "$tmp/empty.patch" 2>/dev/null; echo $?
)"
cat="$(cat "$tmp/failure_category")"
reason="$(cat "$tmp/failure_reason")"
t "empty patch: exit code" "1" "$code"
t "empty patch: category" "AGENT_PATCH_INVALID" "$cat"
t "empty patch: reason" "EMPTY_PATCH" "$reason"

# ---- 3. PATCH_PARSE_FAILED: corrupt patch ----
tmp="$(make_temp)"
make_target_repo "$tmp"
printf 'this is not a valid git patch\n' > "$tmp/bad.patch"
code="$(
  RUNNER_TEMP="$tmp" FAILURE_REASON_FILE="$tmp/failure_reason" \
    bash -c 'source "$0"; apply_agent_patch "$1" "$2" 1' "$COMMON" \
    "$tmp/repo" "$tmp/bad.patch" 2>/dev/null; echo $?
)"
cat="$(cat "$tmp/failure_category")"
reason="$(cat "$tmp/failure_reason")"
t "parse failed: exit code" "1" "$code"
t "parse failed: category" "AGENT_PATCH_INVALID" "$cat"
t "parse failed: reason" "PATCH_PARSE_FAILED" "$reason"

# ---- 4. PATCH_VALIDATION_FAILED: trailing whitespace ----
# Generate a patch with trailing whitespace using actual base/workspace dirs.
# The production wrapper uses: git diff --no-index --src-prefix=a/ --dst-prefix=b/ base workspace
tmp="$(make_temp)"
make_target_repo "$tmp"
base_dir="$tmp/base"
workspace_dir="$tmp/workspace"
mkdir -p "$base_dir" "$workspace_dir"
# Copy repo content (without .git) to base and workspace
tar -C "$tmp/repo" --exclude=.git -cf - . | tar -C "$base_dir" -xf -
tar -C "$base_dir" -cf - . | tar -C "$workspace_dir" -xf -
# Add trailing whitespace to the workspace copy
printf 'original\n' > "$base_dir/file.txt"
printf 'original\ntrailing \n' > "$workspace_dir/file.txt"
(
  cd "$tmp"
  git diff --no-index --no-ext-diff --src-prefix=a/ --dst-prefix=b/ base workspace
) > "$tmp/whitespace.patch" 2>/dev/null
code="$(
  RUNNER_TEMP="$tmp" FAILURE_REASON_FILE="$tmp/failure_reason" \
    bash -c 'source "$0"; apply_agent_patch "$1" "$2" 1' "$COMMON" \
    "$tmp/repo" "$tmp/whitespace.patch" 2>/dev/null; echo $?
)"
cat="$(cat "$tmp/failure_category")"
reason="$(cat "$tmp/failure_reason")"
t "validation failed: exit code" "1" "$code"
t "validation failed: category" "AGENT_PATCH_INVALID" "$cat"
t "validation failed: reason" "PATCH_VALIDATION_FAILED" "$reason"
# The target tree must remain unchanged after a validation failure
t "validation failed: tree unchanged" "original" "$(cat "$tmp/repo/file.txt")"

# ---- 5. Clean success: valid patch with no whitespace issues ----
tmp="$(make_temp)"
make_target_repo "$tmp"
base_dir="$tmp/base"
workspace_dir="$tmp/workspace"
mkdir -p "$base_dir" "$workspace_dir"
tar -C "$tmp/repo" --exclude=.git -cf - . | tar -C "$base_dir" -xf -
tar -C "$base_dir" -cf - . | tar -C "$workspace_dir" -xf -
printf 'original\nnew content\n' > "$workspace_dir/file.txt"
(
  cd "$tmp"
  git diff --no-index --no-ext-diff --src-prefix=a/ --dst-prefix=b/ base workspace
) > "$tmp/clean.patch" 2>/dev/null
code="$(
  RUNNER_TEMP="$tmp" FAILURE_REASON_FILE="$tmp/failure_reason" \
    bash -c 'source "$0"; apply_agent_patch "$1" "$2" 1' "$COMMON" \
    "$tmp/repo" "$tmp/clean.patch" 2>/dev/null; echo $?
)"
cat_content="$(cat "$tmp/failure_category" 2>/dev/null || echo 'none')"
reason_content="$(cat "$tmp/failure_reason" 2>/dev/null || echo 'none')"
t "clean patch: exit code" "0" "$code"
t "clean patch: no failure category" "" "$cat_content"
t "clean patch: no failure reason" "" "$reason_content"
t "clean patch: content applied" "new content" "$(tail -n 1 "$tmp/repo/file.txt")"

# ---- 6. AGENT_START_FAILED: diff_status outside 0/1 ----
tmp="$(make_temp)"
make_target_repo "$tmp"
: > "$tmp/patch"
# diff_status=2 (or any value != 0 and != 1) => AGENT_START_FAILED
code="$(
  RUNNER_TEMP="$tmp" FAILURE_REASON_FILE="$tmp/failure_reason" \
    bash -c 'source "$0"; apply_agent_patch "$1" "$2" 2' "$COMMON" \
    "$tmp/repo" "$tmp/patch" 2>/dev/null; echo $?
)"
cat="$(cat "$tmp/failure_category")"
reason="$(cat "$tmp/failure_reason" 2>/dev/null || echo 'none')"
t "diff start fail: exit code" "1" "$code"
t "diff start fail: category" "AGENT_START_FAILED" "$cat"
t "diff start fail: no reason written" "" "$(cat "$tmp/failure_reason" 2>/dev/null)"

# ---- 7. Production wrappers call apply_agent_patch ----
t "dispatch container uses shared helper" "yes" "$(grep -q 'apply_agent_patch' "$DISPATCH" && echo yes || echo no)"
t "repair container uses shared helper" "yes" "$(grep -q 'apply_agent_patch' "$REPAIR" && echo yes || echo no)"

# ---- 8. Deterministic AGENT=opencode export (compatibility) ----
# AGENT must not be exported by the helper or common.sh on source
export_check="$(
  env -i HOME="$HOME" PATH="$PATH" RUNNER_TEMP="$tmp" \
    bash -c 'source "$0"; printf "%s" "${AGENT:-unset}"' "$COMMON"
)"
t "AGENT remains unset after sourcing common.sh" "unset" "$export_check"

finish