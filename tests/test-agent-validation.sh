#!/usr/bin/env bash
# Regression coverage for the trusted apply_agent_patch shared helper.
# Tests call the helper directly with realistic base/workspace-prefixed
# -p2 fixtures rather than reimplementing the algorithm.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/lib/helpers.sh"
source "$ROOT/scripts/lib/common.sh"

CONTAINER="$ROOT/scripts/run-agent-dispatch-container.sh"
RUN_AGENT="$ROOT/scripts/run-agent.sh"

# --- Helpers for -p2 fixture creation ---

# make_target_repo <tmp>    convenience: creates a small repo with file.txt
make_target_repo() {
  local tmp="$1"
  git init -q "$tmp/repo"
  git -C "$tmp/repo" config user.name test
  git -C "$tmp/repo" config user.email test@example.com
  git -C "$tmp/repo" checkout -q -b master
  printf 'base\n' > "$tmp/repo/file.txt"
  git -C "$tmp/repo" add file.txt
  git -C "$tmp/repo" commit -qm base
}

# make_diff_patch <tmp> <change_fn>
#   Creates agent_root/{base,workspace}, runs a change function on workspace,
#   then runs git diff --no-index -p2-style to produce patch at agent_root/patch.
#   Returns diff_status via global _diff_status.
make_diff_patch() {
  local tmp="$1" change_fn="$2"
  local agent_root="$tmp/agent_root"
  mkdir -p "$agent_root/base" "$agent_root/workspace"
  printf 'base\n' > "$agent_root/base/file.txt"
  cp "$agent_root/base/file.txt" "$agent_root/workspace/"
  $change_fn "$agent_root/workspace"
  set +e
  (
    cd "$agent_root"
    git diff --no-index --binary --no-ext-diff --src-prefix=a/ --dst-prefix=b/ base workspace
  ) > "$agent_root/patch"
  _diff_status=$?
  set -e
}

_noop()        { :; }
_append_valid() { printf 'valid change\n' >> "$1/file.txt"; }
_append_trailing_ws() { printf 'invalid trailing whitespace \n' >> "$1/file.txt"; }

# --- Direct shared helper tests (realistic -p2 fixtures) ---

# NO_CHANGES: diff_status=0 produces AGENT_PATCH_INVALID + NO_CHANGES reason
tmp="$(make_temp)"
make_target_repo "$tmp"
make_diff_patch "$tmp" _noop
# _diff_status should be 0 (identical trees)
( RUNNER_TEMP="$tmp" source "$ROOT/scripts/lib/common.sh" \
    && apply_agent_patch "$tmp/repo" "$tmp/agent_root/patch" "$_diff_status" "$tmp/reason" 2>/dev/null )
code=$?
t "NO_CHANGES diff_status=0 rejected" "1|NO_CHANGES" "$code|$(cat "$tmp/reason" 2>/dev/null || echo missing)"
t "NO_CHANGES does not modify target" "base" "$(cat "$tmp/repo/file.txt")"

# EMPTY_PATCH: non-existent patch file
tmp="$(make_temp)"
make_target_repo "$tmp"
( RUNNER_TEMP="$tmp" source "$ROOT/scripts/lib/common.sh" \
    && apply_agent_patch "$tmp/repo" "$tmp/nonexistent" 1 "$tmp/reason" 2>/dev/null )
code=$?
t "EMPTY_PATCH missing file rejected" "1|EMPTY_PATCH" "$code|$(cat "$tmp/reason" 2>/dev/null || echo missing)"

# EMPTY_PATCH: zero-length patch file
tmp="$(make_temp)"
make_target_repo "$tmp"
: > "$tmp/empty.patch"
( RUNNER_TEMP="$tmp" source "$ROOT/scripts/lib/common.sh" \
    && apply_agent_patch "$tmp/repo" "$tmp/empty.patch" 1 "$tmp/reason" 2>/dev/null )
code=$?
t "EMPTY_PATCH zero-length rejected" "1|EMPTY_PATCH" "$code|$(cat "$tmp/reason" 2>/dev/null || echo missing)"

# PATCH_PARSE_FAILED: patch that doesn't apply
tmp="$(make_temp)"
make_target_repo "$tmp"
# Write a patch that references a nonexistent path
printf 'diff --git a/nonexistent.txt b/nonexistent.txt\n' > "$tmp/bad.patch"
printf '--- a/nonexistent.txt\n+++ b/nonexistent.txt\n' >> "$tmp/bad.patch"
printf '@@ -0,0 +1 @@\n+content\n' >> "$tmp/bad.patch"
( RUNNER_TEMP="$tmp" source "$ROOT/scripts/lib/common.sh" \
    && apply_agent_patch "$tmp/repo" "$tmp/bad.patch" 1 "$tmp/reason" 2>/dev/null )
