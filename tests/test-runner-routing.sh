#!/usr/bin/env bash
# Runner selection for ordinary Agent Dispatch must be explicit and fail-closed.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/lib/helpers.sh"

CHECK="$ROOT/scripts/check-agent-dispatch-runner.sh"
WORKFLOW="$ROOT/.github/workflows/agent-dispatch.yml"
ACTION="$ROOT/.github/actions/agent-dispatch/action.yml"
CONTAINER="$ROOT/scripts/run-agent-dispatch-container.sh"

tmp="$(make_temp)"
RUNNER_TEMP="$tmp" AGENT_DISPATCH_RUNNER_LABELS='' bash "$CHECK" >/dev/null 2>"$tmp/err"
t "missing self-hosted runner labels fail closed" "1|AGENT_EXECUTOR_UNAVAILABLE" "$?|$(cat "$tmp/failure_category")"

tmp="$(make_temp)"
RUNNER_TEMP="$tmp" AGENT_DISPATCH_RUNNER_LABELS='["ubuntu-latest"]' bash "$CHECK" >/dev/null 2>"$tmp/err"
t "hosted runner labels do not select self-hosted" "1|AGENT_EXECUTOR_UNAVAILABLE" "$?|$(cat "$tmp/failure_category")"

tmp="$(make_temp)"
RUNNER_TEMP="$tmp" GITHUB_OUTPUT="$tmp/out" AGENT_DISPATCH_RUNNER_LABELS='["self-hosted","review-repair","macOS","ARM64"]' \
  bash "$CHECK" >/dev/null
t "existing Mac runner labels are accepted" "0|result=pass" "$?|$(tr -d '\n' < "$tmp/out")"

t "workflow defaults dispatch input to github" "yes" "$(grep -A7 'runner_mode:' "$WORKFLOW" | grep -q 'default: github' && echo yes || echo no)"
t "github mode keeps a static hosted job" "yes" "$(grep -q 'agent_github:' "$WORKFLOW" && grep -A7 'agent_github:' "$WORKFLOW" | grep -q 'runs-on: ubuntu-latest' && echo yes || echo no)"
t "self-hosted mode has a separate job using configured labels" "yes" "$(grep -q 'agent_self_hosted:' "$WORKFLOW" && grep -q 'runs-on: \${{ fromJSON(vars.REVIEW_REPAIR_RUNNER_LABELS) }}' "$WORKFLOW" && echo yes || echo no)"
t "self-hosted mode is explicit opt-in" "yes" "$(grep -q "needs.route.outputs.runner_mode == 'self-hosted'" "$WORKFLOW" && grep -q "needs.route.outputs.runner_mode == 'github'" "$WORKFLOW" && echo yes || echo no)"
t "self-hosted agent and tests use isolated container" "yes" "$(grep -q 'run-agent-dispatch-container.sh' "$ACTION" && grep -q 'unset OPENROUTER_API_KEY' "$CONTAINER" && grep -q -- '--read-only' "$CONTAINER" && grep -q -- '--cap-drop=ALL' "$CONTAINER" && grep -q -- '--network "\$private_network"' "$CONTAINER" && echo yes || echo no)"
t "outer commit does not rerun isolated tests" "yes" "$(grep -q 'AGENT_TESTS_ALREADY_RAN' "$ACTION" && grep -q 'AGENT_TESTS_ALREADY_RAN' "$ROOT/scripts/commit-push-pr.sh" && echo yes || echo no)"
t "review-repair feature gate remains outside ordinary workflow" "yes" "$(grep -q 'REVIEW_REPAIR_ENABLED' "$ROOT/.github/workflows/review-repair-executor.yml" && ! grep -q 'REVIEW_REPAIR_ENABLED:' "$WORKFLOW" && echo yes || echo no)"

finish
