#!/usr/bin/env bash
# Codex CLI agent adapter. CLI: `codex`.
#
# Codex supports two authentication modes:
#   1. OpenAI API key (profile=openai-api) via OPENAI_API_KEY env var
#   2. ChatGPT subscription (profile=chatgpt-subscription) via host-local auth
#
# Subscription mode is represented by the profile matrix but is rejected before
# execution until trusted-host identity and per-job credential cleanup exist.
set -uo pipefail

_ADAPTER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_ADAPTER_DIR/../lib/common.sh"
source "$_ADAPTER_DIR/../lib/credentials.sh"

AGENT_NAME="codex"

agent_check_available() {
  command -v codex >/dev/null 2>&1
}

agent_get_version() {
  agent_exec_clean "${1:-}" "${2:-}" -- codex --version 2>&1 | head -1
}

agent_run() {
  local model="$1" prompt="$2" logfile="$3" max_runtime="$4"
  local credential_var="$5" credential_value="$6"
  agent_run_clean "$credential_var" "$credential_value" "$max_runtime" "$logfile" -- \
    codex exec "$prompt"
}

is_transient_agent_error() {
  local logfile="$1"
  grep -qiE '429|rate.?limit|ECONNRESET|ETIMEDOUT|fetch failed|5[0-9]{2}|server error|temporarily' "$logfile" 2>/dev/null
}
