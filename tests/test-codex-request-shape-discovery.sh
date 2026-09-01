#!/usr/bin/env bash
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/lib/helpers.sh"

WORKFLOW="$ROOT/.github/workflows/codex-request-shape-discovery.yml"
SCRIPT="$ROOT/scripts/codex-request-shape-discovery.sh"

bash -n "$SCRIPT"
t "Codex B2a discovery script parses" "0" "$?"

t "workflow is explicit issue-opened trigger" "yes" "$(grep -q 'types: \[opened\]' "$WORKFLOW" && echo yes || echo no)"
t "workflow restricts actor and issue author" "yes" "$(grep -q "github.actor == 'sironekotoro'" "$WORKFLOW" && grep -q "github.event.issue.user.login == 'sironekotoro'" "$WORKFLOW" && echo yes || echo no)"
t "workflow requires exact Codex discovery title and master body" "yes" "$(grep -q "Codex Request Shape Discovery" "$WORKFLOW" && grep -q "body must be exactly REF=master" "$WORKFLOW" && echo yes || echo no)"
t "workflow resolves immutable master SHA" "yes" "$(grep -q 'git/ref/heads/master' "$WORKFLOW" && grep -q 'ref: \${{ needs.plan.outputs.trusted_sha }}' "$WORKFLOW" && echo yes || echo no)"
t "workflow uses dedicated self-hosted runner" "yes" "$(grep -q 'runs-on: \[self-hosted, review-repair, macOS, ARM64\]' "$WORKFLOW" && echo yes || echo no)"
t "workflow checkout credentials are not persisted" "yes" "$(grep -q 'persist-credentials: false' "$WORKFLOW" && echo yes || echo no)"
t "workflow does not reference repository secrets" "yes" "$(grep -q 'secrets\.' "$WORKFLOW" && echo no || echo yes)"

t "discovery harness builds pinned production agent image" "yes" "$(grep -q 'review-repair-agent.Dockerfile' "$SCRIPT" && echo yes || echo no)"
t "discovery harness asserts Codex 0.147.0" "yes" "$(grep -q '0.147.0' "$SCRIPT" && grep -q 'codex --version' "$SCRIPT" && echo yes || echo no)"
t "discovery harness invokes production run-agent adapter" "yes" "$(grep -q '/opt/review-repair-runner/run-agent.sh' "$SCRIPT" && grep -q 'AGENT_CREDENTIAL_PROFILE=openai-api' "$SCRIPT" && echo yes || echo no)"
t "discovery harness points OpenAI base URL only at local mock" "yes" "$(grep -q 'openai_base_url = \"http://mock:8080/v1\"' "$SCRIPT" && echo yes || echo no)"
t "discovery harness runtime network is internal-only" "yes" "$(grep -q 'docker network create --internal' "$SCRIPT" && echo yes || echo no)"
t "discovery harness contains no real OpenAI provider URL" "yes" "$(grep -q 'api.openai.com' "$SCRIPT" && echo no || echo yes)"
t "discovery harness uses only a fixed non-provider capability" "yes" "$(grep -q 'AGENT_CREDENTIAL_VALUE=b2a-local-capability' "$SCRIPT" && grep -q 'OPENAI_API_KEY=' "$SCRIPT" && echo no || echo yes)"
t "discovery harness requires Responses API observation" "yes" "$(grep -q '\"/v1/responses\"' "$SCRIPT" && grep -q 'CODEX_B2A_RESPONSES_NOT_OBSERVED' "$SCRIPT" && echo yes || echo no)"
t "discovery harness verifies bearer capability shape without logging value" "yes" "$(grep -q 'authorizationMatchesCapability' "$SCRIPT" && grep -q 'authorization:' "$SCRIPT" && echo no || echo yes)"

finish
