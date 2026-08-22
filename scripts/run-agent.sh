#!/usr/bin/env bash
# Run the coding agent (opencode via OpenRouter) with bounded time and retries.
#
# Injection safety: the prompt is read from a file into a variable and passed
# as a single quoted argument. It is NEVER shell-interpolated.
# Prompt contents are NEVER printed; only length/hash are logged.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

TASK_FILE="${TASK_FILE:-$RUNNER_TEMP/task.json}"
PROMPT_FILE="${PROMPT_FILE:-$RUNNER_TEMP/agent-prompt.txt}"
AGENT_LOG="${AGENT_LOG:-$RUNNER_TEMP/agent.log}"

# A trusted outer executor explicitly enables this mode for the isolated
# review-repair container. A stale prompt file must never alter ordinary agent
# dispatch behavior.
if [ "${AGENT_USE_PREBUILT_PROMPT:-false}" = "true" ]; then
  [ -s "$PROMPT_FILE" ] || fail_with "$CAT_AGENT_START" "trusted prebuilt prompt is missing"
  model="${AGENT_MODEL:-${OPENROUTER_MODEL:-openrouter/deepseek/deepseek-v4-flash}}"
  max_runtime="${AGENT_MAX_RUNTIME:-10}"
else
  # --- build the prompt (with injected target identity) ---
  prompt_builder="$SCRIPT_DIR/build-agent-prompt.sh"
  if [ "$(jq -r '.mode // "issue_dispatch"' "$TASK_FILE")" = "review_repair" ]; then
    prompt_builder="$SCRIPT_DIR/build-review-prompt.sh"
  fi
  "$prompt_builder" || fail_with "$CAT_AGENT_START" "prompt build failed"
  model="$(jq -r '.requested_model // ""' "$TASK_FILE")"
  [ -z "$model" ] && model="${OPENROUTER_MODEL:-openrouter/deepseek/deepseek-v4-flash}"
  max_runtime="$(jq -r '.max_runtime // ""' "$TASK_FILE")"
  [ -z "$max_runtime" ] && max_runtime="${AGENT_MAX_RUNTIME:-10}"
fi
max_attempts="${AGENT_MAX_ATTEMPTS:-2}"

# --- ensure opencode is available ---
if ! command -v opencode >/dev/null 2>&1; then
  if [ "${AGENT_AUTO_INSTALL:-true}" != "true" ]; then
    fail_with "$CAT_AGENT_START" "opencode is not preinstalled on the self-hosted executor"
  fi
  log_info "opencode not found; installing opencode-ai (this can take a while)..."
  npm install -g opencode-ai >/dev/null 2>&1 || fail_with "$CAT_AGENT_START" "npm install opencode-ai failed"
fi
log_info "opencode version: $(opencode --version 2>&1 | head -1)"

# --- read prompt once; single quoted arg = injection-safe ---
PROMPT="$(<"$PROMPT_FILE")"

run_once() {
  local out="$AGENT_LOG"
  if command -v timeout >/dev/null 2>&1; then
    timeout "${max_runtime}m" env OPENROUTER_API_KEY="${OPENROUTER_API_KEY:-}" \
      opencode run --print-logs -m "$model" "$PROMPT" >"$out" 2>&1
  else
    env OPENROUTER_API_KEY="${OPENROUTER_API_KEY:-}" \
      opencode run --print-logs -m "$model" "$PROMPT" >"$out" 2>&1
  fi
  return $?
}

is_transient() { # <logfile> -> 0 if the failure looks like a transient API error
  grep -qiE '429|rate.?limit|ECONNRESET|ETIMEDOUT|fetch failed|5[0-9]{2}|server error|temporarily' "$1" 2>/dev/null
}

attempt=1
status=0
agent_started_epoch="$(date +%s)"
while :; do
  log_info "agent attempt $attempt/$max_attempts (model=$model, max_runtime=${max_runtime}m)"
  run_once
  status=$?

  if [ "$status" -eq 0 ]; then
    break
  fi
  if [ "$status" -eq 124 ]; then
    set_failure "$CAT_AGENT_TIMEOUT"
    log_error "FAILURE_CATEGORY=$CAT_AGENT_TIMEOUT exceeded ${max_runtime}m"
    tail -n 40 "$AGENT_LOG" >&2
    break
  fi
  if [ "$attempt" -ge "$max_attempts" ] || ! is_transient "$AGENT_LOG"; then
    set_failure "$CAT_MODEL_API"
    log_error "FAILURE_CATEGORY=$CAT_MODEL_API opencode exited $status (attempt $attempt)"
    tail -n 40 "$AGENT_LOG" >&2
    break
  fi
  log_warn "transient API failure; retrying (attempt $attempt)"
  attempt=$((attempt + 1))
done
agent_finished_epoch="$(date +%s)"
agent_runtime_seconds=$((agent_finished_epoch - agent_started_epoch))

echo "model=$model" >> "${GITHUB_OUTPUT:-/dev/null}"
echo "runtime_seconds=$agent_runtime_seconds" >> "${GITHUB_OUTPUT:-/dev/null}"
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
