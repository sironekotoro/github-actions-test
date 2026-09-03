#!/usr/bin/env bash
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/lib/helpers.sh"
SCRIPT="$ROOT/scripts/b3c-ordinary-claude-broker-e2e.sh"
WORKFLOW="$ROOT/.github/workflows/b3c-ordinary-claude-broker-e2e.yml"

bash -n "$SCRIPT"
t "B3c ordinary E2E script parses" 0 "$?"
t "workflow is owner-only issue-opened" yes "$(grep -Fq 'types: [opened]' "$WORKFLOW" && grep -Fq "github.actor == 'sironekotoro'" "$WORKFLOW" && grep -Fq "github.event.issue.user.login == 'sironekotoro'" "$WORKFLOW" && echo yes || echo no)"
t "workflow requires exact B3c trigger title" yes "$(grep -Fq "github.event.issue.title == 'B3c Ordinary Claude Broker E2E'" "$WORKFLOW" && echo yes || echo no)"
t "workflow fixes trusted and candidate revisions" yes "$(grep -Fq 'trusted_sha' "$WORKFLOW" && grep -Fq 'candidate_sha' "$WORKFLOW" && grep -Fq 'ref: ${{ needs.plan.outputs.trusted_sha }}' "$WORKFLOW" && grep -Fq 'ref: ${{ needs.plan.outputs.candidate_sha }}' "$WORKFLOW" && echo yes || echo no)"
t "workflow restricts candidate changed-file surface" yes "$(grep -Fq 'B3C_ORDINARY_E2E_UNEXPECTED_CANDIDATE_FILE' "$WORKFLOW" && echo yes || echo no)"
t "workflow runs dedicated self-hosted acceptance" yes "$(grep -Fq 'runs-on: [self-hosted, review-repair, macOS, ARM64]' "$WORKFLOW" && echo yes || echo no)"
t "workflow receives no repository secrets" yes "$(! grep -Fq 'secrets.' "$WORKFLOW" && echo yes || echo no)"
t "harness uses production ordinary wrapper" yes "$(grep -Fq 'scripts/run-agent-dispatch-container.sh' "$SCRIPT" && echo yes || echo no)"
t "harness locks candidate broker build inputs" yes "$(grep -Fq 'B3C_ORDINARY_E2E_UNTRUSTED_BROKER_DOCKERFILE' "$SCRIPT" && grep -Fq 'B3C_ORDINARY_E2E_UNTRUSTED_BROKER_ENTRYPOINT' "$SCRIPT" && echo yes || echo no)"
t "harness pins host-executed wrapper and credential routing blobs" yes "$(grep -Fq 'B3C_ORDINARY_E2E_UNTRUSTED_HOST_WRAPPER' "$SCRIPT" && grep -Fq '19d36bcf93f5fe26f2207f86fca7c01b7188e047' "$SCRIPT" && grep -Fq 'B3C_ORDINARY_E2E_UNTRUSTED_CREDENTIAL_ROUTING' "$SCRIPT" && grep -Fq '6334ff748d3994f9065e42f7d37f4996518a66e0' "$SCRIPT" && echo yes || echo no)"
t "harness uses only fake Anthropic provider credential" yes "$(grep -Fq "ANTHROPIC_API_KEY='b3c-local-provider-marker'" "$SCRIPT" && echo yes || echo no)"
t "trusted test layer removes broker provider egress" yes "$(grep -Fq 'unset BROKER_PROXY_URL' "$SCRIPT" && grep -Fq 'ANTHROPIC_PROVIDER_API_URL=http://mock:8080' "$SCRIPT" && echo yes || echo no)"
t "mock stays on a dedicated internal network shared only with broker" yes "$(grep -Fq 'docker network create --internal "$mock_network"' "$SCRIPT" && grep -Fq 'docker network connect "$mock_network" "agent-dispatch-broker-$run_key"' "$SCRIPT" && ! grep -Fq 'docker network connect --alias mock "$private_network" "$mock_name"' "$SCRIPT" && echo yes || echo no)"
t "harness inspects live untrusted agent environment" yes "$(grep -Fq 'docker inspect "$agent_container"' "$SCRIPT" && echo yes || echo no)"
t "harness proves real provider key and proxy absent from agent" yes "$(grep -Fq 'B3C_ORDINARY_E2E_PROVIDER_KEY_LEAKED_TO_AGENT' "$SCRIPT" && grep -Fq 'B3C_ORDINARY_E2E_HTTP_PROXY_LEAKED_TO_AGENT' "$SCRIPT" && echo yes || echo no)"
t "harness proves Count Tokens precedes Messages" yes "$(grep -Fq 'B3C_ORDINARY_E2E_COUNT_NOT_BEFORE_MESSAGES' "$SCRIPT" && echo yes || echo no)"
t "harness proves guarded exact model and max tokens" yes "$(grep -Fq 'B3C_ORDINARY_E2E_MODEL_NOT_PROVEN' "$SCRIPT" && grep -Fq 'B3C_ORDINARY_E2E_MAX_TOKENS_NOT_GUARDED' "$SCRIPT" && echo yes || echo no)"
t "harness expects safe no-change failure after successful inference-shaped mock" yes "$(grep -Fq 'AGENT_PATCH_INVALID' "$SCRIPT" && grep -Fq 'NO_CHANGES' "$SCRIPT" && echo yes || echo no)"
t "harness declares zero provider inference" yes "$(grep -Fq 'PROVIDER_INFERENCE=0' "$SCRIPT" && echo yes || echo no)"

finish
