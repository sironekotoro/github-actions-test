#!/usr/bin/env bash
# Regression coverage for the trusted apply_agent_patch helper and agent
# dispatch failure categories.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/lib/helpers.sh"
source "$ROOT/scripts/lib/common.sh"

# --- helpers ----------------------------------------------------------------

make_repo() { # <dir>
  local repo="$1"
  git init -q "$repo"
  git -C "$repo" config user.name test
  git -C "$repo" config user.email test@example.com
  git -C "$repo" checkout -q -b main
  printf 'base\n' > "$repo/file.txt"
  git -C "$repo" add file.txt
  git -C "$repo" commit -qm base
}

# Generate a realistic patch from base/workspace dirs exactly as the container
# scripts do, so -p2 strips the two controlled prefix directories.
gen_patch() { # <patch-file> <base-dir> <workspace-dir>
  local patch_file="$1" base_dir="$2" workspace_dir="$3"
  local parent="$(dirname "$base_dir")"
  local base_name="$(basename "$base_dir")"
  local workspace_name="$(basename "$workspace_dir")"
  (
    cd "$parent" 2>/dev/null
    git diff --no-index --binary --no-ext-diff \
      --src-prefix=a/ --dst-prefix=b/ \
      "$base_name" "$workspace_name" 2>/dev/null
  ) > "$patch_file" || true
}

reset_failures() {
  : > "$FAILURE_FILE"
  : > "$FAILURE_REASON_FILE"
}

# --- apply_agent_patch unit tests ------------------------------------------

# diff_status=2 => AGENT_START_FAILED, no FAILURE_REASON
tmp="$(make_temp)"
make_repo "$tmp/repo"
reset_failures
( apply_agent_patch "$tmp/repo" "$tmp/patch" 2 ) || true
t "diff_status=2 yields AGENT_START_FAILED" "AGENT_START_FAILED" "$(get_failure)"
t "diff_status=2 yields no FAILURE_REASON" "" "$(get_failure_reason)"

# diff_status=0 (no changes) => AGENT_PATCH_INVALID + NO_CHANGES
tmp="$(make_temp)"
make_repo "$tmp/repo"
mkdir -p "$tmp/base" "$tmp/workspace"
printf 'base\n' > "$tmp/base/file.txt"
cp "$tmp/base/file.txt" "$tmp/workspace/file.txt"
gen_patch "$tmp/patch" "$tmp/base" "$tmp/workspace"
reset_failures
( apply_agent_patch "$tmp/repo" "$tmp/patch" 0 ) || true
t "diff_status=0 yields AGENT_PATCH_INVALID" "AGENT_PATCH_INVALID" "$(get_failure)"
t "diff_status=0 yields NO_CHANGES reason" "NO_CHANGES" "$(get_failure_reason)"

# diff_status=1 with zero-byte patch => AGENT_PATCH_INVALID + EMPTY_PATCH
tmp="$(make_temp)"
make_repo "$tmp/repo"
: > "$tmp/patch"
reset_failures
( apply_agent_patch "$tmp/repo" "$tmp/patch" 1 ) || true
t "empty patch yields AGENT_PATCH_INVALID" "AGENT_PATCH_INVALID" "$(get_failure)"
t "empty patch yields EMPTY_PATCH reason" "EMPTY_PATCH" "$(get_failure_reason)"

# diff_status=1 with missing patch => AGENT_PATCH_INVALID + EMPTY_PATCH
tmp="$(make_temp)"
make_repo "$tmp/repo"
reset_failures
( apply_agent_patch "$tmp/repo" "$tmp/nonexistent.patch" 1 ) || true
t "missing patch yields AGENT_PATCH_INVALID" "AGENT_PATCH_INVALID" "$(get_failure)"
t "missing patch yields EMPTY_PATCH reason" "EMPTY_PATCH" "$(get_failure_reason)"

# PATCH_PARSE_FAILED: garbage patch fails baseline git apply --check -p2
tmp="$(make_temp)"
make_repo "$tmp/repo"
printf 'not a valid git patch\n' > "$tmp/patch"
reset_failures
( apply_agent_patch "$tmp/repo" "$tmp/patch" 1 ) || true
t "garbage patch yields AGENT_PATCH_INVALID" "AGENT_PATCH_INVALID" "$(get_failure)"
t "garbage patch yields PATCH_PARSE_FAILED reason" "PATCH_PARSE_FAILED" "$(get_failure_reason)"

# PATCH_VALIDATION_FAILED: trailing whitespace passes baseline --check but
# fails strict --whitespace=error
tmp="$(make_temp)"
make_repo "$tmp/repo"
mkdir -p "$tmp/base" "$tmp/workspace"
printf 'base\n' > "$tmp/base/file.txt"
printf 'base\ntrailing whitespace  \n' > "$tmp/workspace/file.txt"
gen_patch "$tmp/patch" "$tmp/base" "$tmp/workspace"
reset_failures
( apply_agent_patch "$tmp/repo" "$tmp/patch" 1 ) || true
t "trailing whitespace yields AGENT_PATCH_INVALID" "AGENT_PATCH_INVALID" "$(get_failure)"
t "trailing whitespace yields PATCH_VALIDATION_FAILED" "PATCH_VALIDATION_FAILED" "$(get_failure_reason)"

# Clean success: valid patch applies cleanly
tmp="$(make_temp)"
make_repo "$tmp/repo"
mkdir -p "$tmp/base" "$tmp/workspace"
printf 'base\n' > "$tmp/base/file.txt"
printf 'base\nclean change\n' > "$tmp/workspace/file.txt"
gen_patch "$tmp/patch" "$tmp/base" "$tmp/workspace"
reset_failures
apply_agent_patch "$tmp/repo" "$tmp/patch" 1
t "clean patch exits 0" "0" "$?"
t "clean patch imports content" "clean change" "$(tail -n 1 "$tmp/repo/file.txt")"

# Final-import fail-closed: all checks pass but final apply cannot write the
# file. Structural assertion that AGENT_PATCH_INVALID has no durable reason.
tmp="$(make_temp)"
make_repo "$tmp/repo"
mkdir -p "$tmp/base" "$tmp/workspace"
printf 'base\n' > "$tmp/base/file.txt"
printf 'base\nimport-fail\n' > "$tmp/workspace/file.txt"
gen_patch "$tmp/patch" "$tmp/base" "$tmp/workspace"
chmod a-w "$tmp/repo/file.txt"
reset_failures
( apply_agent_patch "$tmp/repo" "$tmp/patch" 1 ) || true
t "final-import fail yields AGENT_PATCH_INVALID" "AGENT_PATCH_INVALID" "$(get_failure)"
t "final-import fail yields no FAILURE_REASON" "" "$(get_failure_reason)"

# Structural assertion: every git apply invocation in apply_agent_patch must
# suppress stderr (2>/dev/null). Count the git-apply lines and verify each.
apply_source="$(declare -f apply_agent_patch)"
apply_count="$(printf '%s\n' "$apply_source" | rg -c 'git -C .* apply ' || true)"
suppressed_count="$(printf '%s\n' "$apply_source" | rg -c 'git -C .* apply .* 2>/dev/null' || true)"
t "all git apply invocations suppress stderr" "$apply_count" "$suppressed_count"

# --- agent runner failure categories (preserved unchanged) ------------------

RUN_AGENT="$ROOT/scripts/run-agent.sh"

run_agent_case() { # <tmp> <mock-agent-mode>
  local tmp="$1" mode="$2"
  mkdir -p "$tmp/bin"
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

finish