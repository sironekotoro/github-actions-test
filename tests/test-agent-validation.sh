#!/usr/bin/env bash
# Regression coverage for the trusted patch-import boundary and agent failure
# categories. Test artifacts stay outside the editable source tree so they
# cannot be returned as part of an agent-generated patch.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/lib/helpers.sh"

TEST_TMP="$(mktemp -d "${TMPDIR:-/tmp}/agent-validation.XXXXXX")"
trap 'rm -rf -- "$TEST_TMP"' EXIT
export RUNNER_TEMP="$TEST_TMP"
export GITHUB_STEP_SUMMARY="$TEST_TMP/summary.md"
source "$ROOT/scripts/lib/common.sh"

CONTAINER="$ROOT/scripts/run-agent-dispatch-container.sh"
REVIEW_CONTAINER="$ROOT/scripts/run-review-repair-agent-container.sh"
RUN_AGENT="$ROOT/scripts/run-agent.sh"

make_case() {
  mktemp -d "$TEST_TMP/case.XXXXXX"
}

make_repo() { # <dir>
  local repo="$1"
  git init -q "$repo"
  git -C "$repo" config user.name test
  git -C "$repo" config user.email test@example.com
  git -C "$repo" checkout -q -b master
  printf 'base\n' > "$repo/file.txt"
  git -C "$repo" add file.txt
  git -C "$repo" commit -qm base
}

gen_patch() { # <patch-file> <base-dir> <workspace-dir>
  local patch_file="$1" base_dir="$2" workspace_dir="$3"
  local parent base_name workspace_name status
  parent="$(dirname "$base_dir")"
  base_name="$(basename "$base_dir")"
  workspace_name="$(basename "$workspace_dir")"
  (
    cd "$parent" || exit 2
    git diff --no-index --binary --no-ext-diff \
      --src-prefix=a/ --dst-prefix=b/ \
      "$base_name" "$workspace_name" 2>/dev/null
  ) > "$patch_file"
  status=$?
  [ "$status" -eq 0 ] || [ "$status" -eq 1 ]
}

reset_failures() {
  : > "$FAILURE_FILE"
  : > "$FAILURE_REASON_FILE"
}

run_apply_case() { # <target> <patch> <diff-status> <stdout> <stderr>
  local target="$1" patch="$2" diff_status="$3" stdout="$4" stderr="$5"
  ( apply_agent_patch "$target" "$patch" "$diff_status" ) >"$stdout" 2>"$stderr"
}

case "$TEST_TMP/" in
  "$ROOT/"*) fixtures_outside=no ;;
  *) fixtures_outside=yes ;;
esac
t "validation fixtures stay outside source tree" "yes" "$fixtures_outside"

# diff_status outside {0,1} is an infrastructure failure and does not assign a
# patch-specific durable reason.
tmp="$(make_case)"
make_repo "$tmp/repo"
reset_failures
run_apply_case "$tmp/repo" "$tmp/missing.patch" 2 "$tmp/stdout" "$tmp/stderr"
code=$?
t "diff_status=2 yields AGENT_START_FAILED" "1|AGENT_START_FAILED" "$code|$(get_failure)"
t "diff_status=2 yields no FAILURE_REASON" "" "$(get_failure_reason)"

# diff_status=0 is a completed agent run with no returned changes.
tmp="$(make_case)"
make_repo "$tmp/repo"
reset_failures
run_apply_case "$tmp/repo" "$tmp/empty.patch" 0 "$tmp/stdout" "$tmp/stderr"
code=$?
t "diff_status=0 yields AGENT_PATCH_INVALID" "1|AGENT_PATCH_INVALID" "$code|$(get_failure)"
t "diff_status=0 yields NO_CHANGES" "NO_CHANGES" "$(get_failure_reason)"

