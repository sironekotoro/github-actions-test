#!/usr/bin/env bash
# Adapter-level regression coverage. These tests assert the exact noninteractive
# CLI shape, timeout wrapper, and selected-credential environment without making
# a network request to any provider.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/lib/helpers.sh"

run_success_case() { # <adapter> <binary> <credential-var> <credential-value> <expected-cli>
  local adapter="$1" binary="$2" credential_var="$3" credential_value="$4" expected_cli="$5"
  local tmp; tmp="$(make_temp)"
  mkdir -p "$tmp/bin"

  cat > "$tmp/bin/$binary" <<MOCK
#!/usr/bin/env bash
printf '%s\\n' "\$@" > "$tmp/argv"
{
  printf 'OPENROUTER_API_KEY=%s\\n' "\${OPENROUTER_API_KEY+x}"
  printf 'OPENAI_API_KEY=%s\\n' "\${OPENAI_API_KEY+x}"
  printf 'ANTHROPIC_API_KEY=%s\\n' "\${ANTHROPIC_API_KEY+x}"
} > "$tmp/env"
exit 0
MOCK
  cat > "$tmp/bin/timeout" <<MOCK
#!/usr/bin/env bash
printf '%s\\n' "\$1" > "$tmp/timeout"
shift
"\$@"
MOCK
  chmod +x "$tmp/bin/$binary" "$tmp/bin/timeout"

  (
    export PATH="$tmp/bin:$PATH"
    export OPENROUTER_API_KEY=unrelated-openrouter
    export OPENAI_API_KEY=unrelated-openai
    export ANTHROPIC_API_KEY=unrelated-anthropic
    source "$ROOT/scripts/agents/$adapter.sh"
    agent_run test/model 'prompt with spaces; $HOME must stay literal' "$tmp/log" 2 "$credential_var" "$credential_value"
  )
  local status=$?

  t "$adapter adapter succeeds" "0" "$status"
  t "$adapter timeout is applied" "2m" "$(cat "$tmp/timeout")"
  t "$adapter selects only its credential" "${credential_var}=x" "$(grep -E "^${credential_var}=" "$tmp/env")"
  for other in OPENROUTER_API_KEY OPENAI_API_KEY ANTHROPIC_API_KEY; do
    if [ "$other" != "$credential_var" ]; then
      t "$adapter excludes $other" "${other}=" "$(grep -E "^${other}=" "$tmp/env")"
    fi
  done

  case "$expected_cli" in
    opencode)
      t "OpenCode uses run" run "$(sed -n '1p' "$tmp/argv")"
      t "OpenCode uses print logs" --print-logs "$(sed -n '2p' "$tmp/argv")"
      t "OpenCode receives one prompt argument" 'prompt with spaces; $HOME must stay literal' "$(tail -n 1 "$tmp/argv")"
      ;;
    codex)
      t "Codex uses exec" exec "$(sed -n '1p' "$tmp/argv")"
      t "Codex uses --skip-git-repo-check" --skip-git-repo-check "$(sed -n '2p' "$tmp/argv")"
      t "Codex receives one prompt argument" 'prompt with spaces; $HOME must stay literal' "$(sed -n '3p' "$tmp/argv")"
      t "Codex adapter does not use legacy run" no "$(grep -qx run "$tmp/argv" && echo yes || echo no)"
      ;;
    claude-code)
      t "Claude Code uses print flag" -p "$(sed -n '1p' "$tmp/argv")"
      t "Claude Code receives one prompt argument" 'prompt with spaces; $HOME must stay literal' "$(sed -n '2p' "$tmp/argv")"
      ;;
  esac
}

run_success_case opencode opencode OPENROUTER_API_KEY selected-openrouter opencode
run_success_case codex codex OPENAI_API_KEY selected-openai codex
run_success_case claude-code claude ANTHROPIC_API_KEY selected-anthropic claude-code

# A Codex provider failure must still be classified by the shared run-agent
# loop, not mistaken for an unavailable CLI or an unknown agent.
tmp="$(make_temp)"
mkdir -p "$tmp/bin"
cat > "$tmp/bin/codex" <<'MOCK'
#!/usr/bin/env bash
if [ "${1:-}" = "--version" ]; then
  echo 'mock codex 0.147.0'
  exit 0
fi
echo 'mock provider failure' >&2
exit 7
MOCK
chmod +x "$tmp/bin/codex"
printf 'trusted prompt\n' > "$tmp/prompt"
printf '%s\n' '{"agent":"codex"}' > "$tmp/task.json"
(
  export PATH="$tmp/bin:$PATH"
  export RUNNER_TEMP="$tmp" TASK_FILE="$tmp/task.json" PROMPT_FILE="$tmp/prompt"
  export AGENT_LOG="$tmp/agent.log" GITHUB_STEP_SUMMARY="$tmp/summary" GITHUB_OUTPUT="$tmp/output"
  export AGENT_USE_PREBUILT_PROMPT=true AGENT_AUTO_INSTALL=false AGENT_MAX_ATTEMPTS=1
  export AGENT_CREDENTIAL_PROFILE=openai-api AGENT_CREDENTIAL_VALUE=selected-openai
  export OPENAI_API_KEY=selected-openai
  bash "$ROOT/scripts/run-agent.sh" >"$tmp/stdout" 2>"$tmp/stderr"
)
status=$?
t "Codex API failure returns CLI status" "7" "$status"
t "Codex API failure is classified" "MODEL_API_FAILED" "$(cat "$tmp/failure_category")"

finish
