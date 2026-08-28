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

  local profile credential_var credential_value
  if ! profile="$(resolve_credential_profile "$agent")"; then
    return 1
  fi
  assert_execution_profile_supported "$profile"
  credential_var="$(profile_env_var "$profile")"
  if [ -n "$credential_var" ] && [ -n "${AGENT_CREDENTIAL_VALUE:-}" ]; then
    credential_value="$AGENT_CREDENTIAL_VALUE"
  else
    credential_value="${!credential_var:-}"
  fi
  assert_credential_available "$profile" "$credential_value"

  if ! agent_check_available; then
    fail_with "$CAT_AGENT_UNAVAILABLE" "CLI for agent=$agent is not installed and auto-install is not available"
  fi
  log_info "agent=$agent version=$(agent_get_version "$credential_var" "$credential_value")" >&2

  credential_summary "$profile"
  export AGENT_VALIDATED_PROFILE="$profile"
}
