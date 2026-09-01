#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/lib/helpers.sh"
SCRIPT="$ROOT/scripts/provider-broker-claude-e2e.sh"
WORKFLOW="$ROOT/.github/workflows/provider-broker-claude-e2e.yml"

t "Claude broker E2E script parses" "yes" "$(bash -n "$SCRIPT" >/dev/null 2>&1 && echo yes || echo no)"
t "workflow is issue-opened only" "yes" "$(grep -Fq 'types: [opened]' "$WORKFLOW" && echo yes || echo no)"
t "workflow restricts actor and issue author" "yes" "$(grep -Fq "github.actor == 'sironekotoro'" "$WORKFLOW" && grep -Fq "github.event.issue.user.login == 'sironekotoro'" "$WORKFLOW" && echo yes || echo no)"
t "workflow requires exact Claude broker E2E title" "yes" "$(grep -Fq "github.event.issue.title == 'Claude Broker E2E'" "$WORKFLOW" && echo yes || echo no)"
t "workflow fixes candidate by same-repo PR head SHA" "yes" "$(grep -Fq "candidate_sha=\"\$(jq -r '.head.sha'" "$WORKFLOW" && grep -Fq ".head.repo.full_name" "$WORKFLOW" && echo yes || echo no)"
t "workflow restricts candidate changed-file surface" "yes" "$(grep -Fq 'scripts/provider-broker-anthropic\\.mjs' "$WORKFLOW" && grep -Fq 'disallowed candidate file' "$WORKFLOW" && echo yes || echo no)"
t "workflow runs dedicated self-hosted acceptance" "yes" "$(grep -Fq 'runs-on: [self-hosted, review-repair, macOS, ARM64]' "$WORKFLOW" && echo yes || echo no)"
t "workflow references no repository secrets" "yes" "$(grep -Eq 'secrets\.|ANTHROPIC_API_KEY:' "$WORKFLOW" && echo no || echo yes)"
t "candidate Dockerfile must equal trusted master" "yes" "$(grep -Fq 'cmp -s trusted/docker/review-repair-agent.Dockerfile candidate/docker/review-repair-agent.Dockerfile' "$WORKFLOW" && echo yes || echo no)"
t "harness builds candidate runtime with trusted Dockerfile" "yes" "$(grep -Fq -- '--file "$TRUSTED/docker/review-repair-agent.Dockerfile" "$CANDIDATE"' "$SCRIPT" && echo yes || echo no)"
t "harness asserts pinned Claude 2.1.165" "yes" "$(grep -Fq '2.1.165' "$SCRIPT" && echo yes || echo no)"
t "harness invokes production run-agent adapter" "yes" "$(grep -Fq '/opt/review-repair-runner/run-agent.sh' "$SCRIPT" && echo yes || echo no)"
t "harness routes Claude only to local broker" "yes" "$(grep -Fq 'ANTHROPIC_BROKER_BASE_URL=http://broker:3080' "$SCRIPT" && echo yes || echo no)"
t "harness runtime network is internal-only" "yes" "$(grep -Fq 'docker network create --internal "$network"' "$SCRIPT" && echo yes || echo no)"
t "harness contains no real Anthropic endpoint" "yes" "$(grep -Fq 'api.anthropic.com' "$SCRIPT" && echo no || echo yes)"
t "harness uses only fake provider credential" "yes" "$(grep -Fq 'ANTHROPIC_API_KEY=b3b-fake-provider-key' "$SCRIPT" && echo yes || echo no)"
t "harness uses opaque agent capability" "yes" "$(grep -Fq 'AGENT_CREDENTIAL_VALUE=b3b-agent-capability-marker' "$SCRIPT" && echo yes || echo no)"
t "harness validates provider key substitution" "yes" "$(grep -Fq 'providerKeyMatch' "$SCRIPT" && grep -Fq 'CLAUDE_B3B_E2E_PROVIDER_AUTH_MISMATCH' "$SCRIPT" && echo yes || echo no)"
t "harness validates exact model" "yes" "$(grep -Fq 'modelMatch' "$SCRIPT" && grep -Fq 'CLAUDE_B3B_E2E_MODEL_MISMATCH' "$SCRIPT" && echo yes || echo no)"
t "harness declares zero provider inference" "yes" "$(grep -Fq "echo 'PROVIDER_INFERENCE=0'" "$SCRIPT" && echo yes || echo no)"

finish
