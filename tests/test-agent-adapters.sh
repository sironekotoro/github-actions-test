#!/usr/bin/env bash
# Adapter-level regression coverage. These tests assert the exact noninteractive
# CLI shape, timeout wrapper, and selected-credential environment without making
# a network request to any provider.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/lib/helpers.sh"

run_success_case() { # <adapter> <binary> <source-credential-var> <credential-value> <runtime-credential-var> <expected-cli>
  local adapter="$1" binary="$2" credential_var="$3" credential_value="$4" runtime_credential_var="$5" expected_cli="$6"
  local tmp; tmp="$(make_temp)"
  mkdir -p "$tmp/bin"

  cat > "$tmp/bin/$binary" <<MOCK
#!/usr/bin/env bash
printf '%s\\n' "\$@" > "$tmp/argv"
{
  printf 'OPENROUTER_API_KEY=%s\\n' "\${OPENROUTER_API_KEY+x}"
  printf 'OPENAI_API_KEY=%s\\n' "\${OPENAI_API_KEY+x}"
  printf 'CODEX_API_KEY=%s\\n' "\${CODEX_API_KEY+x}"
  printf 'ANTHROPIC_API_KEY=%s\\n' "\${ANTHROPIC_API_KEY+x}"
  printf 'GH_TOKEN=%s\\n' "\${GH_TOKEN+x}"
  printf 'GITHUB_TOKEN=%s\\n' "\${GITHUB_TOKEN+x}"
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
    export CODEX_API_KEY=unrelated-codex
    export ANTHROPIC_API_KEY=unrelated-anthropic
    export GH_TOKEN=unrelated-gh
    export GITHUB_TOKEN=unrelated-github
    source "$ROOT/scripts/agents/$adapter.sh"
    agent_run test/model 'prompt with spaces; $HOME must stay literal' "$tmp/log" 2 "$credential_var" "$credential_value"
  )
  local status=$?

  t "$adapter adapter succeeds" "0" "$status"
  t "$adapter timeout is applied" "2m" "$(cat "$tmp/timeout")"
  t "$adapter selects only its runtime credential" "${runtime_credential_var}=x" "$(grep -E "^${runtime_credential_var}=" "$tmp/env")"
  for other in OPENROUTER_API_KEY OPENAI_API_KEY CODEX_API_KEY ANTHROPIC_API_KEY GH_TOKEN GITHUB_TOKEN; do
    if [ "$other" != "$runtime_credential_var" ]; then
      t "$adapter excludes $other" "${other}=" "$(grep -E "^${other}=" "$tmp/env")"
    fi
  done
  t "$adapter does not log selected credential value" "absent" "$(grep -Fq "$credential_value" "$tmp/log" 2>/dev/null && echo present || echo absent)"

  case "$expected_cli" in
    opencode)
      t "OpenCode uses run" run "$(sed -n '1p' "$tmp/argv")"
      t "OpenCode auto-approves inside outer sandbox" --auto "$(sed -n '2p' "$tmp/argv")"
      t "OpenCode selects writable build agent" --agent "$(sed -n '3p' "$tmp/argv")"
      t "OpenCode build agent value" build "$(sed -n '4p' "$tmp/argv")"
      t "OpenCode uses print logs" --print-logs "$(sed -n '5p' "$tmp/argv")"
      t "OpenCode receives one prompt argument" 'prompt with spaces; $HOME must stay literal' "$(tail -n 1 "$tmp/argv")"
      ;;
    codex)
      t "Codex uses exec" exec "$(sed -n '1p' "$tmp/argv")"
      t "Codex binds requested model with -m" -m "$(sed -n '2p' "$tmp/argv")"
      t "Codex requested model value" test/model "$(sed -n '3p' "$tmp/argv")"
      t "Codex relies on external sandbox" --dangerously-bypass-approvals-and-sandbox "$(sed -n '4p' "$tmp/argv")"
      t "Codex uses --skip-git-repo-check" --skip-git-repo-check "$(sed -n '5p' "$tmp/argv")"
      t "Codex receives one prompt argument" 'prompt with spaces; $HOME must stay literal' "$(sed -n '6p' "$tmp/argv")"
      t "Codex does not request nested workspace sandbox" "absent" "$(grep -qx -- '--sandbox' "$tmp/argv" && echo present || echo absent)"
      t "Codex adapter does not use legacy run" no "$(grep -qx run "$tmp/argv" && echo yes || echo no)"
      ;;
    claude-code)
      t "Claude Code uses print flag" -p "$(sed -n '1p' "$tmp/argv")"
      t "Claude Code receives one prompt argument" 'prompt with spaces; $HOME must stay literal' "$(sed -n '2p' "$tmp/argv")"
      ;;
  esac
}