# A successful no-op emits only a bounded, exact-literal-redacted agent tail.
tmp="$(make_case)"
make_repo "$tmp/repo"
secret='selected-provider-secret-no-change'
prompt='full trusted prompt must not be exposed'
printf '%s' "$prompt" > "$tmp/prompt"
{
  for line in $(seq 1 45); do printf 'agent line %s\n' "$line"; done
  printf 'credential=%s\n' "$secret"
  printf 'prompt=%s\n' "$prompt"
} > "$tmp/agent.log"
reset_failures
( apply_agent_patch "$tmp/repo" "$tmp/empty.patch" 0 "$tmp/agent.log" "$secret" "$tmp/prompt" ) >"$tmp/stdout" 2>"$tmp/stderr"
code=$?
t "no-change diagnostic remains patch failure" "1|AGENT_PATCH_INVALID|NO_CHANGES" "$code|$(get_failure)|$(get_failure_reason)"
t "no-change diagnostic redacts selected credential" "absent" "$(grep -Fq "$secret" "$tmp/stderr" && echo present || echo absent)"
t "no-change diagnostic has redaction marker" "present" "$(grep -Fq '[REDACTED_SELECTED_CREDENTIAL]' "$tmp/stderr" && echo present || echo absent)"
t "no-change diagnostic redacts full prompt" "absent|present" "$(grep -Fq "$prompt" "$tmp/stderr" && echo present || echo absent)|$(grep -Fq '[REDACTED_AGENT_PROMPT]' "$tmp/stderr" && echo present || echo absent)"
t "no-change diagnostic is bounded to tail" "absent" "$(grep -Eq '^agent line 1$' "$tmp/stderr" && echo present || echo absent)"

# A missing or zero-byte patch with diff_status=1 is EMPTY_PATCH.
tmp="$(make_case)"
make_repo "$tmp/repo"
reset_failures
run_apply_case "$tmp/repo" "$tmp/missing.patch" 1 "$tmp/stdout" "$tmp/stderr"
code=$?
t "missing patch yields AGENT_PATCH_INVALID" "1|AGENT_PATCH_INVALID" "$code|$(get_failure)"
t "missing patch yields EMPTY_PATCH" "EMPTY_PATCH" "$(get_failure_reason)"

tmp="$(make_case)"
make_repo "$tmp/repo"
: > "$tmp/empty.patch"
reset_failures
run_apply_case "$tmp/repo" "$tmp/empty.patch" 1 "$tmp/stdout" "$tmp/stderr"
code=$?
t "zero-byte patch yields AGENT_PATCH_INVALID" "1|AGENT_PATCH_INVALID" "$code|$(get_failure)"
t "zero-byte patch yields EMPTY_PATCH" "EMPTY_PATCH" "$(get_failure_reason)"

# Garbage that cannot pass the baseline applicability/parse check is distinct
# from strict whitespace validation failure.
tmp="$(make_case)"
make_repo "$tmp/repo"
printf 'not a valid git patch\n' > "$tmp/invalid.patch"
reset_failures
run_apply_case "$tmp/repo" "$tmp/invalid.patch" 1 "$tmp/stdout" "$tmp/stderr"
code=$?
t "garbage patch yields AGENT_PATCH_INVALID" "1|AGENT_PATCH_INVALID" "$code|$(get_failure)"
t "garbage patch yields PATCH_PARSE_FAILED" "PATCH_PARSE_FAILED" "$(get_failure_reason)"

# Build trailing whitespace only at runtime. The repository test source itself
# remains whitespace-clean, so an outer strict patch validator never sees the
# intentionally invalid fixture.
tmp="$(make_case)"
make_repo "$tmp/repo"
mkdir -p "$tmp/base" "$tmp/workspace"
printf 'base\n' > "$tmp/base/file.txt"
printf 'base\n%s%s\n' 'trailing whitespace' '  ' > "$tmp/workspace/file.txt"
gen_patch "$tmp/trailing.patch" "$tmp/base" "$tmp/workspace"
reset_failures
run_apply_case "$tmp/repo" "$tmp/trailing.patch" 1 "$tmp/stdout" "$tmp/stderr"
code=$?
t "trailing whitespace yields AGENT_PATCH_INVALID" "1|AGENT_PATCH_INVALID" "$code|$(get_failure)"
t "trailing whitespace yields PATCH_VALIDATION_FAILED" "PATCH_VALIDATION_FAILED" "$(get_failure_reason)"
t "rejected whitespace patch leaves target unchanged" "base" "$(cat "$tmp/repo/file.txt")"

# A clean realistic base/workspace patch crosses the trusted boundary.
tmp="$(make_case)"
make_repo "$tmp/repo"
mkdir -p "$tmp/base" "$tmp/workspace"
printf 'base\n' > "$tmp/base/file.txt"
printf 'base\nclean change\n' > "$tmp/workspace/file.txt"
gen_patch "$tmp/clean.patch" "$tmp/base" "$tmp/workspace"
reset_failures
run_apply_case "$tmp/repo" "$tmp/clean.patch" 1 "$tmp/stdout" "$tmp/stderr"
code=$?
t "clean patch imports successfully" "0|" "$code|$(get_failure)"
t "clean patch imports content" "clean change" "$(tail -n 1 "$tmp/repo/file.txt")"
t "clean patch assigns no FAILURE_REASON" "" "$(get_failure_reason)"

