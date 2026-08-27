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
#   openai-api          - OpenAI API key (repo secret OPENAI_API_KEY)
#   chatgpt-subscription - Host-local ChatGPT subscription (no credential to inject;
#                          requires CLI auth already configured on the runner)
#   anthropic-api       - Anthropic API key (repo secret ANTHROPIC_API_KEY)
#   claude-subscription - Host-local Claude Code subscription (no credential to inject;
#                          requires CLI auth already configured on the runner)
#
# Compatibility matrix (agent -> allowed profiles):
#   opencode    -> openrouter
#   codex       -> openai-api, chatgpt-subscription
#   claude-code  -> anthropic-api, claude-subscription
#
# The credential profile is selected by the agent type. Only the matching
# credential(s) are injected into the agent environment.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/common.sh"

# agent_allowed_profiles <agent> -> prints space-separated profile keys, fails if unknown
agent_allowed_profiles() {
  local agent="$1"
  case "$agent" in
    opencode)
      echo "openrouter"
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

# agent_default_profile <agent> -> prints the default profile key
agent_default_profile() {
  local agent="$1"
  case "$agent" in
    opencode) echo "openrouter" ;;
    codex) echo "openai-api" ;;
    claude-code) echo "anthropic-api" ;;
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
    openai-api) echo "OPENAI_API_KEY" ;;
    chatgpt-subscription) echo "" ;;
    anthropic-api) echo "ANTHROPIC_API_KEY" ;;
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
  local profile="$1" var
  if profile_is_subscription "$profile"; then
    return 0
  fi
  var="$(profile_env_var "$profile")"
  if [ -z "${!var:-}" ]; then
    fail_with "$CAT_AGENT_AUTH" "required credential $var is not set for profile=$profile"
  fi
  return 0
}

# emit_credential_env <profile> -> prints export statements for the given profile's
# credential variables. Subscription profiles emit nothing.
emit_credential_env() {
  local profile="$1" var val
  if profile_is_subscription "$profile"; then
    return 0
  fi
  var="$(profile_env_var "$profile")"
  val="${!var:-}"
  if [ -n "$val" ]; then
    printf '%s=%s\n' "$var" "$val"
  fi
}

# credential_summary <profile> -> prints a markdown summary line
credential_summary() {
  local profile="$1" label
  case "$profile" in
    openrouter) label="OpenRouter API key (repo secret)" ;;
    openai-api) label="OpenAI API key (repo secret)" ;;
    chatgpt-subscription) label="host-local ChatGPT subscription (no credential injected)" ;;
    anthropic-api) label="Anthropic API key (repo secret)" ;;
    claude-subscription) label="host-local Claude Code subscription (no credential injected)" ;;
    *) label="unknown" ;;
  esac
  summary "| credential profile | $profile ($label) |"
}