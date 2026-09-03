#!/usr/bin/env bash
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/lib/helpers.sh"

CREDS="$ROOT/scripts/lib/credentials.sh"
DISPATCH="$ROOT/.github/workflows/agent-dispatch.yml"
ACTION="$ROOT/.github/actions/agent-dispatch/action.yml"
CONTAINER="$ROOT/scripts/run-agent-dispatch-container.sh"
DOCKERFILE="$ROOT/docker/provider-broker.Dockerfile"
ENTRYPOINT="$ROOT/scripts/provider-broker-entrypoint.sh"
BUDGET="$ROOT/scripts/provider-budget-preflight.mjs"
source "$CREDS"

t "Claude accepts trusted Anthropic broker profile" "yes" \
  "$(grep -Fq '[ "$agent" = "claude-code" ] && [ "$profile" = "anthropic-broker" ]' "$CREDS" && echo yes || echo no)"
t "Claude defaults to broker only when global broker mode is enabled" "anthropic-api|anthropic-broker" \
  "$(PROVIDER_BROKER_ENABLED=false agent_default_profile claude-code)|$(PROVIDER_BROKER_ENABLED=true agent_default_profile claude-code)"
t "Anthropic broker capability uses Claude credential contract" "ANTHROPIC_API_KEY" \
  "$(profile_env_var anthropic-broker)"
t "Anthropic broker profile requires broker feature flag" "yes" \
  "$(grep -Fq 'openrouter-broker|openai-broker|anthropic-broker)' "$CREDS" && echo yes || echo no)"

t "dispatch withholds direct Anthropic key in broker mode" "yes" \
  "$(grep -Fq "needs.route.outputs.agent == 'claude-code' && vars.PROVIDER_BROKER_ENABLED != 'true' && secrets.ANTHROPIC_API_KEY" "$DISPATCH" && echo yes || echo no)"
t "dispatch exposes Anthropic key only to trusted broker invocation" "yes" \
  "$(grep -Fq "ANTHROPIC_API_KEY: \${{ needs.route.outputs.agent == 'claude-code' && vars.PROVIDER_BROKER_ENABLED == 'true' && secrets.ANTHROPIC_API_KEY || '' }}" "$DISPATCH" && echo yes || echo no)"
t "dispatch keeps Anthropic live forwarding hard-disabled" "yes" \
  "$(grep -Fq "ANTHROPIC_BROKER_LIVE_ALLOWED: 'false'" "$DISPATCH" && echo yes || echo no)"
t "action legacy fallback cannot bypass broker" "yes" \
  "$(grep -cF "inputs.provider_broker_enabled != 'true'" "$ACTION" | grep -qx 2 && echo yes || echo no)"

t "common broker image contains guarded Anthropic broker" "yes" \
  "$(grep -Fq 'provider-broker-anthropic.mjs' "$DOCKERFILE" && grep -Fq 'anthropic-spend-guard.mjs' "$DOCKERFILE" && echo yes || echo no)"
t "broker entrypoint selects Anthropic implementation explicitly" "yes" \
  "$(grep -Fq 'anthropic)' "$ENTRYPOINT" && grep -Fq 'broker-anthropic.mjs' "$ENTRYPOINT" && echo yes || echo no)"
t "container binds trusted Claude model to broker and CLI" "yes" \
  "$(grep -Fq 'broker_allowed_model="$claude_model"' "$CONTAINER" && grep -Fq -- '--env CLAUDE_MODEL="$claude_model"' "$CONTAINER" && echo yes || echo no)"
t "container gives Claude only opaque capability and broker URL" "yes" \
  "$(grep -Fq 'openai-broker|anthropic-broker)' "$CONTAINER" && grep -Fq -- '--env ANTHROPIC_BROKER_BASE_URL=' "$CONTAINER" && echo yes || echo no)"
t "container enables spend guard but defaults live forwarding off" "yes" \
  "$(grep -Fq 'BROKER_ANTHROPIC_SPEND_GUARD_ENABLED=' "$CONTAINER" && grep -Fq 'ANTHROPIC_BROKER_LIVE_ALLOWED:-false' "$CONTAINER" && echo yes || echo no)"
t "Anthropic Phase A remains budget-unknown fail closed" "yes" \
  "$(grep -Fq "agent === 'claude-code') unknown('anthropic', 'PROVIDER_BUDGET_UNKNOWN'" "$BUDGET" && echo yes || echo no)"

finish
