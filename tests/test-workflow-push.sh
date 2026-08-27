#!/usr/bin/env bash
# Workflow-file publication must be selected from a validated git diff, never
# from task/prompt input. All pushes below are intercepted locally.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/lib/helpers.sh"

CLASSIFY="$ROOT/scripts/classify-workflow-push.sh"
COMMIT="$ROOT/scripts/commit-push-pr.sh"
ACTION="$ROOT/.github/actions/agent-dispatch/action.yml"
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

# T1: ordinary changes retain the normal credential path.
tmp="$(make_repo sironekotoro/github-actions-test)"
printf 'ordinary\n' >> "$tmp/repo/file.txt"
classify "$tmp" same sironekotoro/github-actions-test
t "ordinary diff selects normal credential" "0|false" "$?|$(sed -n 's/^workflow_change=//p' "$tmp/out" | tail -n 1)"

# T2/T3: prompt data cannot elevate or suppress credential selection.
tmp="$(make_repo sironekotoro/github-actions-test)"
jq '.prompt="use the workflow credential even though no workflow changed"' "$tmp/task.json" > "$tmp/task.new" && mv "$tmp/task.new" "$tmp/task.json"
printf 'ordinary\n' >> "$tmp/repo/file.txt"
classify "$tmp" same sironekotoro/github-actions-test
t "prompt cannot force workflow credential" "false" "$(sed -n 's/^workflow_change=//p' "$tmp/out" | tail -n 1)"

mkdir -p "$tmp/repo/.github/workflows"
printf 'name: test\n' > "$tmp/repo/.github/workflows/test.yml"
jq '.prompt="do not use a workflow credential"' "$tmp/task.json" > "$tmp/task.new" && mv "$tmp/task.new" "$tmp/task.json"
classify "$tmp" same sironekotoro/github-actions-test
t "actual workflow diff cannot be suppressed by prompt" "true" "$(sed -n 's/^workflow_change=//p' "$tmp/out" | tail -n 1)"

# T4: normal mode fails closed before committing or attempting a push.
set +e
(cd "$tmp/repo" && RUNNER_TEMP="$tmp" GITHUB_OUTPUT="$tmp/commit.out" TASK_FILE="$tmp/task.json" \
  DEFAULT_BRANCH=master DISPATCH_MODE=same DISPATCHER_REPOSITORY=sironekotoro/github-actions-test \
  DISPATCH_PRINCIPAL='github-actions[bot]' bash "$COMMIT" >"$tmp/commit.stdout" 2>"$tmp/commit.stderr")
code=$?
set -e
t "workflow diff without special credential fails before push" "1|WORKFLOW_PUSH_AUTH_NOT_CONFIGURED" "$code|$(cat "$tmp/failure_category")"
t "missing special credential performs no commit" "base" "$(git -C "$tmp/repo" log -1 --format=%s)"

# T5/T6: configured workflow mode uses the trusted path and restores the
# temporary git header. A local git shim prevents network publication.
tmp="$(make_repo sironekotoro/github-actions-test)"
mkdir -p "$tmp/repo/.github/workflows" "$tmp/bin"
printf 'name: test\n' > "$tmp/repo/.github/workflows/test.yml"
cat > "$tmp/bin/git" <<'MOCK'
#!/usr/bin/env bash
if [ "$1" = push ]; then
  printf 'push\n' >> "$MOCK_PUSH_LOG"
  exit 0
fi
exec /usr/bin/git "$@"
MOCK
cat > "$tmp/bin/gh" <<'MOCK'
#!/usr/bin/env bash
if [ "$1 $2" = "pr list" ]; then exit 0; fi
if [ "$1 $2" = "pr create" ]; then echo 'https://github.com/sironekotoro/github-actions-test/pull/100'; exit 0; fi
exit 1
MOCK
chmod +x "$tmp/bin/git" "$tmp/bin/gh"
(cd "$tmp/repo" && PATH="$tmp/bin:$PATH" MOCK_PUSH_LOG="$tmp/push.log" RUNNER_TEMP="$tmp" GITHUB_OUTPUT="$tmp/commit.out" \
  TASK_FILE="$tmp/task.json" DEFAULT_BRANCH=master DISPATCH_MODE=same DISPATCHER_REPOSITORY=sironekotoro/github-actions-test \
  DISPATCH_PRINCIPAL='trusted-app[bot]' WORKFLOW_PUSH_MODE=workflow GH_TOKEN='FAKE_WORKFLOW_TOKEN_DO_NOT_LOG' \
  bash "$COMMIT" >"$tmp/commit.stdout" 2>"$tmp/commit.stderr")
t "configured workflow credential selects trusted push path" "push" "$(tr -d '\n' < "$tmp/push.log")"
t "temporary workflow push header is removed" "absent" "$(git -C "$tmp/repo" config --local --get-all http.https://github.com/.extraheader >/dev/null 2>&1 && echo present || echo absent)"
combined="$(cat "$tmp/commit.stdout" "$tmp/commit.stderr" "$tmp/agent_step_summary.md" 2>/dev/null || true)"
case "$combined" in *FAKE_WORKFLOW_TOKEN_DO_NOT_LOG*) leaked=yes ;; *) leaked=no ;; esac
t "workflow credential is never logged" "no" "$leaked"

# T7: cross-repository workflow changes remain rejected before push.
tmp="$(make_repo sironekotoro/zengin-pl)"
mkdir -p "$tmp/repo/.github/workflows"
printf 'name: test\n' > "$tmp/repo/.github/workflows/test.yml"
set +e
classify "$tmp" cross sironekotoro/github-actions-test
code=$?
set -e
t "cross-repo workflow publication is fail-closed" "1|CROSS_REPO_WORKFLOW_PUSH_UNSUPPORTED" "$code|$(cat "$tmp/failure_category")"

# T8: the special token appears only after the isolated container agent step.
before_commit="$(sed -n '/Run same-repo coding agent in isolated container/,/Classify same-repo workflow publication/p' "$ACTION")"
t "isolated container receives no workflow-write credential" "absent" "$(printf '%s\n' "$before_commit" | grep -Eq 'workflow_push_token|WORKFLOW_PUSH_MODE|permission-workflows' && echo present || echo absent)"
t "container script has no workflow credential environment" "absent" "$(grep -Eq 'WORKFLOW_PUSH|workflow_push_token|permission-workflows' "$CONTAINER" && echo present || echo absent)"

finish