code=$?
t "PATCH_PARSE_FAILED bad path rejected" "1|PATCH_PARSE_FAILED" "$code|$(cat "$tmp/reason" 2>/dev/null || echo missing)"

# PATCH_VALIDATION_FAILED: trailing whitespace
tmp="$(make_temp)"
make_target_repo "$tmp"
make_diff_patch "$tmp" _append_trailing_ws
# _diff_status is 1 (changed)
( RUNNER_TEMP="$tmp" source "$ROOT/scripts/lib/common.sh" \
    && apply_agent_patch "$tmp/repo" "$tmp/agent_root/patch" "$_diff_status" "$tmp/reason" 2>/dev/null )
code=$?
t "PATCH_VALIDATION_FAILED trailing ws rejected" "1|PATCH_VALIDATION_FAILED" "$code|$(cat "$tmp/reason" 2>/dev/null || echo missing)"
t "PATCH_VALIDATION_FAILED does not modify target" "base" "$(cat "$tmp/repo/file.txt")"

# Valid patch imported successfully
tmp="$(make_temp)"
make_target_repo "$tmp"
make_diff_patch "$tmp" _append_valid
( RUNNER_TEMP="$tmp" source "$ROOT/scripts/lib/common.sh" \
    && apply_agent_patch "$tmp/repo" "$tmp/agent_root/patch" "$_diff_status" "$tmp/reason" 2>/dev/null )
code=$?
t "valid patch imports successfully" "0|" "$code|$(cat "$tmp/reason" 2>/dev/null)"
t "valid patch content is imported" "valid change" "$(tail -n 1 "$tmp/repo/file.txt")"

# --- Container-level integration tests (existing pattern, simplified) ---

make_target() { # <tmp>
  local tmp="$1"
  make_target_repo "$tmp"
  printf '%s\n' '{"task_id":"validation","target_repository":"sironekotoro/github-actions-test","title":"validation","source":"test","prompt":"safe task"}' > "$tmp/task.json"
}

run_container_case() { # <tmp> <mock-docker-mode>
  local tmp="$1" mode="$2"
  mkdir -p "$tmp/bin"
  cat > "$tmp/bin/docker" <<'MOCK'
#!/usr/bin/env bash
set -uo pipefail

command="${1:-}"
subcommand="${2:-}"

if [ "$command" = "info" ]; then
  [ "${MOCK_DOCKER_MODE:-}" != "agent-start-fail" ]
  exit $?
fi

if [ "$command" = "image" ] && [ "$subcommand" = "inspect" ]; then
  exit 0
fi

if [ "$command" = "network" ]; then
  exit 0
fi

if [ "$command" = "inspect" ]; then
  printf '%s\n' '[{"NetworkSettings":{"Networks":{"agent-dispatch-private-validation123":{"IPAddress":"127.0.0.2"}}}}]'
  exit 0
fi

if [ "$command" = "run" ]; then
  is_agent=false
  workspace_mount=""
  for arg in "$@"; do
    [ "$arg" = "--rm" ] && is_agent=true
    case "$arg" in
      type=bind,src=*,dst=/workspace)
        workspace_mount="${arg#type=bind,src=}"
        workspace_mount="${workspace_mount%,dst=/workspace}"
        ;;
    esac
  done
  if [ "$is_agent" = true ] && [ -n "$workspace_mount" ]; then
    case "${MOCK_DOCKER_MODE:-}" in
      invalid)
        printf 'invalid trailing whitespace \n' >> "$workspace_mount/file.txt"
        ;;
      valid)
        printf 'valid change\n' >> "$workspace_mount/file.txt"
        ;;
    esac
  fi
  exit 0
fi

exit 0
MOCK
  chmod +x "$tmp/bin/docker"
  ( cd "$tmp/repo" && PATH="$tmp/bin:$PATH" MOCK_DOCKER_MODE="$mode" \
      RUNNER_TEMP="$tmp" GITHUB_RUN_ID=validation123 GITHUB_OUTPUT="$tmp/out" \
      TASK_FILE="$tmp/task.json" AGENT_CREDENTIAL_VALUE=mock-openrouter-key \
      export PATH MOCK_DOCKER_MODE RUNNER_TEMP GITHUB_RUN_ID GITHUB_OUTPUT TASK_FILE AGENT_CREDENTIAL_VALUE; \
      bash "$CONTAINER" >"$tmp/stdout" 2>"$tmp/stderr" )
  printf '%s\n' "$?" > "$tmp/code"
}

