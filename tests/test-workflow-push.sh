#!/usr/bin/env bash
# Agent-generated workflow files must never be published automatically.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/lib/helpers.sh"

CLASSIFY="$ROOT/scripts/classify-workflow-push.sh"
COMMIT="$ROOT/scripts/commit-push-pr.sh"
ACTION="$ROOT/.github/actions/agent-dispatch/action.yml"
WORKFLOW="$ROOT/.github/workflows/agent-dispatch.yml"
CONTAINER="$ROOT/scripts/run-agent-dispatch-container.sh"

make_repo() { # <target-repository> -> prints temp root
  local target="$1" tmp
  tmp="$(make_temp)"
  git init -q "$tmp/repo"
  git -C "$tmp/repo" config user.name test
  git -C "$tmp/repo" config user.email test@example.com
  git -C "$tmp/repo" checkout -q -b master
  printf 'base\n' > "$tmp/repo/file.txt"
  git -C "$tmp/repo" add file.txt
  git -C "$tmp/repo" commit -qm base
  git -C "$tmp/repo" remote add origin "https://github.com/$target.git"
  git -C "$tmp/repo" checkout -q -b agent/workflow-test
  jq -cn --arg target "$target" \
    '{task_id:"workflow-test",target_repository:$target,title:"workflow test",source:"test",prompt:"normal prompt",dry_run:false}' \
    > "$tmp/task.json"
  printf '%s\n' "$tmp"
}

classify() { # <tmp> <mode> <dispatcher>
  local tmp="$1" mode="$2" dispatcher="$3"
  (cd "$tmp/repo" && RUNNER_TEMP="$tmp" GITHUB_OUTPUT="$tmp/out" TASK_FILE="$tmp/task.json" \
    DEFAULT_BRANCH=master DISPATCH_MODE="$mode" DISPATCHER_REPOSITORY="$dispatcher" \
    bash "$CLASSIFY" >"$tmp/stdout" 2>"$tmp/stderr")
}

# T1: ordinary changes remain publishable through the normal trusted path.
tmp="$(make_repo sironekotoro/github-actions-test)"
printf 'ordinary\n' >> "$tmp/repo/file.txt"
classify "$tmp" same sironekotoro/github-actions-test
t "ordinary diff remains allowed" "0|pass|false" "$?|$(awk -F= '$1 == "result" {print $2}' "$tmp/out")|$(awk -F= '$1 == "workflow_change" {print $2}' "$tmp/out")"

# T2: same-repository workflow changes fail before any commit/push stage.
tmp="$(make_repo sironekotoro/github-actions-test)"
mkdir -p "$tmp/repo/.github/workflows"
printf 'name: test\n' > "$tmp/repo/.github/workflows/test.yml"
set +e
classify "$tmp" same sironekotoro/github-actions-test
code=$?
set -e
t "same-repo workflow diff fails closed" "1|WORKFLOW_PUSH_AUTH_NOT_CONFIGURED" "$code|$(cat "$tmp/failure_category")"

# T3: cross-repository workflow changes remain fail-closed.
tmp="$(make_repo sironekotoro/zengin-pl)"
mkdir -p "$tmp/repo/.github/workflows"
printf 'name: test\n' > "$tmp/repo/.github/workflows/test.yml"
set +e
classify "$tmp" cross sironekotoro/github-actions-test
code=$?
set -e
t "cross-repo workflow diff fails closed" "1|CROSS_REPO_WORKFLOW_PUSH_UNSUPPORTED" "$code|$(cat "$tmp/failure_category")"

# T4/T5: commit-push-pr.sh independently enforces the same policy, even if a
# future refactor accidentally bypasses the classifier.
tmp="$(make_repo sironekotoro/github-actions-test)"
mkdir -p "$tmp/repo/.github/workflows"
printf 'name: test\n' > "$tmp/repo/.github/workflows/test.yml"
set +e
(cd "$tmp/repo" && RUNNER_TEMP="$tmp" GITHUB_OUTPUT="$tmp/commit.out" TASK_FILE="$tmp/task.json" \
  DEFAULT_BRANCH=master DISPATCH_MODE=same DISPATCHER_REPOSITORY=sironekotoro/github-actions-test \
  DISPATCH_PRINCIPAL='github-actions[bot]' AGENT_TESTS_ALREADY_RAN=true \
  bash "$COMMIT" >"$tmp/commit.stdout" 2>"$tmp/commit.stderr")
code=$?
set -e
t "trusted commit path rejects same-repo workflow diff" "1|WORKFLOW_PUSH_AUTH_NOT_CONFIGURED" "$code|$(cat "$tmp/failure_category")"
t "rejected workflow diff performs no commit" "base" "$(git -C "$tmp/repo" log -1 --format=%s)"

# T6: there is no workflow-write credential route left in the composite action.
t "workflow-write App token route is removed" "absent" "$(grep -Eq 'permission-workflows|workflow_push_token|commit_same_workflow|WORKFLOW_PUSH_MODE' "$ACTION" && echo present || echo absent)"

# T7: the outer workflow also contains no workflow-write token request.
t "outer workflow contains no workflow-write permission request" "absent" "$(grep -q 'permission-workflows' "$WORKFLOW" && echo present || echo absent)"

# T8: the isolated agent container never receives any workflow publication credential.
t "container script has no workflow credential environment" "absent" "$(grep -Eq 'WORKFLOW_PUSH|workflow_push_token|permission-workflows' "$CONTAINER" && echo present || echo absent)"

finish
