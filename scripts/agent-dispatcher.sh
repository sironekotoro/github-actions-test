#!/usr/bin/env bash
# Agent dispatcher: routes to the correct adapter based on a normalized agent
# identifier. Avoids scattering CLI-specific conditionals across the pipeline.
set -uo pipefail

_DISPATCHER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_DISPATCHER_DIR/lib/common.sh"
source "$_DISPATCHER_DIR/lib/credentials.sh"

agent_from_task() {
  jq -r '.agent // "opencode"' "$1"
}

agent_load_adapter() {
  local agent="$1"
  local adapter="$_DISPATCHER_DIR/agents/$agent.sh"
  if [ ! -f "$adapter" ]; then
    fail_with "$CAT_AGENT_UNKNOWN" "unknown agent: $agent (no adapter at scripts/agents/$agent.sh)"
  fi
  # shellcheck source=scripts/agents/$agent.sh
  source "$adapter"
  if [ "$(type -t agent_check_available)" != "function" ] \
     || [ "$(type -t agent_run)" != "function" ]; then
    fail_with "$CAT_AGENT_START" "adapter for agent=$agent is incomplete (missing agent_check_available or agent_run)"
  fi
}

agent_validate_and_prepare() {
  local agent="$1"
  agent_load_adapter "$agent"

  if ! agent_check_available; then
    fail_with "$CAT_AGENT_UNAVAILABLE" "CLI for agent=$agent is not installed and auto-install is not available"
  fi
  log_info "agent=$agent version=$(agent_get_version)"

  local profile
  profile="$(resolve_credential_profile "$agent")"
  assert_credential_available "$profile"
  credential_summary "$profile"
  echo "$profile"
}