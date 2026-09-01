#!/usr/bin/env bash
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/lib/helpers.sh"

SCRIPT="$ROOT/scripts/claude-request-shape-discovery.sh"
WORKFLOW="$ROOT/.github/workflows/claude-request-shape-discovery.yml"
DOCKERFILE="$ROOT/docker/review-repair-agent.Dockerfile"
ADAPTER="$ROOT/scripts/agents/claude-code.sh"

# Pinned binary and zero-paid local-only discovery contract.
t "Claude discovery uses pinned 2.1.165 image" "yes" \
  "$(grep -Fq 'CLAUDE_CODE_VERSION=2.1.165' "$DOCKERFILE" && grep -Fq 'expected pinned Claude Code 2.1.165' "$SCRIPT" && echo yes || echo no)"
t "Claude discovery uses internal-only Docker network" "yes" \
  "$(grep -Fq 'docker network create --internal "$network"' "$SCRIPT" && echo yes || echo no)"
t "Claude discovery routes inference only to local mock" "yes" \
  "$(grep -Fq 'ANTHROPIC_BASE_URL=http://mock:8080' "$SCRIPT" && ! grep -Fq 'api.anthropic.com' "$SCRIPT" && echo yes || echo no)"
t "Claude discovery uses fake capability rather than real API secret" "yes" \
  "$(grep -Fq 'ANTHROPIC_API_KEY=b3a-local-capability' "$SCRIPT" && echo yes || echo no)"
t "Claude discovery disables nonessential traffic" "yes" \
  "$(grep -Fq 'CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1' "$SCRIPT" && grep -Fq 'DISABLE_TELEMETRY=1' "$SCRIPT" && grep -Fq 'DISABLE_ERROR_REPORTING=1' "$SCRIPT" && grep -Fq 'DISABLE_AUTOUPDATER=1' "$SCRIPT" && echo yes || echo no)"
t "Claude discovery runs probe as non-root runner identity" "yes" \
  "$(grep -Fq 'runner_uid="$(id -u)"' "$SCRIPT" && grep -Fq '[ "$runner_uid" -ne 0 ]' "$SCRIPT" && grep -Fq -- '--user "$runner_uid:$runner_gid"' "$SCRIPT" && echo yes || echo no)"
t "Claude discovery keeps non-root runtime tmpfs writable" "yes" \
  "$(grep -Fq -- '--tmpfs /runtime:rw,nosuid,nodev,mode=1777,size=128m' "$SCRIPT" && grep -Fq -- '--tmpfs /tmp:rw,nosuid,nodev,mode=1777,size=128m' "$SCRIPT" && echo yes || echo no)"

# Request-shape capture records metadata only; prompt/body/credential values are
# never emitted in CAPTURE records.
t "Claude capture records safe request metadata" "yes" \
  "$(grep -Fq 'rawBytes: raw.length' "$SCRIPT" && grep -Fq 'bodyKeys:' "$SCRIPT" && grep -Fq 'toolCount:' "$SCRIPT" && echo yes || echo no)"
t "Claude capture does not log raw body" "yes" \
  "$( ! grep -Eq 'CAPTURE.*raw\.toString|CAPTURE.*expectedCapability' "$SCRIPT" && echo yes || echo no)"
t "Claude discovery expects Messages API" "yes" \
  "$(grep -Fq '/v1/messages' "$SCRIPT" && grep -Fq 'CLAUDE_B3A_MESSAGES_NOT_OBSERVED' "$SCRIPT" && echo yes || echo no)"
t "Claude discovery observes API-key auth shape without printing key" "yes" \
  "$(grep -Fq 'xApiKeyMatchesCapability' "$SCRIPT" && grep -Fq 'authorizationMatchesCapability' "$SCRIPT" && echo yes || echo no)"
t "Claude discovery explicitly binds a marker model" "yes" \
  "$(grep -Fq -- '--model b3a-requested-model-marker' "$SCRIPT" && grep -Fq 'CLAUDE_B3A_MODEL_BINDING_MISMATCH' "$SCRIPT" && echo yes || echo no)"

# Trusted workflow trigger contract.
t "Claude discovery workflow is owner-only issue triggered" "yes" \
  "$(grep -Fq "github.actor == 'sironekotoro'" "$WORKFLOW" && grep -Fq "github.event.issue.title == 'Claude Request Shape Discovery'" "$WORKFLOW" && echo yes || echo no)"
t "Claude discovery workflow requires exact master request body" "yes" \
  "$(grep -Fq "[ \"\$ISSUE_BODY\" = 'REF=master' ]" "$WORKFLOW" && echo yes || echo no)"
t "Claude discovery runs only on self-hosted review-repair Mac" "yes" \
  "$(grep -Fq 'runs-on: [self-hosted, review-repair, macOS, ARM64]' "$WORKFLOW" && echo yes || echo no)"
t "Claude discovery workflow receives no repository secrets" "yes" \
  "$( ! grep -Eq 'secrets\.|ANTHROPIC_API_KEY:' "$WORKFLOW" && echo yes || echo no)"

# B3a discovered that the adapter dropped the trusted model. B3b closes that
# gap and this regression now freezes explicit exact-model binding.
t "B3b Claude production adapter forwards trusted model flag" "yes" \
  "$(grep -Fq 'local model="$1"' "$ADAPTER" && grep -Fq 'claude -p "$prompt" --model "$model"' "$ADAPTER" && echo yes || echo no)"

finish
