#!/usr/bin/env bash
# Test 10: prompt must automatically include the target repository identity
# and verification commands.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/helpers.sh
source "$ROOT/tests/lib/helpers.sh"

BUILD="$ROOT/scripts/build-agent-prompt.sh"

tmp="$(make_temp)"
cat > "$tmp/task.json" <<'JSON'
{"task_id":"t10","target_repository":"sironekotoro/github-actions-test","title":"x","prompt":"Do a thing."}
JSON

( RUNNER_TEMP="$tmp" GITHUB_STEP_SUMMARY="$tmp/summary.md" TASK_FILE="$tmp/task.json" PROMPT_FILE="$tmp/agent-prompt.txt" \
    bash "$BUILD" >"$tmp/stdout.log" 2>&1 )
t "T10 build exit ok" "0" "$?"

prompt="$(cat "$tmp/agent-prompt.txt")"

case "$prompt" in
  *"TARGET REPOSITORY:"*) t "T10 target repository header present" "yes" "yes" ;;
  *) t "T10 target repository header present" "yes" "no" ;;
esac
case "$prompt" in
  *"sironekotoro/github-actions-test"*) t "T10 repo name present" "yes" "yes" ;;
  *) t "T10 repo name present" "yes" "no" ;;
esac
for cmd in "git remote -v" "git branch" "git status" "STOP WITHOUT MAKING CHANGES" "AGENTS.md"; do
  case "$prompt" in
    *"$cmd"*) t "T10 contains [$cmd]" "yes" "yes" ;;
    *) t "T10 contains [$cmd]" "yes" "no" ;;
  esac
done

# prompt body must be in file, not in stdout log
if grep -q "Do a thing." "$tmp/stdout.log"; then
  t "T10 prompt body not leaked to log" "no" "yes"
else
  t "T10 prompt body not leaked to log" "no" "no"
fi

finish