#!/usr/bin/env bash
# Credential profile abstraction for selected agents.
#
# A credential profile models a safe, scoped authentication source. Each agent
# accepts exactly one profile. The compatibility matrix is enforced at dispatch
# time: an unsupported (agent, profile) pair fails closed before the container
# or agent process starts.
#
# Profiles (machine-readable keys):
#   openrouter          - OpenRouter API key (repo secret OPENROUTER_API_KEY)
#   openrouter-broker   - OpenRouter via broker (capability token replaces key)
#   openai-api          - OpenAI API key (repo secret OPENAI_API_KEY)
#   openai-broker       - OpenAI via broker (capability token replaces key)
#   chatgpt-subscription - Host-local ChatGPT subscription (no credential to inject;
#                          represented for future trusted-host provisioning only)
#   anthropic-api       - Anthropic API key (repo secret ANTHROPIC_API_KEY)
#   anthropic-broker    - Anthropic via broker (capability token replaces key)
#   claude-subscription - Host-local Claude Code subscription (no credential to inject;
#                          represented for future trusted-host provisioning only)
#
# Compatibility matrix (agent -> allowed profiles):
#   opencode    -> openrouter, openrouter-broker
#   codex       -> openai-api, openai-broker, chatgpt-subscription
#   claude-code  -> anthropic-api, anthropic-broker, claude-subscription
#
# The credential profile is selected by the agent type. Only the matching
# credential(s) are injected into the agent environment.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/common.sh"

# agent_allowed_profiles <agent> -> prints the legacy user-selectable profile
# keys. Broker profiles that are selected automatically by trusted routing may
# be accepted explicitly by validate_credential_profile without widening this
# legacy listing (which is also used by older tests/docs).
agent_allowed_profiles() {
  local agent="$1"
  case "$agent" in
    opencode)
      echo "openrouter openrouter-broker"
      ;;
    codex)
      echo "openai-api chatgpt-subscription"
      ;;
    claude-code)
      echo "anthropic-api claude-subscription"
      ;;
    *)
      fail_with "$CAT_AGENT_AUTH" "unknown agent: $agent"
      ;;
  esac
}

# agent_default_profile <agent> -> prints the default profile key.
# When PROVIDER_BROKER_ENABLED is true, API-backed agents resolve to their
# broker profiles. Broker profiles are trusted-routing-only.
agent_default_profile() {
  local agent="$1"
  case "$agent" in
    opencode)
      if [ "${PROVIDER_BROKER_ENABLED:-false}" = "true" ]; then
        echo "openrouter-broker"
      else
        echo "openrouter"
      fi
      ;;
    codex)
      if [ "${PROVIDER_BROKER_ENABLED:-false}" = "true" ]; then
        echo "openai-broker"
      else
        echo "openai-api"
      fi
      ;;
    claude-code)
      if [ "${PROVIDER_BROKER_ENABLED:-false}" = "true" ]; then
        echo "anthropic-broker"
      else
        echo "anthropic-api"
      fi
      ;;
    *)
      fail_with "$CAT_AGENT_AUTH" "unknown agent: $agent"
      ;;
  esac
}

# profile_env_var <profile> -> prints the env var name that carries the credential
profile_env_var() {
  local profile="$1"
  case "$profile" in
    openrouter) echo "OPENROUTER_API_KEY" ;;
    openrouter-broker) echo "OPENROUTER_API_KEY" ;;
    openai-api) echo "OPENAI_API_KEY" ;;
    openai-broker) echo "OPENAI_API_KEY" ;;
    chatgpt-subscription) echo "" ;;
    anthropic-api) echo "ANTHROPIC_API_KEY" ;;
    anthropic-broker) echo "ANTHROPIC_API_KEY" ;;
    claude-subscription) echo "" ;;
    *)
      fail_with "$CAT_AGENT_AUTH" "unknown credential profile: $profile"
      ;;
  esac
}

# profile_is_subscription <profile> -> 0 if subscription-based (no credential to inject), 1 otherwise
profile_is_subscription() {
  local profile="$1"
  case "$profile" in
    chatgpt-subscription|claude-subscription) return 0 ;;
    *) return 1 ;;
  esac
}

# validate_credential_profile <agent> <profile> -> 0 if valid, fails closed otherwise
validate_credential_profile() {
  local agent="$1" profile="$2"
  local allowed
  allowed="$(agent_allowed_profiles "$agent")"
  local found=false
  for p in $allowed; do
    [ "$p" = "$profile" ] && { found=true; break; }
  done
  # Broker profiles added after the legacy profile selector are
  # trusted-routing-only. Accept them here without widening that selector.
  if [ "$agent" = "codex" ] && [ "$profile" = "openai-broker" ]; then
    found=true
  fi
  if [ "$agent" = "claude-code" ] && [ "$profile" = "anthropic-broker" ]; then
    found=true
  fi
  if [ "$found" != true ]; then
    fail_with "$CAT_AGENT_AUTH" "agent=$agent does not support profile=$profile (allowed: $allowed)"
  fi
}

# resolve_credential_profile <agent> -> prints the resolved profile key.
# Uses the explicitly provided AGENT_CREDENTIAL_PROFILE if set, otherwise picks
# the agent's default. Validates compatibility.
resolve_credential_profile() {
  local agent="$1" profile
  profile="${AGENT_CREDENTIAL_PROFILE:-$(agent_default_profile "$agent")}"
  validate_credential_profile "$agent" "$profile"
  echo "$profile"
}

# assert_credential_available <profile> -> 0 if credential is available, fails closed
assert_credential_available() {
  local profile="$1" var value
  if profile_is_subscription "$profile"; then
    return 0
  fi
  var="$(profile_env_var "$profile")"
  if [ "$#" -ge 2 ]; then
    value="$2"
  else
    value="${!var:-}"
  fi
  if [ -z "$value" ]; then
    fail_with "$CAT_AGENT_AUTH" "required credential $var is not set for profile=$profile"
  fi
  return 0
}

# Subscription profiles remain part of the compatibility model, but there is
# no safe credential handoff implementation yet. In particular, never fall
# back to a host's pre-authenticated browser/CLI state from an untrusted job.
assert_execution_profile_supported() {
  local profile="$1"
  if profile_is_subscription "$profile"; then
    fail_with "$CAT_AGENT_AUTH" "credential profile=$profile is unsupported in Agent Dispatch until trusted-host identity, per-job provisioning, and cleanup are implemented"
  fi
  case "$profile" in
    openrouter-broker|openai-broker|anthropic-broker)
      if [ "${PROVIDER_BROKER_ENABLED:-false}" != "true" ]; then
        fail_with "$CAT_AGENT_AUTH" "credential profile=$profile requires PROVIDER_BROKER_ENABLED=true"
      fi
      ;;
  esac
}

# credential_summary <profile> -> prints a markdown summary line
credential_summary() {
  local profile="$1" label
  case "$profile" in
    openrouter) label="OpenRouter API key (repo secret)" ;;
    openrouter-broker) label="OpenRouter via broker (per-job capability token)" ;;
    openai-api) label="OpenAI API key (repo secret)" ;;
    openai-broker) label="OpenAI via broker (per-job capability token; disposable project credential held by broker)" ;;
    chatgpt-subscription) label="host-local ChatGPT subscription (no credential injected)" ;;
    anthropic-api) label="Anthropic API key (repo secret)" ;;
    anthropic-broker) label="Anthropic via broker (per-job capability token; provider key held by broker)" ;;
    claude-subscription) label="host-local Claude Code subscription (no credential injected)" ;;
    *) label="unknown" ;;
  esac
  summary "| credential profile | $profile ($label) |"
}
