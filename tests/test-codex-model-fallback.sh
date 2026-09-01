#!/usr/bin/env bash
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/lib/helpers.sh"

run_case() { # <code_model_env> <expected_model>
  local codex_model="$1" expected="$2"
  local tmp; tmp="$(make_temp)"
  mkdir -p "$tmp/bin"

  cat > "$tmp/bin/codex" <<MOCK
#!/usr/bin/env bash
if [ "\${1:-}" = "--version" ]; then
  echo 'codex-cli 0.147.0'
  exit 0
fi
printf '%s\\n' "\$@" > "$tmp/argv"
exit 0
MOCK
  cat > "$tmp/bin/timeout" <<MOCK
#!/usr/bin/env bash
shift
"\$@"
MOCK
  chmod +x "$tmp/bin/codex" "$tmp/bin/timeout"
  printf 'trusted prompt\n' > "$tmp/prompt"

  (
    export PATH="$tmp/bin:$PATH"
    export RUNNER_TEMP="$tmp"
    export PROMPT_FILE="$tmp/prompt"
    export AGENT_LOG="$tmp/agent.log"
    export GITHUB_OUTPUT="$tmp/output"
    export GITHUB_STEP_SUMMARY="$tmp/summary"
    export AGENT=codex
    export AGENT_USE_PREBUILT_PROMPT=true
    export AGENT_CREDENTIAL_PROFILE=openai-api
    export AGENT_CREDENTIAL_VALUE=fake-local-key
    export AGENT_MAX_ATTEMPTS=1
    export OPENROUTER_MODEL=openrouter/should-never-reach-codex
    unset AGENT_MODEL
    if [ -n "$codex_model" ]; then export CODEX_MODEL="$codex_model"; else unset CODEX_MODEL; fi
    bash "$ROOT/scripts/run-agent.sh" >/dev/null 2>&1
  )
  local status=$?
  t "Codex fallback invocation succeeds" "0" "$status"
  t "Codex fallback passes -m" "-m" "$(sed -n '2p' "$tmp/argv")"
  t "Codex fallback model is isolated from OpenRouter default" "$expected" "$(sed -n '3p' "$tmp/argv")"
}

run_case '' 'gpt-5.6-sol'
run_case 'gpt-trusted-override' 'gpt-trusted-override'

# Static guard: the common runner must not use OPENROUTER_MODEL as the Codex
# fallback after B2a model-binding hardening.
t "run-agent defines a Codex-specific fallback" "yes" \
  "$(grep -Fq 'CODEX_MODEL:-gpt-5.6-sol' "$ROOT/scripts/run-agent.sh" && echo yes || echo no)"

finish