# Deterministically simulate a final-import race/failure without copying the
# production algorithm. The shim delegates both --check stages to the real Git
# binary and fails only the actual import, regardless of the leading -C args.
tmp="$(make_case)"
make_repo "$tmp/repo"
mkdir -p "$tmp/base" "$tmp/workspace" "$tmp/bin"
printf 'base\n' > "$tmp/base/file.txt"
printf 'base\nfinal import candidate\n' > "$tmp/workspace/file.txt"
gen_patch "$tmp/final.patch" "$tmp/base" "$tmp/workspace"
real_git="$(command -v git)"
cat > "$tmp/bin/git" <<'MOCK'
#!/usr/bin/env bash
set -uo pipefail
is_apply=false
has_check=false
for arg in "$@"; do
  [ "$arg" = "apply" ] && is_apply=true
  [ "$arg" = "--check" ] && has_check=true
done
if [ "$is_apply" = true ] && [ "$has_check" = false ]; then
  printf '%s\n' 'FINAL_APPLY_SHIM_STDERR' >&2
  exit 86
fi
exec "$REAL_GIT" "$@"
MOCK
chmod +x "$tmp/bin/git"
reset_failures
(
  export REAL_GIT="$real_git"
  export PATH="$tmp/bin:$PATH"
  apply_agent_patch "$tmp/repo" "$tmp/final.patch" 1
) >"$tmp/stdout" 2>"$tmp/stderr"
code=$?
t "final import failure is fail-closed" "1|AGENT_PATCH_INVALID" "$code|$(get_failure)"
t "final import failure adds no durable reason" "" "$(get_failure_reason)"
t "final import failure leaves target unchanged" "base" "$(cat "$tmp/repo/file.txt")"
t "final git stderr remains suppressed" "absent" "$(grep -q 'FINAL_APPLY_SHIM_STDERR' "$tmp/stderr" && echo present || echo absent)"

# Structural contract: the shared helper owns exactly the baseline check,
# strict check, and final import; every stage suppresses git stderr.
apply_source="$(awk '/^apply_agent_patch\(\)/,/^}/ {print}' "$ROOT/scripts/lib/common.sh")"
apply_count="$(printf '%s\n' "$apply_source" | grep -c 'git -C .* apply ' || true)"
suppressed_count="$(printf '%s\n' "$apply_source" | grep 'git -C .* apply ' | grep -c '2>/dev/null' || true)"
baseline_count="$(printf '%s\n' "$apply_source" | grep -c '^[[:space:]]*git -C .* apply --check -p2 ' || true)"
strict_count="$(printf '%s\n' "$apply_source" | grep -c '^[[:space:]]*git -C .* apply --check --whitespace=error -p2 ' || true)"
final_count="$(printf '%s\n' "$apply_source" | grep -c '^[[:space:]]*git -C .* apply --whitespace=error -p2 ' || true)"
reason_count="$(printf '%s\n' "$apply_source" | grep -Ec 'set_failure_reason "(NO_CHANGES|EMPTY_PATCH|PATCH_PARSE_FAILED|PATCH_VALIDATION_FAILED)"' || true)"
t "apply_agent_patch has exactly three git apply stages" "3" "$apply_count"
t "all three git apply stages suppress stderr" "3" "$suppressed_count"
t "baseline parse/applicability check exists once" "1" "$baseline_count"
t "strict whitespace check exists once" "1" "$strict_count"
t "final strict import exists once" "1" "$final_count"
t "durable reason taxonomy has exactly four assignments" "4" "$reason_count"
for reason in NO_CHANGES EMPTY_PATCH PATCH_PARSE_FAILED PATCH_VALIDATION_FAILED; do
  count="$(printf '%s\n' "$apply_source" | grep -Fc "set_failure_reason \"$reason\"" || true)"
  t "durable reason $reason assigned exactly once" "1" "$count"
done

