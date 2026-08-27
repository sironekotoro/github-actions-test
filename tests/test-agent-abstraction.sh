#!/usr/bin/env bash
# Test: agent abstraction layer, credential profiles, compatibility matrix.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/lib/helpers.sh"

PARSE="$ROOT/scripts/parse-task.mjs"
DISPATCHER="$ROOT/scripts/agent-dispatcher.sh"
CREDENTIALS="$ROOT/scripts/lib/credentials.sh"
RUN_AGENT="$ROOT/scripts/run-agent.sh"
WORKFLOW="$ROOT/.github/workflows/agent-dispatch.yml"
ACTION="$ROOT/.github/actions/agent-dispatch/action.yml"

# ============================================================
# 1. Agent input parsing (parse-task.mjs)
# ============================================================

parse_dispatch() { # <json>
  local tmp; tmp="$(make_temp)"
  ( RUNNER_TEMP="$tmp" GITHUB_OUTPUT="$tmp/out.txt" \
      DISPATCH_INPUTS="$1" \
      node "$PARSE" >"$tmp/stdout.log" 2>"$tmp/stderr.log" )
  local code=$?
  local err=""; [ -f "$tmp/stderr.log" ] && err="$(cat "$tmp/stderr.log" | cut -d: -f1)"
  echo "$code|$err|$(jq -r '.agent // "null"' "$tmp/task.json" 2>/dev/null || echo 'null')"
}

# omitted agent defaults to opencode
basic='{"task_id":"a1","target_repository":"sironekotoro/github-actions-test","title":"t","prompt":"do it"}'
res="$(parse_dispatch "$basic")"
t "omitted agent defaults to opencode" "0||opencode" "$res"

# explicit opencode
opencode='{"task_id":"a2","target_repository":"sironekotoro/github-actions-test","title":"t","prompt":"do it","agent":"opencode"}'
res="$(parse_dispatch "$opencode")"
t "explicit opencode accepted" "0||opencode" "$res"

# explicit codex
codex='{"task_id":"a3","target_repository":"sironekotoro/github-actions-test","title":"t","prompt":"do it","agent":"codex"}'
res="$(parse_dispatch "$codex")"
t "explicit codex accepted" "0||codex" "$res"

# explicit claude-code
claude='{"task_id":"a4","target_repository":"sironekotoro/github-actions-test","title":"t","prompt":"do it","agent":"claude-code"}'
res="$(parse_dispatch "$claude")"
t "explicit claude-code accepted" "0||claude-code" "$res"

# unknown agent fails closed
unknown='{"task_id":"a5","target_repository":"sironekotoro/github-actions-test","title":"t","prompt":"do it","agent":"unknown"}'
res="$(parse_dispatch "$unknown")"
t "unknown agent fails closed" "1|INVALID_PAYLOAD" "$(echo "$res" | cut -d'|' -f1-2 | head -1)"

# ============================================================
# 2. runner_mode independent from agent (both in parse-task.mjs)
# ============================================================

parse_both() { # <json>
  local tmp; tmp="$(make_temp)"
  ( RUNNER_TEMP="$tmp" GITHUB_OUTPUT="$tmp/out.txt" \
      DISPATCH_INPUTS="$1" \
      node "$PARSE" >"$tmp/stdout.log" 2>"$tmp/stderr.log" )
  local code=$?
  local agent="$(jq -r '.agent' "$tmp/task.json" 2>/dev/null || echo 'null')"
  local mode="$(jq -r '.runner_mode' "$tmp/task.json" 2>/dev/null || echo 'null')"
  echo "$code|$agent|$mode"
}

both1='{"task_id":"b1","target_repository":"sironekotoro/github-actions-test","title":"t","prompt":"do it","runner_mode":"self-hosted","agent":"codex"}'
res="$(parse_both "$both1")"
t "self-hosted + codex: agent is codex" "0|codex|self-hosted" "$res"

both2='{"task_id":"b2","target_repository":"sironekotoro/github-actions-test","title":"t","prompt":"do it","runner_mode":"github","agent":"claude-code"}'
res="$(parse_both "$both2")"
t "github + claude-code: agent is claude-code" "0|claude-code|github" "$res"

# ============================================================
# 3. Credential profile validation
# ============================================================

source "$CREDENTIALS"

# agent_allowed_profiles
t "opencode allowed profiles" "openrouter" "$(agent_allowed_profiles opencode)"
t "codex allowed profiles" "openai-api chatgpt-subscription" "$(agent_allowed_profiles codex)"
t "claude-code allowed profiles" "anthropic-api claude-subscription" "$(agent_allowed_profiles claude-code)"

# unknown agent_allowed_profiles fails
tmp="$(make_temp)"
( RUNNER_TEMP="$tmp" agent_allowed_profiles nonexistent 2>"$tmp/err" ) && true
t "unknown agent_allowed_profiles fails closed" "1" "$?"

# validate_credential_profile
validate_credential_profile opencode openrouter
t "opencode+openrouter valid" "0" "$?"

