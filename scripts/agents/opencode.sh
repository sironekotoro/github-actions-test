#!/usr/bin/env bash
# OpenCode agent adapter. CLI: `opencode run`.
set -uo pipefail

_ADAPTER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$_ADAPTER_DIR/../lib/common.sh"
# shellcheck source=lib/credentials.sh
source "$_ADAPTER_DIR/../lib/credentials.sh"

AGENT_NAME="opencode"

agent_check_available() {
  if command -v opencode >/dev/null 2>&1; then
    return 0
  fi
  if [ "${AGENT_AUTO_INSTALL:-true}" = "true" ]; then
    log_info "opencode not found; installing opencode-ai..."
    npm install -g opencode-ai >/dev/null 2>&1 || return 1
    return 0
  fi
  return 1
}

agent_get_version() {
  agent_exec_clean "${1:-}" "${2:-}" -- opencode --version 2>&1 | head -1
}

agent_run() {
  local model="$1" prompt="$2" logfile="$3" max_runtime="$4"
  local credential_var="$5" credential_value="$6"
  agent_run_clean "$credential_var" "$credential_value" "$max_runtime" "$logfile" -- \
    opencode run --auto --agent build --print-logs -m "$model" "$prompt"
}

is_transient_agent_error() {
  local logfile="$1"
  grep -qiE '429|rate.?limit|ECONNRESET|ETIMEDOUT|fetch failed|5[0-9]{2}|server error|temporarily' "$logfile" 2>/dev/null
}
