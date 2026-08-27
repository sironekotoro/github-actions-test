#!/usr/bin/env bash
# Claude Code agent adapter. CLI: `claude`.
#
# Claude Code supports two authentication modes:
#   1. Anthropic API key (profile=anthropic-api) via ANTHROPIC_API_KEY env var
#   2. Claude subscription (profile=claude-subscription) via host-local auth
#
# Subscription mode assumes the CLI has been pre-authenticated on the runner.
# This profile is intentionally fail-closed on hosted executors; the credential
# must be provisioned explicitly on self-hosted runners.
set -uo pipefail

_ADAPTER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_ADAPTER_DIR/../lib/common.sh"
source "$_ADAPTER_DIR/../lib/credentials.sh"

AGENT_NAME="claude-code"

agent_check_available() {
  command -v claude >/dev/null 2>&1
}

agent_get_version() {
  claude --version 2>&1 | head -1
}

agent_run() {
  local model="$1" prompt="$2" logfile="$3" max_runtime="$4" credential_env="$5"
  # Claude Code uses ANTHROPIC_API_KEY in the environment
  if command -v timeout >/dev/null 2>&1; then
    timeout "${max_runtime}m" env $credential_env \
      claude run "$prompt" >"$logfile" 2>&1
  else
    env $credential_env \
      claude run "$prompt" >"$logfile" 2>&1
  fi
  return $?
}

is_transient_agent_error() {
  local logfile="$1"
  grep -qiE '429|rate.?limit|ECONNRESET|ETIMEDOUT|fetch failed|5[0-9]{2}|server error|temporarily' "$logfile" 2>/dev/null
}