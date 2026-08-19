#!/usr/bin/env bash
# Test: prompt/secret-like strings must never leak into the step summary.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/helpers.sh
source "$ROOT/tests/lib/helpers.sh"

BUILD="$ROOT/scripts/build-agent-prompt.sh"

tmp="$(make_temp)"
secret='sk-or-v1-fakefakefakefakefake00000000000000000000'
payload="Do not print this secret: \${secrets.OPENROUTER_API_KEY} or $secret"

cat > "$tmp/task.json" <<JSON
{"task_id":"red","target_repository":"sironekotoro/github-actions-test","title":"redaction","prompt":$(node -e 'process.stdout.write(JSON.stringify(process.argv[1]))' "$payload")}
JSON

( RUNNER_TEMP="$tmp" GITHUB_STEP_SUMMARY="$tmp/summary.md" TASK_FILE="$tmp/task.json" PROMPT_FILE="$tmp/agent-prompt.txt" \
    bash "$BUILD" >"$tmp/stdout.log" 2>"$tmp/stderr.log" )
code=$?
t "T33 build exit ok" "0" "$code"

# summary and stdout must not contain the fake secret or the payload
for f in "$tmp/summary.md" "$tmp/stdout.log" "$tmp/stderr.log"; do
  if grep -q "$secret" "$f" 2>/dev/null; then
    t "T33 $(basename "$f") does not leak fake token" "no" "yes"
  else
    t "T33 $(basename "$f") does not leak fake token" "no" "no"
  fi
  if grep -q 'secrets.OPENROUTER_API_KEY' "$f" 2>/dev/null; then
    t "T33 $(basename "$f") does not leak secrets.OPENROUTER_API_KEY" "no" "yes"
  else
    t "T33 $(basename "$f") does not leak secrets.OPENROUTER_API_KEY" "no" "no"
  fi
done

# prompt file itself must contain the identity guard
grep -q "TARGET REPOSITORY:" "$tmp/agent-prompt.txt"
t "T33 prompt file built" "0" "$?"

finish