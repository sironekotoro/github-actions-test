#!/usr/bin/env bash
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/lib/helpers.sh"

WORKFLOW="$ROOT/.github/workflows/provider-broker-opencode-e2e.yml"
SCRIPT="$ROOT/scripts/provider-broker-opencode-e2e.sh"

bash -n "$SCRIPT"
t "OpenCode E2E script parses" "0" "$?"

t "workflow is explicit issue-opened trigger" "yes" \
  "$(grep -q 'types: \[opened\]' "$WORKFLOW" && echo yes || echo no)"
t "workflow restricts actor and issue author" "yes" \
  "$(grep -q "github.actor == 'sironekotoro'" "$WORKFLOW" && grep -q "github.event.issue.user.login == 'sironekotoro'" "$WORKFLOW" && echo yes || echo no)"
t "workflow requires exact OpenCode E2E title" "yes" \
  "$(grep -q "Provider Broker OpenCode E2E" "$WORKFLOW" && echo yes || echo no)"
t "workflow fixes candidate by PR head SHA" "yes" \
  "$(grep -q 'candidate_sha' "$WORKFLOW" && grep -q 'ref: \${{ needs.plan.outputs.candidate_sha }}' "$WORKFLOW" && echo yes || echo no)"
t "workflow uses dedicated self-hosted runner" "yes" \
  "$(grep -q 'runs-on: \[self-hosted, review-repair, macOS, ARM64\]' "$WORKFLOW" && echo yes || echo no)"
t "workflow checkout credentials are not persisted" "yes" \
  "$(count="$(grep -c 'persist-credentials: false' "$WORKFLOW")"; [ "$count" -ge 2 ] && echo yes || echo no)"
t "workflow does not reference repository secrets" "yes" \
  "$(grep -q 'secrets\.' "$WORKFLOW" && echo no || echo yes)"

t "contract harness builds candidate pinned agent image" "yes" \
  "$(grep -q 'review-repair-agent.Dockerfile' "$SCRIPT" && echo yes || echo no)"
t "contract harness asserts OpenCode 1.18.16" "yes" \
  "$(grep -q "1.18.16" "$SCRIPT" && grep -q 'opencode.*--version' "$SCRIPT" && echo yes || echo no)"
t "contract harness invokes production run-agent adapter" "yes" \
  "$(grep -q '/opt/review-repair-runner/run-agent.sh' "$SCRIPT" && grep -q 'AGENT_CREDENTIAL_PROFILE=openrouter-broker' "$SCRIPT" && echo yes || echo no)"
t "contract harness uses production broker baseURL form" "yes" \
  "$(grep -q 'OPENCODE_BROKER_BASE_URL=http://broker:3080' "$SCRIPT" && echo yes || echo no)"
t "contract harness runtime networks are internal-only" "yes" \
  "$(count="$(grep -c 'docker network create --internal' "$SCRIPT")"; [ "$count" -eq 2 ] && echo yes || echo no)"
t "contract harness starts broker where management mock is reachable" "yes" \
  "$(grep -A4 'docker run -d' "$SCRIPT" | grep -q -- '--network "$mock_net"' && echo yes || echo no)"
t "contract harness attaches broker alias to agent network" "yes" \
  "$(grep -q 'docker network connect --alias broker "$agent_net" "$broker_name"' "$SCRIPT" && echo yes || echo no)"
t "contract harness has no OpenRouter external endpoint" "yes" \
  "$(grep -q 'openrouter.ai' "$SCRIPT" && echo no || echo yes)"
t "contract harness checks temporary key cleanup" "yes" \
  "$(grep -q 'MGMT_DELETE' "$SCRIPT" && grep -q 'docker stop --time 10' "$SCRIPT" && echo yes || echo no)"

finish
