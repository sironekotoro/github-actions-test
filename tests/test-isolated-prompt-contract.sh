#!/usr/bin/env bash
# Regression coverage for the ordinary isolated Agent Dispatch prompt/baseline
# contract. The agent must be able to validate a filesystem diff without .git.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/lib/helpers.sh"

WRAPPER="$ROOT/scripts/run-agent-dispatch-container.sh"
BUILD="$ROOT/scripts/build-agent-prompt.sh"

wrapper_source="$(cat "$WRAPPER")"

t "isolated wrapper selects isolated prompt mode" "yes" "$(grep -q 'AGENT_ISOLATED_WORKSPACE=true TASK_FILE=' "$WRAPPER" && echo yes || echo no)"
t "isolated wrapper mounts baseline read-only" "yes" "$(grep -q 'src=\$base_dir,dst=/baseline,readonly' "$WRAPPER" && echo yes || echo no)"
t "isolated wrapper does not mount target git metadata" "no" "$(grep -Eq 'src=\$target_dir/\.git|dst=/workspace/\.git' "$WRAPPER" && echo yes || echo no)"
t "isolated wrapper still excludes git metadata from staged baseline" "yes" "$(grep -q -- '--exclude=.git' "$WRAPPER" && echo yes || echo no)"

# Verify the exact final-validation command semantics used by the prompt:
# no difference => 0, clean difference => accepted, whitespace error => fail.
tmp="$(make_temp)"
mkdir -p "$tmp/baseline" "$tmp/workspace"
printf 'base\n' > "$tmp/baseline/file.txt"
printf 'base\n' > "$tmp/workspace/file.txt"
(
  cd "$tmp"
  git diff --no-index --check baseline workspace || [ "$?" -eq 1 ]
) >/dev/null 2>&1
t "baseline validation accepts no changes" "0" "$?"

printf 'changed\n' > "$tmp/workspace/file.txt"
(
  cd "$tmp"
  git diff --no-index --check baseline workspace || [ "$?" -eq 1 ]
) >/dev/null 2>&1
t "baseline validation accepts clean changes" "0" "$?"

printf 'changed \n' > "$tmp/workspace/file.txt"
set +e
(
  cd "$tmp"
  git diff --no-index --check baseline workspace || [ "$?" -eq 1 ]
) >/dev/null 2>&1
bad_status=$?
set -e
t "baseline validation rejects trailing whitespace" "nonzero" "$([ "$bad_status" -ne 0 ] && echo nonzero || echo zero)"

# Build a real isolated prompt and ensure no task text is emitted to stdout.
cat > "$tmp/task.json" <<'JSON'
{"task_id":"isolated-contract","target_repository":"sironekotoro/github-actions-test","title":"isolated contract","agent":"codex","source":"test","prompt":"Create one safe file."}
JSON
RUNNER_TEMP="$tmp" TASK_FILE="$tmp/task.json" PROMPT_FILE="$tmp/prompt" \
  AGENT_ISOLATED_WORKSPACE=true bash "$BUILD" >"$tmp/stdout" 2>&1
t "isolated prompt builds" "0" "$?"
t "isolated prompt contains baseline validation" "yes" "$(grep -Fq 'git diff --no-index --check /baseline /workspace || [ "$?" -eq 1 ]' "$tmp/prompt" && echo yes || echo no)"
t "isolated prompt does not leak task body" "no" "$(grep -q 'Create one safe file.' "$tmp/stdout" && echo yes || echo no)"

finish
