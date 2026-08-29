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

t "workflow defaults dispatch input to self-hosted" "yes" "$(grep -A7 'runner_mode:' "$WORKFLOW" | grep -q 'default: self-hosted' && echo yes || echo no)"
t "github job is explicitly dry-run only" "yes" "$(grep -q "runner_mode == 'github'.*dry_run == 'true'" "$WORKFLOW" && echo yes || echo no)"
t "self-hosted mode has a separate job using configured labels" "yes" "$(grep -q 'agent_self_hosted:' "$WORKFLOW" && grep -q 'runs-on: \${{ fromJSON(vars.REVIEW_REPAIR_RUNNER_LABELS) }}' "$WORKFLOW" && echo yes || echo no)"
t "workflow contains no GitHub-hosted coding-agent step" "yes" "$(grep -Eq 'Run (same-repo|cross-repo) coding agent$|bash .*run-agent\.sh' "$WORKFLOW" && echo no || echo yes)"
t "composite action rejects non-self-hosted execution" "yes" "$(grep -q 'Require isolated self-hosted execution' "$ACTION" && grep -q 'non-dry-run Agent Dispatch must use the isolated self-hosted executor' "$ACTION" && echo yes || echo no)"
t "composite action has no hosted agent execution branch" "yes" "$(grep -q "inputs.execution_mode == 'github'" "$ACTION" && echo no || echo yes)"
TEST_HELPER="$ROOT/scripts/run-isolated-repository-tests.sh"
t "self-hosted agent and tests use separate isolated containers" "yes" "$(grep -q 'run-agent-dispatch-container.sh' "$ACTION" && grep -q 'run-isolated-repository-tests.sh' "$CONTAINER" && grep -q -- '--read-only' "$CONTAINER" && grep -q -- '--cap-drop=ALL' "$CONTAINER" && grep -q -- '--network "\$private_network"' "$CONTAINER" && grep -q -- '--network none' "$TEST_HELPER" && grep -q 'src=\$test_dir,dst=/workspace' "$TEST_HELPER" && echo yes || echo no)"
t "agent-created git metadata is discarded before patch import" "yes" "$(grep -q 'rm -rf -- "\$workspace_dir/.git"' "$CONTAINER" && grep -q 'no agent-owned Git metadata can cross this boundary' "$CONTAINER" && echo yes || echo no)"
t "self-hosted same-repo target stays separate from dispatcher code" "yes" "$(grep -q 'Checkout same-repo target separately' "$ACTION" && grep -q 'Re-verify same-repo target checkout identity' "$ACTION" && grep -q 'working-directory: target' "$ACTION" && echo yes || echo no)"
t "separate target checkout is removed after dispatch" "yes" "$(grep -q 'Remove separate target checkout' "$ACTION" && grep -q 'rm -rf -- "\$target_dir"' "$ACTION" && echo yes || echo no)"
t "outer commit does not rerun isolated tests" "yes" "$(grep -q "AGENT_TESTS_ALREADY_RAN: 'true'" "$ACTION" && grep -q 'AGENT_TESTS_ALREADY_RAN' "$ROOT/scripts/commit-push-pr.sh" && echo yes || echo no)"
t "isolated path preserves task model and runtime semantics" "yes" "$(grep -q "steps.parse.outputs.requested_model || inputs.openrouter_model" "$ACTION" && grep -q "steps.parse.outputs.max_runtime || '10'" "$ACTION" && echo yes || echo no)"
t "per-run isolated images are cleaned on every action exit" "yes" "$(grep -q 'Remove per-run isolated images' "$ACTION" && grep -q 'agent-dispatch-agent:\$GITHUB_RUN_ID' "$ACTION" && grep -q 'agent-dispatch-egress:\$GITHUB_RUN_ID' "$ACTION" && echo yes || echo no)"
t "self-hosted path preserves cross-repo feature flag input" "yes" "$(grep -q 'cross_repo_enabled:' "$ACTION" && grep -q 'cross_repo_enabled: \${{ vars.CROSS_REPO_ENABLED' "$WORKFLOW" && echo yes || echo no)"
t "review-repair feature gate remains outside ordinary workflow" "yes" "$(grep -q 'REVIEW_REPAIR_ENABLED' "$ROOT/.github/workflows/review-repair-executor.yml" && ! grep -q 'REVIEW_REPAIR_ENABLED:' "$WORKFLOW" && echo yes || echo no)"

finish
