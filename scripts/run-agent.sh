#!/usr/bin/env bash
# Run the coding agent with bounded time and retries.
#
# The agent type is read from the task JSON (default: opencode). Its adapter
# handles CLI-specific invocation. Credential profiles are resolved by
# lib/credentials.sh and only the selected agent's credential is injected.
#
# Injection safety: the prompt is read from a file into a variable and passed
# as a single quoted argument. It is NEVER shell-interpolated.
# Prompt contents are NEVER printed; only length/hash are logged.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Save SCRIPT_DIR before sub-files overwrite it
_RUN_AGENT_SCRIPT_DIR="$SCRIPT_DIR"
# shellcheck source=lib/common.sh
source "$_RUN_AGENT_SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/credentials.sh
source "$_RUN_AGENT_SCRIPT_DIR/lib/credentials.sh"
# shellcheck source=agent-dispatcher.sh
source "$_RUN_AGENT_SCRIPT_DIR/agent-dispatcher.sh"

runtime_temp="${RUNNER_TEMP:-/tmp}"
TASK_FILE="${TASK_FILE:-$runtime_temp/task.json}"
PROMPT_FILE="${PROMPT_FILE:-$runtime_temp/agent-prompt.txt}"
AGENT_LOG="${AGENT_LOG:-$runtime_temp/agent.log}"

# API-backed hosted runs must not reuse a runner user's CLI configuration. The
# isolated container supplies its own /home/agent and does not set AGENT_HOME.
if [ -n "${AGENT_HOME:-}" ]; then
  mkdir -p "$AGENT_HOME" || fail_with "$CAT_AGENT_START" "could not create isolated agent home"
  HOME="$AGENT_HOME"
  export HOME
fi

# --- resolve agent ---
# A prebuilt prompt in the isolated container intentionally has no task file.
# The trusted outer wrapper passes the normalized agent explicitly in that
# case; direct prebuilt callers default to OpenCode. A real task file always
# remains authoritative, so an unknown task agent still fails closed.
agent="${AGENT:-opencode}"
if [ -f "$TASK_FILE" ]; then
  agent="$(agent_from_task "$TASK_FILE")"
fi
profile=""
if [ "${AGENT_USE_PREBUILT_PROMPT:-false}" = "true" ]; then
  [ -s "$PROMPT_FILE" ] || fail_with "$CAT_AGENT_START" "trusted prebuilt prompt is missing"
  model="${AGENT_MODEL:-${OPENROUTER_MODEL:-openrouter/deepseek/deepseek-v4-flash}}"
  max_runtime="${AGENT_MAX_RUNTIME:-10}"
  agent_load_adapter "$agent"
  if ! profile="$(resolve_credential_profile "$agent")"; then
    exit 1
  fi
else
  # --- build the prompt (with injected target identity) ---
  prompt_builder="$_RUN_AGENT_SCRIPT_DIR/build-agent-prompt.sh"
  if [ "$(jq -r '.mode // "issue_dispatch"' "$TASK_FILE")" = "review_repair" ]; then
    prompt_builder="$_RUN_AGENT_SCRIPT_DIR/build-review-prompt.sh"
  fi
  "$prompt_builder" || fail_with "$CAT_AGENT_START" "prompt build failed"
  model="$(jq -r '.requested_model // ""' "$TASK_FILE")"
  [ -z "$model" ] && model="${OPENROUTER_MODEL:-openrouter/deepseek/deepseek-v4-flash}"
  max_runtime="$(jq -r '.max_runtime // ""' "$TASK_FILE")"
  [ -z "$max_runtime" ] && max_runtime="${AGENT_MAX_RUNTIME:-10}"
  agent_load_adapter "$agent"
  agent_validate_and_prepare "$agent" || exit $?
  profile="$AGENT_VALIDATED_PROFILE"
fi
[ -n "$profile" ] || {
  if ! profile="$(resolve_credential_profile "$agent")"; then
    exit 1
  fi
}
max_attempts="${AGENT_MAX_ATTEMPTS:-2}"

assert_execution_profile_supported "$profile"
credential_var="$(profile_env_var "$profile")"
credential_value=""
if [ -n "$credential_var" ]; then
  if [ -n "${AGENT_CREDENTIAL_VALUE:-}" ]; then
    credential_value="$AGENT_CREDENTIAL_VALUE"
  else
    credential_value="${!credential_var:-}"
  fi
  assert_credential_available "$profile" "$credential_value"
fi

# --- ensure agent is available ---
agent_check_available || fail_with "$CAT_AGENT_UNAVAILABLE" "agent=$agent CLI is not available"
log_info "agent=$agent version=$(agent_get_version "$credential_var" "$credential_value")"

# --- read prompt once; single quoted arg = injection-safe ---
PROMPT="$(<"$PROMPT_FILE")"

attempt=1
status=0
agent_started_epoch="$(date +%s)"
while :; do
  log_info "agent=$agent attempt $attempt/$max_attempts (model=$model, max_runtime=${max_runtime}m)"
  agent_run "$model" "$PROMPT" "$AGENT_LOG" "$max_runtime" "$credential_var" "$credential_value"
  status=$?

  if [ "$status" -eq 0 ]; then
    break
  fi
  if [ "$status" -eq 124 ]; then
    set_failure "$CAT_AGENT_TIMEOUT"
    log_error "FAILURE_CATEGORY=$CAT_AGENT_TIMEOUT exceeded ${max_runtime}m"
    redacted_agent_log_tail "$AGENT_LOG" "$credential_value"
    break
  fi
  # Authentication failures are deterministic for the supplied credential.
  # Adapters may recognize their provider-specific auth diagnostics; classify
  # them before transient detection so 401s are never retried as API failures.
  if declare -F is_auth_agent_error >/dev/null 2>&1 && is_auth_agent_error "$AGENT_LOG"; then
    set_failure "$CAT_AGENT_AUTH"
    log_error "FAILURE_CATEGORY=$CAT_AGENT_AUTH agent=$agent authentication failed"
    redacted_agent_log_tail "$AGENT_LOG" "$credential_value"
    break
  fi
  if [ "$attempt" -ge "$max_attempts" ] || ! is_transient_agent_error "$AGENT_LOG"; then
    set_failure "$CAT_MODEL_API"
    log_error "FAILURE_CATEGORY=$CAT_MODEL_API agent=$agent exited $status (attempt $attempt)"
    redacted_agent_log_tail "$AGENT_LOG" "$credential_value"
    break
  fi
  log_warn "transient API failure; retrying (attempt $attempt)"
  attempt=$((attempt + 1))
done
agent_finished_epoch="$(date +%s)"
agent_runtime_seconds=$((agent_finished_epoch - agent_started_epoch))

echo "model=$model" >> "${GITHUB_OUTPUT:-/dev/null}"
echo "runtime_seconds=$agent_runtime_seconds" >> "${GITHUB_OUTPUT:-/dev/null}"
summary "| agent | $agent |"
summary "| model | \`$model\` |"
summary "| max runtime | ${max_runtime}m |"
summary "| attempts | $attempt |"
summary "| agent runtime | ${agent_runtime_seconds}s |"

if [ "$status" -eq 0 ]; then
  summary "| agent result | success |"
  echo "result=pass" >> "${GITHUB_OUTPUT:-/dev/null}"
  exit 0
fi
exit "$status"
