#!/usr/bin/env bash
# Negative regression coverage for the .git-free review-repair prompt.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/lib/helpers.sh"

BUILD="$ROOT/scripts/build-review-prompt.sh"
tmp="$(make_temp)"

cat > "$tmp/task.json" <<'JSON'
{
  "target_repository": "sironekotoro/github-actions-test",
  "title": "review prompt contract",
  "source": "issue#1",
  "prompt": "Make the requested safe repair.",
  "review": {
    "head_branch": "agent/review-prompt-contract",
    "pr_number": 1,
    "id": 1,
    "attempt": 1,
    "body": "Please repair the reviewed change."
  }
}
JSON

RUNNER_TEMP="$tmp" TASK_FILE="$tmp/task.json" PROMPT_FILE="$tmp/prompt" \
  bash "$BUILD" >"$tmp/stdout" 2>&1

t "review isolated prompt builds" "0" "$?"
t "review isolated prompt omits legacy git status short" "no" "$(grep -Fq '  git status --short' "$tmp/prompt" && echo yes || echo no)"
t "review isolated prompt omits legacy standalone git diff check" "no" "$(grep -Fxq '  git diff --check' "$tmp/prompt" && echo yes || echo no)"
t "review isolated prompt keeps baseline validation" "yes" "$(grep -Fq 'git diff --no-index --check /baseline /workspace || [ \"$?\" -eq 1 ]' "$tmp/prompt" && echo yes || echo no)"

finish
