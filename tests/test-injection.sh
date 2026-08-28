#!/usr/bin/env bash
# Test: command-injection payloads must NOT be executed by the agent runner.
# The prompt is passed as a single quoted argument, never shell-interpolated.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/helpers.sh
source "$ROOT/tests/lib/helpers.sh"

RUN_AGENT="$ROOT/scripts/run-agent.sh"

tmp="$(make_temp)"

# malicious prompt
prompt='Normal task here.
$(touch /tmp/agent-pwned-PWNED)
`touch /tmp/agent-pwned-BACKTICK`
"; touch /tmp/agent-pwned-SEMI; "
| touch /tmp/agent-pwned-PIPE
%0A touch /tmp/agent-pwned-URLENC'

cat > "$tmp/task.json" <<JSON
{"task_id":"inj","target_repository":"sironekotoro/github-actions-test","title":"injection","prompt":$(node -e 'process.stdout.write(JSON.stringify(process.argv[1]))' "$prompt")}
JSON

# mock opencode that records its arguments instead of doing anything
mkdir -p "$tmp/bin"
cat > "$tmp/bin/opencode" <<MOCK
#!/usr/bin/env bash
echo "\$#" > "$tmp/argcount"
printf '%s' "\${@: -1}" > "$tmp/lastarg"
exit 0
MOCK
chmod +x "$tmp/bin/opencode"

( cd "$tmp" || exit 1
  export PATH="$tmp/bin:$PATH" MOCK_FILE="$tmp/argcount" MOCK_LASTARG="$tmp/lastarg"
  export RUNNER_TEMP="$tmp" GITHUB_OUTPUT="$tmp/out.txt" GITHUB_STEP_SUMMARY="$tmp/summary.md"
  export TASK_FILE="$tmp/task.json" PROMPT_FILE="$tmp/agent-prompt.txt" AGENT_LOG="$tmp/agent.log"
  export OPENROUTER_API_KEY="mock-openrouter-key" OPENROUTER_MODEL="test/model"
  bash "$RUN_AGENT" >"$tmp/stdout.log" 2>"$tmp/stderr.log" )
code=$?
t "T32 agent exits 0" "0" "$code"

# opencode must have received exactly 5 args: run --print-logs -m model <prompt>
t "T32 opencode arg count == 5" "5" "$(cat "$tmp/argcount" 2>/dev/null)"
built_prompt="$(cat "$tmp/agent-prompt.txt" 2>/dev/null)"
t "T32 prompt passed as single last arg" "yes" "$(test "$(cat "$tmp/lastarg" 2>/dev/null)" = "$built_prompt" && echo yes || echo no)"

# injection payloads must NOT be executed
for f in /tmp/agent-pwned-PWNED /tmp/agent-pwned-BACKTICK /tmp/agent-pwned-SEMI /tmp/agent-pwned-PIPE /tmp/agent-pwned-URLENC; do
  rm -f "$f"
done
for f in /tmp/agent-pwned-PWNED /tmp/agent-pwned-BACKTICK /tmp/agent-pwned-SEMI /tmp/agent-pwned-PIPE /tmp/agent-pwned-URLENC; do
  if [ -e "$f" ]; then
    t "T32 [$f] not created" "no" "yes"
  else
    t "T32 [$f] not created" "no" "no"
  fi
done

finish
