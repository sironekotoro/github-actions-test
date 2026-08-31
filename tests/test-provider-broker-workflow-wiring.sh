#!/usr/bin/env bash
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/lib/helpers.sh"

DISPATCH="$ROOT/.github/workflows/agent-dispatch.yml"
REPAIR="$ROOT/.github/workflows/review-repair-executor.yml"

# Ordinary Agent Dispatch: broker is opt-in, OpenCode-only, and the real
# OpenRouter inference key is withheld from the live agent action when enabled.
t "dispatch wires broker flag from repository variable" "yes" \
  "$(grep -Fq "provider_broker_enabled: \${{ needs.route.outputs.agent == 'opencode' && vars.PROVIDER_BROKER_ENABLED == 'true' && 'true' || 'false' }}" "$DISPATCH" && echo yes || echo no)"
t "dispatch wires provider job cap" "yes" \
  "$(grep -Fq "provider_job_max_usd: \${{ vars.PROVIDER_JOB_MAX_USD || '0.25' }}" "$DISPATCH" && echo yes || echo no)"
t "dispatch passes management key only for enabled OpenCode broker" "yes" \
  "$(grep -Fq "openrouter_management_key: \${{ needs.route.outputs.agent == 'opencode' && vars.PROVIDER_BROKER_ENABLED == 'true' && secrets.OPENROUTER_MANAGEMENT_KEY || '' }}" "$DISPATCH" && echo yes || echo no)"
t "dispatch withholds direct OpenRouter key in broker mode" "yes" \
  "$(grep -Fq "agent_credential: \${{ needs.route.outputs.agent == 'opencode' && vars.PROVIDER_BROKER_ENABLED != 'true' && secrets.OPENROUTER_API_KEY" "$DISPATCH" && echo yes || echo no)"
t "dispatch preserves Codex direct credential path" "yes" \
  "$(grep -Fq "needs.route.outputs.agent == 'codex' && secrets.OPENAI_API_KEY" "$DISPATCH" && echo yes || echo no)"
t "dispatch preserves Claude direct credential path" "yes" \
  "$(grep -Fq "needs.route.outputs.agent == 'claude-code' && secrets.ANTHROPIC_API_KEY" "$DISPATCH" && echo yes || echo no)"

# Review Repair: it is currently OpenCode/OpenRouter-only. Broker mode builds
# the broker image and passes only the trusted management credential to the
# outer executor; legacy direct-key mode remains available while the flag is
# false.
t "review repair builds broker image only when enabled" "yes" \
  "$(grep -Fq "if [ \"\${{ vars.PROVIDER_BROKER_ENABLED || 'false' }}\" = \"true\" ]; then" "$REPAIR" && grep -Fq 'docker build --tag "provider-broker:$GITHUB_RUN_ID"' "$REPAIR" && echo yes || echo no)"
t "review repair wires broker flag" "yes" \
  "$(grep -Fq "PROVIDER_BROKER_ENABLED: \${{ vars.PROVIDER_BROKER_ENABLED || 'false' }}" "$REPAIR" && echo yes || echo no)"
t "review repair wires provider job cap" "yes" \
  "$(grep -Fq "PROVIDER_JOB_MAX_USD: \${{ vars.PROVIDER_JOB_MAX_USD || '0.25' }}" "$REPAIR" && echo yes || echo no)"
t "review repair withholds direct key in broker mode" "yes" \
  "$(grep -Fq "OPENROUTER_API_KEY: \${{ vars.PROVIDER_BROKER_ENABLED != 'true' && secrets.OPENROUTER_API_KEY || '' }}" "$REPAIR" && echo yes || echo no)"
t "review repair passes management key only in broker mode" "yes" \
  "$(grep -Fq "OPENROUTER_MANAGEMENT_KEY: \${{ vars.PROVIDER_BROKER_ENABLED == 'true' && secrets.OPENROUTER_MANAGEMENT_KEY || '' }}" "$REPAIR" && echo yes || echo no)"
t "review repair no longer unconditionally injects direct OpenRouter key" "no" \
  "$(grep -F "OPENROUTER_API_KEY: \${{ secrets.OPENROUTER_API_KEY }}" "$REPAIR" 2>/dev/null || true)"

finish
