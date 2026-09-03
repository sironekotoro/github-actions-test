#!/usr/bin/env bash
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/lib/helpers.sh"

CREDS="$ROOT/scripts/lib/credentials.sh"
DISPATCH="$ROOT/.github/workflows/agent-dispatch.yml"
CONTAINER="$ROOT/scripts/run-agent-dispatch-container.sh"

# Credential profile contract.
t "Codex accepts trusted OpenAI broker profile" "yes" \
  "$(grep -Fq '[ "$agent" = "codex" ] && [ "$profile" = "openai-broker" ]' "$CREDS" && echo yes || echo no)"
t "Codex defaults to broker profile when broker enabled" "yes" \
  "$(grep -A8 -F 'codex)' "$CREDS" | grep -Fq 'echo "openai-broker"' && echo yes || echo no)"
t "OpenAI broker capability uses OpenAI external credential contract" "yes" \
  "$(grep -Fq 'openai-broker) echo "OPENAI_API_KEY"' "$CREDS" && echo yes || echo no)"
t "OpenAI broker profile requires feature flag" "yes" \
  "$(grep -Fq 'openrouter-broker|openai-broker|anthropic-broker)' "$CREDS" && grep -Fq 'requires PROVIDER_BROKER_ENABLED=true' "$CREDS" && echo yes || echo no)"

# Trusted workflow wiring: direct OpenAI key is withheld in broker mode and the
# Admin key is available only to the trusted composite action invocation.
t "dispatch withholds direct OpenAI key in Codex broker mode" "yes" \
  "$(grep -Fq "needs.route.outputs.agent == 'codex' && vars.PROVIDER_BROKER_ENABLED != 'true' && secrets.OPENAI_API_KEY" "$DISPATCH" && echo yes || echo no)"
t "dispatch continues enabling broker for Codex" "yes" \
  "$(grep -Fq "provider_broker_enabled: \${{ contains(fromJSON('[\"opencode\",\"codex\",\"claude-code\"]'), needs.route.outputs.agent) && vars.PROVIDER_BROKER_ENABLED == 'true' && 'true' || 'false' }}" "$DISPATCH" && echo yes || echo no)"
t "dispatch passes OpenAI Admin key only for enabled Codex broker" "yes" \
  "$(grep -Fq "OPENAI_ADMIN_KEY: \${{ needs.route.outputs.agent == 'codex' && vars.PROVIDER_BROKER_ENABLED == 'true' && secrets.OPENAI_ADMIN_KEY || '' }}" "$DISPATCH" && echo yes || echo no)"
t "dispatch still scopes OpenRouter management key to OpenCode" "yes" \
  "$(grep -Fq "openrouter_management_key: \${{ needs.route.outputs.agent == 'opencode' && vars.PROVIDER_BROKER_ENABLED == 'true' && secrets.OPENROUTER_MANAGEMENT_KEY || '' }}" "$DISPATCH" && echo yes || echo no)"

# Trusted outer-container routing.
t "container continues recognizing OpenRouter and OpenAI broker profiles" "yes" \
  "$(grep -Fq 'openrouter-broker|openai-broker|anthropic-broker) broker_profile=true' "$CONTAINER" && echo yes || echo no)"
t "OpenAI broker requires Admin key before startup" "yes" \
  "$(grep -Fq 'OPENAI_ADMIN_KEY required for OpenAI broker' "$CONTAINER" && echo yes || echo no)"
t "OpenAI broker selects provider mode explicitly" "yes" \
  "$(grep -Fq 'broker_provider="openai"' "$CONTAINER" && grep -Fq -- '-e BROKER_PROVIDER="$broker_provider"' "$CONTAINER" && echo yes || echo no)"
t "Codex broker exact model comes from validated task or trusted fallback" "yes" \
  "$(grep -Fq "codex_model=\"\$(jq -r '.requested_model // empty' \"\$task_file\")\"" "$CONTAINER" && grep -Fq 'codex_model="${CODEX_MODEL:-gpt-5.6-sol}"' "$CONTAINER" && echo yes || echo no)"
t "Codex broker passes same exact model into isolated CLI" "yes" \
  "$(grep -Fq -- '--env CODEX_MODEL="$codex_model"' "$CONTAINER" && echo yes || echo no)"
t "Codex broker points isolated Codex HOME at broker Responses base URL" "yes" \
  "$(grep -Fq -- '--env CODEX_BROKER_BASE_URL="${codex_broker_base_url:-}"' "$CONTAINER" && grep -Fq 'openai_base_url = \"%s/v1\"' "$CONTAINER" && echo yes || echo no)"
t "Codex broker sends opaque capability through generic agent credential only" "yes" \
  "$(grep -A3 -F 'openai-broker|anthropic-broker)' "$CONTAINER" | grep -Fq 'AGENT_CREDENTIAL_VALUE="$broker_capability"' && echo yes || echo no)"
t "brokered agent gets no provider-capable proxy env" "yes" \
  "$(grep -Fq 'if [ "$broker_profile" != true ]; then' "$CONTAINER" && echo yes || echo no)"
t "broker proxy args remain nonempty on macOS Bash nounset" "yes" \
  "$(grep -Fq 'agent_proxy_env=(--env NO_PROXY=localhost,127.0.0.1)' "$CONTAINER" && echo yes || echo no)"
t "workspace credential scan uses opaque capability for both brokers" "yes" \
  "$(grep -Fq 'scan_final_workspace_for_credential "$workspace_dir" "$broker_capability"' "$CONTAINER" && echo yes || echo no)"

# Review Repair intentionally remains OpenCode-only in B2c; do not broaden its
# agent/auth surface implicitly while wiring ordinary Codex dispatch.
t "B2c does not inject OpenAI Admin key into Review Repair" "yes" \
  "$(! grep -Fq 'OPENAI_ADMIN_KEY' "$ROOT/.github/workflows/review-repair-executor.yml" && echo yes || echo no)"

finish
