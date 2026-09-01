#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
workflow="$ROOT/.github/workflows/provider-broker-codex-e2e.yml"
harness="$ROOT/scripts/provider-broker-codex-e2e.sh"

pass=0
fail=0
check() {
  local desc="$1"; shift
  if "$@"; then
    echo "PASS: $desc"
    pass=$((pass + 1))
  else
    echo "FAIL: $desc"
    fail=$((fail + 1))
  fi
}

check 'Codex broker E2E script parses' bash -n "$harness"
check 'workflow is explicit issue-opened trigger' grep -Fq 'types: [opened]' "$workflow"
check 'workflow restricts actor and issue author' grep -Fq "github.event.issue.user.login == 'sironekotoro'" "$workflow"
check 'workflow requires exact Codex broker E2E title' grep -Fq "github.event.issue.title == 'Provider Broker Codex E2E'" "$workflow"
check 'workflow fixes candidate by same-repo PR head SHA' grep -Fq 'candidate_sha=' "$workflow"
check 'workflow uses dedicated self-hosted runner' grep -Fq 'runs-on: [self-hosted, review-repair, macOS, ARM64]' "$workflow"
check 'workflow checkout credentials are not persisted' grep -Fq 'persist-credentials: false' "$workflow"
check 'workflow does not reference repository secrets' bash -c '! grep -q "secrets\." "$1"' _ "$workflow"
check 'harness builds candidate pinned agent image' grep -Fq 'review-repair-agent.Dockerfile' "$harness"
check 'harness builds candidate broker image' grep -Fq 'provider-broker.Dockerfile' "$harness"
check 'harness asserts Codex 0.147.0' grep -Fq "*'0.147.0'*" "$harness"
check 'harness invokes production run-agent adapter' grep -Fq '/opt/review-repair-runner/run-agent.sh' "$harness"
check 'harness points Codex base URL at local broker only' grep -Fq 'openai_base_url = "http://broker:3080/v1"' "$harness"
check 'harness runtime networks are internal-only' bash -c '[[ $(grep -c "docker network create --internal" "$1") -ge 2 ]]' _ "$harness"
check 'harness has no real OpenAI endpoint' bash -c '! grep -Fq "api.openai.com" "$1"' _ "$harness"
check 'harness validates provider hard cap' grep -Fq 'SPEND cents=25' "$harness"
check 'harness validates exact requested model' grep -Fq 'MODEL_POLICY mode=allow_list model=gpt-5.6-sol' "$harness"
check 'harness validates ephemeral project credential path' grep -Fq 'RESPONSES auth=ok project=ok model=gpt-5.6-sol' "$harness"
check 'harness validates service-account cleanup' grep -Fq 'SERVICE_DELETE' "$harness"
check 'harness validates project archive cleanup' grep -Fq 'PROJECT_ARCHIVE' "$harness"

printf '%s\n' '----'
printf 'PASS=%d FAIL=%d\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