tmp="$(make_temp)"
make_target "$tmp"
run_container_case "$tmp" invalid
t "invalid returned patch is rejected (container)" "1|AGENT_PATCH_INVALID" "$(cat "$tmp/code")|$(cat "$tmp/failure_category")"
t "invalid returned patch is not imported (container)" "base" "$(cat "$tmp/repo/file.txt")"

tmp="$(make_temp)"
make_target "$tmp"
run_container_case "$tmp" valid
t "valid returned patch imports (container)" "0|" "$(cat "$tmp/code")|$(cat "$tmp/failure_category")"
t "valid patch content is imported (container)" "valid change" "$(tail -n 1 "$tmp/repo/file.txt")"

tmp="$(make_temp)"
make_target "$tmp"
run_container_case "$tmp" agent-start-fail
t "agent start failure keeps existing category (container)" "1|AGENT_START_FAILED" "$(cat "$tmp/code")|$(cat "$tmp/failure_category")"

# --- agent-level category tests (unchanged) ---

run_agent_case() { # <tmp> <mock-agent-mode>
  local tmp="$1" mode="$2"
  mkdir -p "$tmp/bin"
  printf 'trusted prompt\n' > "$tmp/prompt"
  cat > "$tmp/bin/opencode" <<'MOCK'
#!/usr/bin/env bash
printf 'mock API failure\n'
exit 7
MOCK
  if [ "$mode" = timeout ]; then
    cat > "$tmp/bin/timeout" <<'MOCK'
#!/usr/bin/env bash
exit 124
MOCK
    chmod +x "$tmp/bin/timeout"
  fi
  chmod +x "$tmp/bin/opencode"
  ( PATH="$tmp/bin:$PATH" MOCK_AGENT_MODE="$mode" RUNNER_TEMP="$tmp" \
      GITHUB_OUTPUT="$tmp/out" GITHUB_STEP_SUMMARY="$tmp/summary.md" \
      PROMPT_FILE="$tmp/prompt" AGENT_LOG="$tmp/agent.log" \
      AGENT_USE_PREBUILT_PROMPT=true AGENT_AUTO_INSTALL=false \
      AGENT_MAX_ATTEMPTS=1 AGENT_MAX_RUNTIME=1 OPENROUTER_MODEL=test/model \
      OPENROUTER_API_KEY=mock-openrouter-key; \
      export PATH MOCK_AGENT_MODE RUNNER_TEMP GITHUB_OUTPUT GITHUB_STEP_SUMMARY PROMPT_FILE AGENT_LOG \
        AGENT_USE_PREBUILT_PROMPT AGENT_AUTO_INSTALL AGENT_MAX_ATTEMPTS AGENT_MAX_RUNTIME \
        OPENROUTER_MODEL OPENROUTER_API_KEY; \
      bash "$RUN_AGENT" >"$tmp/stdout" 2>"$tmp/stderr" )
  printf '%s\n' "$?" > "$tmp/code"
}

tmp="$(make_temp)"
run_agent_case "$tmp" api
t "API failure keeps existing category" "7|MODEL_API_FAILED" "$(cat "$tmp/code")|$(cat "$tmp/failure_category")"

tmp="$(make_temp)"
run_agent_case "$tmp" timeout
t "timeout keeps existing category" "124|AGENT_TIMEOUT" "$(cat "$tmp/code")|$(cat "$tmp/failure_category")"

# --- Structural assertion for final-import failure path ---
# A deterministic final-apply regression cannot be simulated cleanly without
# weakening isolation (--check and --apply fail on identical conditions).
# Instead assert the helper source wraps the final import with AGENT_PATCH_INVALID.
# The final import is the only `apply --whitespace=error -p2` WITHOUT --check.
final_import_count="$(grep 'apply --whitespace=error -p2' "$ROOT/scripts/lib/common.sh" | grep -v -c '\-\-check' || true)"
t "helper contains exactly one final apply import line" "1" "$final_import_count"

# Every stage that fails must go through fail_with CAT_AGENT_PATCH_INVALID.
# There are 5 failure exits in the function (NO_CHANGES, EMPTY_PATCH,
# PATCH_PARSE_FAILED, PATCH_VALIDATION_FAILED, final import PATCH_VALIDATION_FAILED).
fail_with_count="$(grep -c 'fail_with "$CAT_AGENT_PATCH_INVALID"' "$ROOT/scripts/lib/common.sh" || true)"
t "helper has 5 AGENT_PATCH_INVALID fail_with calls for all stages" "5" "$fail_with_count"

finish