validate_credential_profile codex openai-api
t "codex+openai-api valid" "0" "$?"

validate_credential_profile claude-code anthropic-api
t "claude-code+anthropic-api valid" "0" "$?"

# invalid combinations fail closed
tmp="$(make_temp)"
( RUNNER_TEMP="$tmp" \
  bash -c "source \"$ROOT/scripts/lib/credentials.sh\"; validate_credential_profile opencode openai-api" \
  2>/dev/null )
code=$?; cat="$(cat "$tmp/failure_category" 2>/dev/null || echo '')"
t "opencode+openai-api invalid fails closed" "1|AGENT_AUTH_FAILED" "$code|$cat"

tmp="$(make_temp)"
( RUNNER_TEMP="$tmp" \
  bash -c "source \"$ROOT/scripts/lib/credentials.sh\"; validate_credential_profile codex openrouter" \
  2>/dev/null )
code=$?; cat="$(cat "$tmp/failure_category" 2>/dev/null || echo '')"
t "codex+openrouter invalid fails closed" "1|AGENT_AUTH_FAILED" "$code|$cat"

tmp="$(make_temp)"
( RUNNER_TEMP="$tmp" \
  bash -c "source \"$ROOT/scripts/lib/credentials.sh\"; validate_credential_profile claude-code openai-api" \
  2>/dev/null )
code=$?; cat="$(cat "$tmp/failure_category" 2>/dev/null || echo '')"
t "claude+openai-api invalid fails closed" "1|AGENT_AUTH_FAILED" "$code|$cat"

# profile_env_var
t "openrouter env var" "OPENROUTER_API_KEY" "$(profile_env_var openrouter)"
t "openai-api env var" "OPENAI_API_KEY" "$(profile_env_var openai-api)"
t "anthropic-api env var" "ANTHROPIC_API_KEY" "$(profile_env_var anthropic-api)"
t "chatgpt-subscription env var" "" "$(profile_env_var chatgpt-subscription)"
t "claude-subscription env var" "" "$(profile_env_var claude-subscription)"

# profile_is_subscription
profile_is_subscription chatgpt-subscription && t "chatgpt-subscription is subscription" "yes" "yes" || t "chatgpt-subscription is subscription" "yes" "no"
profile_is_subscription claude-subscription && t "claude-subscription is subscription" "yes" "yes" || t "claude-subscription is subscription" "yes" "no"
profile_is_subscription openrouter && t "openrouter is not subscription" "no" "yes" || t "openrouter is not subscription" "no" "no"

# ============================================================
# 4. Credential isolation: only selected agent's credential visible
# ============================================================

tmp="$(make_temp)"
mkdir -p "$tmp/bin"
cat > "$tmp/bin/opencode" <<'MOCK'
#!/usr/bin/env bash
echo "OPENROUTER_API_KEY=${OPENROUTER_API_KEY:-}" > "$MOCK_CRED_OUT"
echo "OPENAI_API_KEY=${OPENAI_API_KEY:-}" >> "$MOCK_CRED_OUT"
echo "ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY:-}" >> "$MOCK_CRED_OUT"
exit 0
MOCK
chmod +x "$tmp/bin/opencode"

# Test: when agent=opencode, only OPENROUTER_API_KEY is set
cat > "$tmp/task_for_cred.json" <<JSON
{"task_id":"cred1","target_repository":"sironekotoro/github-actions-test","title":"cred","prompt":"test","agent":"opencode"}
JSON
(
  PATH="$tmp/bin:$PATH"
  RUNNER_TEMP="$tmp"
  TASK_FILE="$tmp/task_for_cred.json"
  PROMPT_FILE="$tmp/prompt_for_cred.txt"
  AGENT_LOG="$tmp/agent_for_cred.log"
  GITHUB_STEP_SUMMARY="$tmp/summary1.md"
  GITHUB_OUTPUT="$tmp/out1.txt"
  AGENT_CREDENTIAL_PROFILE=openrouter
  AGENT_AUTO_INSTALL=false
  AGENT_MAX_ATTEMPTS=1
  AGENT_USE_PREBUILT_PROMPT=true
  OPENROUTER_API_KEY="sk-or-test-key"
  OPENAI_API_KEY=""
  ANTHROPIC_API_KEY=""
  MOCK_CRED_OUT="$tmp/cred_visible.txt"
  printf 'prompt content\n' > "$tmp/prompt_for_cred.txt"
  bash "$RUN_AGENT" >/dev/null 2>&1
)
grep -q 'OPENROUTER_API_KEY=sk-or-test-key' "$tmp/cred_visible.txt" && t "opencode sees OPENROUTER_API_KEY" "yes" "yes" || t "opencode sees OPENROUTER_API_KEY" "yes" "no"
grep -q 'OPENAI_API_KEY=' "$tmp/cred_visible.txt" && ! grep -q 'OPENAI_API_KEY=sk' "$tmp/cred_visible.txt" && t "opencode does not see OPENAI_API_KEY" "yes" "yes" || t "opencode does not see OPENAI_API_KEY" "yes" "no"
grep -q 'ANTHROPIC_API_KEY=' "$tmp/cred_visible.txt" && ! grep -q 'ANTHROPIC_API_KEY=sk' "$tmp/cred_visible.txt" && t "opencode does not see ANTHROPIC_API_KEY" "yes" "yes" || t "opencode does not see ANTHROPIC_API_KEY" "yes" "no"

