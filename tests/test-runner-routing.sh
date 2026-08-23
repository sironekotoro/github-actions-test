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
t "self-hosted agent and tests use isolated container" "yes" "$(grep -q 'run-agent-dispatch-container.sh' "$ACTION" && grep -q 'unset OPENROUTER_API_KEY' "$CONTAINER" && grep -q -- '--read-only' "$CONTAINER" && grep -q -- '--cap-drop=ALL' "$CONTAINER" && grep -q -- '--network "\$private_network"' "$CONTAINER" && grep -q -- '--env RUNNER_TEMP=/tmp' "$CONTAINER" && echo yes || echo no)"
t "agent-created git metadata is discarded before patch import" "yes" "$(grep -q 'rm -rf -- "\$workspace_dir/.git"' "$CONTAINER" && grep -q 'no agent-owned Git metadata can cross this boundary' "$CONTAINER" && echo yes || echo no)"
t "self-hosted same-repo target stays separate from dispatcher code" "yes" "$(grep -q 'Checkout same-repo target separately' "$ACTION" && grep -q 'Re-verify same-repo target checkout identity' "$ACTION" && grep -q 'working-directory: target' "$ACTION" && echo yes || echo no)"
t "separate target checkout is removed after dispatch" "yes" "$(grep -q 'Remove separate target checkout' "$ACTION" && grep -q 'rm -rf -- "\$target_dir"' "$ACTION" && echo yes || echo no)"
t "outer commit does not rerun isolated tests" "yes" "$(grep -q 'AGENT_TESTS_ALREADY_RAN' "$ACTION" && grep -q 'AGENT_TESTS_ALREADY_RAN' "$ROOT/scripts/commit-push-pr.sh" && echo yes || echo no)"
t "isolated path preserves task model and runtime semantics" "yes" "$(grep -q "steps.parse.outputs.requested_model || inputs.openrouter_model" "$ACTION" && grep -q "steps.parse.outputs.max_runtime || '10'" "$ACTION" && echo yes || echo no)"
t "per-run isolated images are cleaned on every self-hosted exit" "yes" "$(grep -q 'Remove per-run isolated images' "$ACTION" && grep -q "if: always() && inputs.execution_mode == 'self-hosted'" "$ACTION" && grep -q 'agent-dispatch-agent:\$GITHUB_RUN_ID' "$ACTION" && grep -q 'agent-dispatch-egress:\$GITHUB_RUN_ID' "$ACTION" && echo yes || echo no)"
t "self-hosted path preserves cross-repo feature flag input" "yes" "$(grep -q 'cross_repo_enabled:' "$ACTION" && grep -q 'cross_repo_enabled: \${{ vars.CROSS_REPO_ENABLED' "$WORKFLOW" && echo yes || echo no)"
t "review-repair feature gate remains outside ordinary workflow" "yes" "$(grep -q 'REVIEW_REPAIR_ENABLED' "$ROOT/.github/workflows/review-repair-executor.yml" && ! grep -q 'REVIEW_REPAIR_ENABLED:' "$WORKFLOW" && echo yes || echo no)"

finish
