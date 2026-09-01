#!/usr/bin/env bash
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/lib/helpers.sh"
SCRIPT="$ROOT/scripts/b2c-ordinary-codex-broker-e2e.sh"
WORKFLOW="$ROOT/.github/workflows/b2c-ordinary-codex-broker-e2e.yml"

bash -n "$SCRIPT"
t "B2c ordinary E2E script parses" 0 "$?"
t "workflow is issue-opened only" yes "$(grep -Fq 'types: [opened]' "$WORKFLOW" && echo yes || echo no)"
t "workflow restricts actor and issue author" yes "$(grep -Fq "github.actor == 'sironekotoro'" "$WORKFLOW" && grep -Fq "github.event.issue.user.login == 'sironekotoro'" "$WORKFLOW" && echo yes || echo no)"
t "workflow requires exact B2c trigger title" yes "$(grep -Fq "github.event.issue.title == 'B2c Ordinary Codex Broker E2E'" "$WORKFLOW" && echo yes || echo no)"
t "workflow fixes candidate by immutable PR head SHA" yes "$(grep -Fq 'candidate_sha' "$WORKFLOW" && grep -Fq 'ref: ${{ needs.plan.outputs.candidate_sha }}' "$WORKFLOW" && echo yes || echo no)"
t "workflow restricts candidate changed-file surface" yes "$(grep -Fq 'B2C_E2E_UNEXPECTED_CANDIDATE_FILE' "$WORKFLOW" && echo yes || echo no)"
t "workflow runs dedicated self-hosted acceptance" yes "$(grep -Fq 'runs-on: [self-hosted, review-repair, macOS, ARM64]' "$WORKFLOW" && echo yes || echo no)"
t "workflow does not reference repository secrets" yes "$(! grep -Fq 'secrets.' "$WORKFLOW" && echo yes || echo no)"
t "candidate build Dockerfiles must equal trusted master" yes "$(grep -Fq 'B2C_E2E_UNTRUSTED_BUILD_INPUT' "$SCRIPT" && echo yes || echo no)"
t "harness builds real pinned agent image" yes "$(grep -Fq 'review-repair-agent.Dockerfile' "$SCRIPT" && grep -Fq 'codex --version' "$SCRIPT" && echo yes || echo no)"
t "harness uses production ordinary container wrapper" yes "$(grep -Fq 'scripts/run-agent-dispatch-container.sh' "$SCRIPT" && echo yes || echo no)"
t "harness supplies only fake OpenAI Admin marker" yes "$(grep -Fq "OPENAI_ADMIN_KEY='b2c-local-admin-marker'" "$SCRIPT" && echo yes || echo no)"
t "harness inspects live agent environment" yes "$(grep -Fq 'docker inspect "$agent_container"' "$SCRIPT" && echo yes || echo no)"
t "harness proves Admin key absent from agent" yes "$(grep -Fq 'B2C_E2E_ADMIN_KEY_LEAKED_TO_AGENT' "$SCRIPT" && echo yes || echo no)"
t "harness proves direct OpenAI key absent from agent" yes "$(grep -Fq 'B2C_E2E_DIRECT_OPENAI_KEY_LEAKED_TO_AGENT' "$SCRIPT" && echo yes || echo no)"
t "harness proves provider proxy env absent from agent" yes "$(grep -Fq 'B2C_E2E_HTTP_PROXY_LEAKED_TO_AGENT' "$SCRIPT" && grep -Fq 'B2C_E2E_HTTPS_PROXY_LEAKED_TO_AGENT' "$SCRIPT" && grep -Fq 'B2C_E2E_ALL_PROXY_LEAKED_TO_AGENT' "$SCRIPT" && echo yes || echo no)"
t "harness proves opaque capability reaches Codex broker" yes "$(grep -Fq 'B2C_POST_AUTH_OK=1' "$SCRIPT" && echo yes || echo no)"
t "harness proves exact model reaches Codex request" yes "$(grep -Fq 'B2C_POST_MODEL_OK=1' "$SCRIPT" && echo yes || echo no)"
t "harness expects safe no-change fail-closed after successful agent call" yes "$(grep -Fq "category" "$SCRIPT" && grep -Fq "AGENT_PATCH_INVALID" "$SCRIPT" && grep -Fq "NO_CHANGES" "$SCRIPT" && echo yes || echo no)"
t "harness declares zero provider inference" yes "$(grep -Fq 'PROVIDER_INFERENCE=0' "$SCRIPT" && echo yes || echo no)"

finish