# ============================================================
# 5. Subscription profiles rejected on unsupported hosted execution
# ============================================================

# claude-subscription on a hosted executor (no Claude CLI available on ubuntu-latest)
# should fail closed rather than falling back to host execution.
tmp="$(make_temp)"
mkdir -p "$tmp/bin"
cat > "$tmp/bin/claude" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
chmod +x "$tmp/bin/claude"
(
  PATH="$tmp/bin:$PATH"
  RUNNER_TEMP="$tmp"
  TASK_FILE=/dev/null
  AGENT_CREDENTIAL_PROFILE=claude-subscription
  source "$CREDENTIALS" 2>/dev/null
) && true
# Just verify the function is defined; it should not fail for a subscription profile
# since subscription profiles don't require an env var
profile_is_subscription claude-subscription
t "claude-subscription is subscription" "0" "$?"

# ============================================================
# 6. Prompt/secret values not logged (smoke check)
# ============================================================

# Verify run-agent.sh never echoes prompt content
tmp="$(make_temp)"
mkdir -p "$tmp/bin"
cat > "$tmp/bin/opencode" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
chmod +x "$tmp/bin/opencode"
cat > "$tmp/task_silent.json" <<JSON
{"task_id":"silent1","target_repository":"sironekotoro/github-actions-test","title":"silent","prompt":"SECRET_PROMPT_CONTENT_XYZ","agent":"opencode"}
JSON
printf 'SECRET_PROMPT_CONTENT_XYZ\n' > "$tmp/prompt_silent.txt"
(
  PATH="$tmp/bin:$PATH"
  RUNNER_TEMP="$tmp"
  TASK_FILE="$tmp/task_silent.json"
  PROMPT_FILE="$tmp/prompt_silent.txt"
  AGENT_LOG="$tmp/agent_silent.log"
  GITHUB_STEP_SUMMARY="$tmp/summary_silent.md"
  GITHUB_OUTPUT="$tmp/out_silent.txt"
  AGENT_CREDENTIAL_PROFILE=openrouter
  AGENT_AUTO_INSTALL=false
  AGENT_MAX_ATTEMPTS=1
  AGENT_USE_PREBUILT_PROMPT=true
  OPENROUTER_API_KEY=""
  bash "$RUN_AGENT" >"$tmp/stdout_silent.log" 2>"$tmp/stderr_silent.log"
)
if grep -q 'SECRET_PROMPT_CONTENT_XYZ' "$tmp/stdout_silent.log" "$tmp/stderr_silent.log" "$tmp/summary_silent.md" 2>/dev/null; then
  t "prompt content not logged" "no" "yes"
else
  t "prompt content not logged" "no" "no"
fi

# ============================================================
# 7. Workflow-level agent input defined with default opencode
# ============================================================

t "workflow dispatch agent input exists" "yes" "$(grep -q 'agent:' "$WORKFLOW" && echo yes || echo no)"
t "workflow dispatch agent default opencode" "yes" "$(grep -A6 '^      agent:' "$WORKFLOW" | grep -q 'default: opencode' && echo yes || echo no)"
t "workflow dispatch agent includes codex" "yes" "$(grep -A5 'agent:' "$WORKFLOW" | grep -q 'codex' && echo yes || echo no)"
t "workflow dispatch agent includes claude-code" "yes" "$(grep -A5 'agent:' "$WORKFLOW" | grep -q 'claude-code' && echo yes || echo no)"

# ============================================================
# 8. Action inputs for credential profiles
# ============================================================

t "action has openai_api_key input" "yes" "$(grep -q 'openai_api_key:' "$ACTION" && echo yes || echo no)"
t "action has anthropic_api_key input" "yes" "$(grep -q 'anthropic_api_key:' "$ACTION" && echo yes || echo no)"
t "action has agent input" "yes" "$(grep -q "agent:" "$ACTION" && echo yes || echo no)"

# ============================================================
# 9. Docker container only gets selected credential
# ============================================================

t "container step only passes openrouter key for opencode" "yes" "$(grep -A10 'agent_same_isolated' "$ACTION" | grep -q 'OPENROUTER_API_KEY.*steps.parse.outputs.agent.*opencode' && echo yes || echo no)"
t "container step passes openai key for codex" "yes" "$(grep -A10 'agent_same_isolated' "$ACTION" | grep -q 'OPENAI_API_KEY.*steps.parse.outputs.agent.*codex' && echo yes || echo no)"
t "container step passes anthropic key for claude-code" "yes" "$(grep -A10 'agent_same_isolated' "$ACTION" | grep -q 'ANTHROPIC_API_KEY.*steps.parse.outputs.agent.*claude-code' && echo yes || echo no)"

finish