# Both isolated wrappers must delegate to the exact same helper and must not
# reintroduce their own git-apply or diff-status classification logic.
t "ordinary dispatch uses shared patch helper" "yes" "$(grep -Fq 'apply_agent_patch "$target_dir" "$patch_file" "$diff_status"' "$CONTAINER" && echo yes || echo no)"
t "review repair uses shared patch helper" "yes" "$(grep -Fq 'apply_agent_patch "$target_dir" "$patch_file" "$diff_status"' "$REVIEW_CONTAINER" && echo yes || echo no)"
t "review repair preserves successful agent log for outer no-change diagnostics" "yes" "$(grep -Fq 'docker cp "$agent_name:/tmp/agent.log" "$agent_log"' "$REVIEW_CONTAINER" && grep -Fq 'apply_agent_patch "$target_dir" "$patch_file" "$diff_status" "$agent_log" "${OPENROUTER_API_KEY:-}" "$prompt_file"' "$REVIEW_CONTAINER" && echo yes || echo no)"
t "ordinary wrapper has no direct git apply" "yes" "$(! grep -Fq 'git -C "$target_dir" apply' "$CONTAINER" && echo yes || echo no)"
t "review wrapper has no direct git apply" "yes" "$(! grep -Fq 'git -C "$target_dir" apply' "$REVIEW_CONTAINER" && echo yes || echo no)"
t "ordinary wrapper does not classify diff_status" "yes" "$(! grep -Fq '[ "$diff_status" -eq 0 ] || [ "$diff_status" -eq 1 ]' "$CONTAINER" && echo yes || echo no)"
t "review wrapper does not classify diff_status" "yes" "$(! grep -Fq '[ "$diff_status" -eq 0 ] || [ "$diff_status" -eq 1 ]' "$REVIEW_CONTAINER" && echo yes || echo no)"

# Existing model API and timeout failures remain distinct from patch failures.
run_agent_case() { # <tmp> <mock-agent-mode>
  local dir="$1" mode="$2"
  mkdir -p "$dir/bin"
  printf 'trusted prompt\n' > "$dir/prompt"
  cat > "$dir/bin/opencode" <<'MOCK'
#!/usr/bin/env bash
printf 'mock API failure\n'
exit 7
MOCK
  if [ "$mode" = timeout ]; then
    cat > "$dir/bin/timeout" <<'MOCK'
#!/usr/bin/env bash
exit 124
MOCK
    chmod +x "$dir/bin/timeout"
  fi
  chmod +x "$dir/bin/opencode"
  (
    PATH="$dir/bin:$PATH" AGENT=opencode MOCK_AGENT_MODE="$mode" RUNNER_TEMP="$dir" \
      GITHUB_OUTPUT="$dir/out" GITHUB_STEP_SUMMARY="$dir/summary.md" \
      PROMPT_FILE="$dir/prompt" AGENT_LOG="$dir/agent.log" \
      AGENT_USE_PREBUILT_PROMPT=true AGENT_AUTO_INSTALL=false \
      AGENT_MAX_ATTEMPTS=1 AGENT_MAX_RUNTIME=1 OPENROUTER_MODEL=test/model \
      OPENROUTER_API_KEY=mock-openrouter-key
    export AGENT PATH MOCK_AGENT_MODE RUNNER_TEMP GITHUB_OUTPUT GITHUB_STEP_SUMMARY PROMPT_FILE AGENT_LOG \
      AGENT_USE_PREBUILT_PROMPT AGENT_AUTO_INSTALL AGENT_MAX_ATTEMPTS AGENT_MAX_RUNTIME \
      OPENROUTER_MODEL OPENROUTER_API_KEY
    bash "$RUN_AGENT" >"$dir/stdout" 2>"$dir/stderr"
  )
  printf '%s\n' "$?" > "$dir/code"
}

tmp="$(make_case)"
run_agent_case "$tmp" api
t "API failure keeps existing category" "7|MODEL_API_FAILED" "$(cat "$tmp/code")|$(cat "$tmp/failure_category")"

tmp="$(make_case)"
run_agent_case "$tmp" timeout
t "timeout keeps existing category" "124|AGENT_TIMEOUT" "$(cat "$tmp/code")|$(cat "$tmp/failure_category")"

# This source file itself must stay safe for the outer strict patch validator.
t "validation test source has no trailing whitespace" "yes" "$(! grep -n '[[:blank:]]$' "$ROOT/tests/test-agent-validation.sh" >/dev/null && echo yes || echo no)"

finish
