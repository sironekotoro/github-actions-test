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

  # When broker is enabled, configure OpenCode to point at the local broker
  # for its OpenRouter provider base URL. Build a single trusted JSON document
  # using the provider.openrouter.options.baseURL structure accepted by
  # pinned opencode-ai@1.18.16. This trusted override wins over project config.
  if [ "${PROVIDER_BROKER_ENABLED:-false}" = "true" ] && [ -n "${OPENCODE_BROKER_BASE_URL:-}" ]; then
    local broker_config
    broker_config="$(node -e "
      const existing = process.env.OPENCODE_CONFIG_CONTENT || '{}';
      try {
        const base = JSON.parse(existing);
        base.provider = base.provider || {};
        base.provider.openrouter = base.provider.openrouter || {};
        base.provider.openrouter.options = base.provider.openrouter.options || {};
        base.provider.openrouter.options.baseURL = process.env.OPENCODE_BROKER_BASE_URL;
        process.stdout.write(JSON.stringify(base));
      } catch(e) {
        process.stderr.write('OPENCODE_CONFIG_CONTENT parse error: ' + e.message);
        process.exit(1);
      }
    " 2>/dev/null)" || fail_with "$CAT_AGENT_START" "could not build broker config"
    OPENCODE_CONFIG_CONTENT="$broker_config"
    export OPENCODE_CONFIG_CONTENT
  fi

  agent_run_clean "$credential_var" "$credential_value" "$max_runtime" "$logfile" -- \
    opencode run --auto --agent build --print-logs -m "$model" "$prompt"
}

is_transient_agent_error() {
  local logfile="$1"
  grep -qiE '429|rate.?limit|ECONNRESET|ETIMEDOUT|fetch failed|5[0-9]{2}|server error|temporarily' "$logfile" 2>/dev/null
}
