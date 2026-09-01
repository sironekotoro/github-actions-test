#!/usr/bin/env bash
# Claude Code agent adapter. CLI: `claude`.
#
# Claude Code supports two authentication modes:
#   1. Anthropic API key (profile=anthropic-api) via ANTHROPIC_API_KEY env var
#   2. Claude subscription (profile=claude-subscription) via host-local auth
#
# Broker mode reuses ANTHROPIC_API_KEY only as the opaque capability slot. The
# trusted outer executor may provide ANTHROPIC_BROKER_BASE_URL; the adapter maps
# that non-secret routing value to Claude's ANTHROPIC_BASE_URL inside env -i.
# Tool permission prompts are bypassed only inside the hardened outer Docker
# sandbox, matching the established OpenCode/Codex execution model.
# Subscription mode is represented by the profile matrix but is rejected before
# execution until trusted-host identity and per-job credential cleanup exist.
set -uo pipefail

_ADAPTER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_ADAPTER_DIR/../lib/common.sh"
source "$_ADAPTER_DIR/../lib/credentials.sh"

AGENT_NAME="claude-code"

agent_check_available() {
  command -v claude >/dev/null 2>&1
}

agent_get_version() {
  agent_exec_clean "${1:-}" "${2:-}" -- claude --version 2>&1 | head -1
}

agent_run() {
  local model="$1" prompt="$2" logfile="$3" max_runtime="$4"
  local credential_var="$5" credential_value="$6"
  [ -n "$model" ] || fail_with "$CAT_AGENT_AUTH" "Claude model is required"

  if [ -n "${ANTHROPIC_BROKER_BASE_URL:-}" ]; then
    agent_run_clean "$credential_var" "$credential_value" "$max_runtime" "$logfile" -- \
      env \
      "ANTHROPIC_BASE_URL=$ANTHROPIC_BROKER_BASE_URL" \
      CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 \
      DISABLE_TELEMETRY=1 \
      DISABLE_ERROR_REPORTING=1 \
      DISABLE_AUTOUPDATER=1 \
      claude -p "$prompt" --model "$model" --dangerously-skip-permissions
  else
    agent_run_clean "$credential_var" "$credential_value" "$max_runtime" "$logfile" -- \
      claude -p "$prompt" --model "$model" --dangerously-skip-permissions
  fi
}

is_transient_agent_error() {
  local logfile="$1"
  grep -qiE '429|rate.?limit|ECONNRESET|ETIMEDOUT|fetch failed|5[0-9]{2}|server error|temporarily' "$logfile" 2>/dev/null
}