run_success_case opencode opencode OPENROUTER_API_KEY selected-openrouter OPENROUTER_API_KEY opencode
run_success_case codex codex OPENAI_API_KEY selected-openai CODEX_API_KEY codex
run_success_case claude-code claude ANTHROPIC_API_KEY selected-anthropic ANTHROPIC_API_KEY claude-code

# The production image deliberately pins the exact OpenCode release whose run
# contract supports --auto and --agent. Do not silently drift to an invented
# per-permission CLI flag: v1.18.16 handles permission prompts through --auto.
t "OpenCode production CLI stays pinned at 1.18.16" "yes" "$(grep -Fq 'opencode-ai@1.18.16' "$ROOT/docker/review-repair-agent.Dockerfile" && echo yes || echo no)"
t "OpenCode adapter does not use unsupported --permission flag" "absent" "$(grep -Eq -- '(^|[[:space:]])--permission([[:space:]]|$)' "$ROOT/scripts/agents/opencode.sh" && echo present || echo absent)"
t "Codex production CLI stays pinned at 0.147.0" "yes" "$(grep -Fq 'CODEX_CLI_VERSION=0.147.0' "$ROOT/docker/review-repair-agent.Dockerfile" && echo yes || echo no)"
t "Codex adapter always forwards model flag" "yes" "$(grep -Fq 'codex exec -m "$model"' "$ROOT/scripts/agents/codex.sh" && echo yes || echo no)"

# A non-auth Codex provider failure must still be classified by the shared
# run-agent loop, not mistaken for an unavailable CLI or an auth failure.
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
  export AGENT_MODEL=test/model
  bash "$ROOT/scripts/run-agent.sh" >"$tmp/stdout" 2>"$tmp/stderr"
)
status=$?
t "Codex API failure returns CLI status" "7" "$status"
t "Codex API failure is classified" "MODEL_API_FAILED" "$(cat "$tmp/failure_category")"

# A deterministic 401 from Codex is authentication failure, not a transient
# model/provider failure. It must not consume the second configured attempt.
tmp="$(make_temp)"
mkdir -p "$tmp/bin"
cat > "$tmp/bin/codex" <<MOCK
#!/usr/bin/env bash
if [ "\${1:-}" = "--version" ]; then
  echo 'mock codex 0.147.0'
  exit 0
fi
count=0
[ -f "$tmp/invocations" ] && count="\$(cat "$tmp/invocations")"
printf '%s\\n' "\$((count + 1))" > "$tmp/invocations"
echo 'unexpected status 401 Unauthorized: Missing bearer or basic authentication in header' >&2
exit 1
MOCK
chmod +x "$tmp/bin/codex"
printf 'trusted prompt\n' > "$tmp/prompt"
printf '%s\n' '{"agent":"codex"}' > "$tmp/task.json"
(
  export PATH="$tmp/bin:$PATH"
  export RUNNER_TEMP="$tmp" TASK_FILE="$tmp/task.json" PROMPT_FILE="$tmp/prompt"
  export AGENT_LOG="$tmp/agent.log" GITHUB_STEP_SUMMARY="$tmp/summary" GITHUB_OUTPUT="$tmp/output"
  export AGENT_USE_PREBUILT_PROMPT=true AGENT_AUTO_INSTALL=false AGENT_MAX_ATTEMPTS=2
  export AGENT_CREDENTIAL_PROFILE=openai-api AGENT_CREDENTIAL_VALUE=selected-openai-secret-marker
  export AGENT_MODEL=test/model
  bash "$ROOT/scripts/run-agent.sh" >"$tmp/stdout" 2>"$tmp/stderr"
)
status=$?
t "Codex 401 returns CLI status" "1" "$status"
t "Codex 401 is classified as auth failure" "AGENT_AUTH_FAILED" "$(cat "$tmp/failure_category")"
t "Codex 401 is not retried" "1" "$(cat "$tmp/invocations")"
t "Codex auth failure does not log key value" "absent" "$(grep -Fq 'selected-openai-secret-marker' "$tmp/stdout" "$tmp/stderr" "$tmp/agent.log" "$tmp/summary" 2>/dev/null && echo present || echo absent)"

finish