#!/usr/bin/env bash
# Codex CLI agent adapter. CLI: `codex`.
#
# Codex supports two authentication modes:
#   1. OpenAI API key (profile=openai-api). The repository secret is sourced
#      as OPENAI_API_KEY, but pinned `codex exec` 0.147.0 consumes ephemeral
#      headless API auth from CODEX_API_KEY.
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
  # Version discovery needs no provider credential.
  agent_exec_clean "" "" -- codex --version 2>&1 | head -1
}

agent_run() {
  local model="$1" prompt="$2" logfile="$3" max_runtime="$4"
  local credential_var="$5" credential_value="$6"

  # Keep the external profile/secret contract as openai-api/OPENAI_API_KEY, but
  # translate only at the Codex process boundary. `codex exec` 0.147.0 enables
  # CODEX_API_KEY as its ephemeral API-key auth source; passing OPENAI_API_KEY
  # alone leaves the Responses request without an Authorization header.
  [ "$credential_var" = "OPENAI_API_KEY" ] \
    || fail_with "$CAT_AGENT_AUTH" "Codex openai-api profile resolved an unexpected credential variable"
  agent_run_clean "CODEX_API_KEY" "$credential_value" "$max_runtime" "$logfile" -- \
    codex exec --skip-git-repo-check "$prompt"
}

is_auth_agent_error() {
  local logfile="$1"
  grep -qiE '401 Unauthorized|Missing bearer or basic authentication|invalid[_ -]?api[_ -]?key|incorrect API key|authentication (failed|required)' "$logfile" 2>/dev/null
}

is_transient_agent_error() {
  local logfile="$1"
  grep -qiE '429|rate.?limit|ECONNRESET|ETIMEDOUT|fetch failed|5[0-9]{2}|server error|temporarily' "$logfile" 2>/dev/null
}
