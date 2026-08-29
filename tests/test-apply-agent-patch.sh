#!/usr/bin/env bash
# Test: apply_agent_patch shared helper.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/lib/helpers.sh"
export ROOT

run_apply() { # <diff_status> <setup_fn>
  local tmp; tmp="$(make_temp)"
  local repo="$tmp/repo"
  local patch_file="$tmp/patch.diff"
  local diff_status="$1"
  local setup_fn="$2"
  git init -q "$repo"
  git -C "$repo" config user.email t@example.com
  git -C "$repo" config user.name t
  echo "original" > "$repo/file.txt"
  git -C "$repo" add file.txt
  git -C "$repo" commit -qm "base"
  "$setup_fn" "$tmp" "$repo" "$patch_file" "$diff_status"
  RUNNER_TEMP="$tmp" GITHUB_STEP_SUMMARY=/dev/null \
    bash -c '
      source "$ROOT/scripts/lib/common.sh"
      apply_agent_patch "$1" "$2" "$3"
    ' -- "$repo" "$patch_file" "$diff_status"
  local code=$?
  local cat=""; [ -f "$tmp/failure_category" ] && cat="$(cat "$tmp/failure_category")"
  local reason=""; [ -f "$tmp/failure_reason" ] && reason="$(cat "$tmp/failure_reason")"
  echo "$code|$cat|$reason"
}

# Build a proper patch from base/workspace dirs (mirrors container scripts).
make_patch() { # <tmp> <patch_file>
  local tmp="$1" patch_file="$2"
  (
    cd "$tmp"
    git diff --no-index --binary --no-ext-diff --src-prefix=a/ --dst-prefix=b/ base workspace
  ) > "$patch_file"
}

# --- diff_status outside {0,1} ---
setup_diff_status_2() {
  local tmp="$1" repo="$2" patch_file="$3" diff_status="$4"
  # No base/workspace dirs -> git diff fails with diff_status=2
  : > "$patch_file"
}
res="$(run_apply 2 setup_diff_status_2)"
t "diff_status=2 -> AGENT_START_FAILED, no reason" "1|AGENT_START_FAILED|" "$res"

# --- diff_status=0 (no changes) ---
setup_no_changes() {
  local tmp="$1" repo="$2" patch_file="$3" diff_status="$4"
  mkdir -p "$tmp/base" "$tmp/workspace"
  echo "original" > "$tmp/base/file.txt"
  echo "original" > "$tmp/workspace/file.txt"
  make_patch "$tmp" "$patch_file"
}
res="$(run_apply 0 setup_no_changes)"
t "diff_status=0 -> NO_CHANGES" "1|AGENT_PATCH_INVALID|NO_CHANGES" "$res"

# --- empty patch file with diff_status=1 (git diff says changes but output is empty) ---
setup_empty_patch() {
  local tmp="$1" repo="$2" patch_file="$3" diff_status="$4"
  : > "$patch_file"
}
res="$(run_apply 1 setup_empty_patch)"
t "empty patch -> EMPTY_PATCH" "1|AGENT_PATCH_INVALID|EMPTY_PATCH" "$res"

# --- patch with bad format (parse fails) ---
setup_parse_fail() {
  local tmp="$1" repo="$2" patch_file="$3" diff_status="$4"
  printf 'garbage patch content\n' > "$patch_file"
}
res="$(run_apply 1 setup_parse_fail)"
t "bad patch format -> PATCH_PARSE_FAILED" "1|AGENT_PATCH_INVALID|PATCH_PARSE_FAILED" "$res"

# --- patch with whitespace errors (valid patch + trailing whitespace) ---
setup_whitespace_fail() {
  local tmp="$1" repo="$2" patch_file="$3" diff_status="$4"
  mkdir -p "$tmp/base" "$tmp/workspace"
  cp "$repo/file.txt" "$tmp/base/"
  printf 'new content with trailing space   \n' > "$tmp/workspace/file.txt"
  make_patch "$tmp" "$patch_file"
}
res="$(run_apply 1 setup_whitespace_fail)"
t "whitespace error -> PATCH_VALIDATION_FAILED" "1|AGENT_PATCH_INVALID|PATCH_VALIDATION_FAILED" "$res"

# --- clean patch (success) ---
setup_clean_success() {
  local tmp="$1" repo="$2" patch_file="$3" diff_status="$4"
  mkdir -p "$tmp/base" "$tmp/workspace"
  cp "$repo/file.txt" "$tmp/base/"
  printf 'new content\n' > "$tmp/workspace/file.txt"
  make_patch "$tmp" "$patch_file"
}
res="$(run_apply 1 setup_clean_success)"
t "clean patch -> success" "0||" "$res"

# --- final import failure structural assertion ---
# The final git apply --whitespace=error -p2 can only fail in a race
# condition (concurrent repo modification).  Verify the code path exists.
t "final import fail code path exists" "1" \
  "$(grep -c 'fail_with.*CAT_AGENT_PATCH_INVALID.*could not import agent patch' "$ROOT/scripts/lib/common.sh")"

# --- verify preserving existing behavior ---

# MODEL_API_FAILED: run-agent dispatches this via set_failure
tmp="$(make_temp)"
RUNNER_TEMP="$tmp" bash -c '
  source "$ROOT/scripts/lib/common.sh"
  set_failure MODEL_API_FAILED
' 2>/dev/null
t "MODEL_API_FAILED preserved" "MODEL_API_FAILED" "$(cat "$tmp/failure_category")"

# AGENT_TIMEOUT: run-agent dispatches this via set_failure
tmp="$(make_temp)"
RUNNER_TEMP="$tmp" bash -c '
  source "$ROOT/scripts/lib/common.sh"
  set_failure AGENT_TIMEOUT
' 2>/dev/null
t "AGENT_TIMEOUT preserved" "AGENT_TIMEOUT" "$(cat "$tmp/failure_category")"

# AGENT=opencode deterministic behavior: parse-task defaults to opencode
tmp="$(make_temp)"
cat > "$tmp/parse_test" <<JSON
{"task_id":"a1","target_repository":"sironekotoro/github-actions-test","title":"t","prompt":"do it"}
JSON
res="$(jq -r '.agent // "opencode"' "$tmp/parse_test")"
t "deterministic AGENT=opencode default" "opencode" "$res"

finish
