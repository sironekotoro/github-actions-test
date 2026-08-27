#!/usr/bin/env bash
# Codex CLI agent adapter. CLI: `codex`.
#
# Codex supports two authentication modes:
#   1. OpenAI API key (profile=openai-api) via --api-key or OPENAI_API_KEY env var
#   2. ChatGPT subscription (profile=chatgpt-subscription) via host-local auth
#
# Subscription mode assumes the CLI has been pre-authenticated on the runner.
# In CI, only the API key mode is exercised safely; subscription is fail-closed
# when unconfigured.
set -uo pipefail

_ADAPTER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_ADAPTER_DIR/../lib/common.sh"
source "$_ADAPTER_DIR/../lib/credentials.sh"

AGENT_NAME="codex"

agent_check_available() {
  command -v codex >/dev/null 2>&1
}

agent_get_version() {
  codex --version 2>&1 | head -1
}

agent_run() {
  local model="$1" prompt="$2" logfile="$3" max_runtime="$4" credential_env="$5"
  local profile="${AGENT_CREDENTIAL_PROFILE:-openai-api}"
  local codex_args=""
  if [ "$profile" = "openai-api" ]; then
    codex_args="--api-key"
  fi
  if command -v timeout >/dev/null 2>&1; then
    timeout "${max_runtime}m" env $credential_env \
      codex run $codex_args "$prompt" >"$logfile" 2>&1
  else
    env $credential_env \
      codex run $codex_args "$prompt" >"$logfile" 2>&1
  fi
  return $?
}

is_transient_agent_error() {
  local logfile="$1"
  grep -qiE '429|rate.?limit|ECONNRESET|ETIMEDOUT|fetch failed|5[0-9]{2}|server error|temporarily' "$logfile" 2>/dev/null
}