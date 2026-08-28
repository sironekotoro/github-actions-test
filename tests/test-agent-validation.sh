#!/usr/bin/env bash
# Regression coverage for the trusted final agent validation and returned
# patch boundary.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/lib/helpers.sh"

CONTAINER="$ROOT/scripts/run-agent-dispatch-container.sh"
RUN_AGENT="$ROOT/scripts/run-agent.sh"

make_target() { # <tmp>
  local tmp="$1"
  git init -q "$tmp/repo"
  git -C "$tmp/repo" config user.name test
  git -C "$tmp/repo" config user.email test@example.com
  git -C "$tmp/repo" checkout -q -b master
  printf 'base\n' > "$tmp/repo/file.txt"
  git -C "$tmp/repo" add file.txt
  git -C "$tmp/repo" commit -qm base
  printf '%s\n' '{"task_id":"validation","target_repository":"sironekotoro/github-actions-test","title":"validation","source":"test","prompt":"safe task"}' > "$tmp/task.json"
}

run_container_case() { # <tmp> <mock-docker-mode>
  local tmp="$1" mode="$2"
  mkdir -p "$tmp/bin"
  cat > "$tmp/bin/docker" <<'MOCK'
#!/usr/bin/env bash
set -uo pipefail

command="${1:-}"
subcommand="${2:-}"

if [ "$command" = "info" ]; then
  [ "${MOCK_DOCKER_MODE:-}" != "agent-start-fail" ]
  exit $?
fi

if [ "$command" = "image" ] && [ "$subcommand" = "inspect" ]; then
  exit 0
fi

if [ "$command" = "network" ]; then
  exit 0
fi

if [ "$command" = "inspect" ]; then
  printf '%s\n' '[{"NetworkSettings":{"Networks":{"agent-dispatch-private-validation123":{"IPAddress":"127.0.0.2"}}}}]'
  exit 0
fi

if [ "$command" = "run" ]; then
  is_agent=false
  workspace_mount=""
  for arg in "$@"; do
    [ "$arg" = "--rm" ] && is_agent=true
    case "$arg" in
      type=bind,src=*,dst=/workspace)
        workspace_mount="${arg#type=bind,src=}"
        workspace_mount="${workspace_mount%,dst=/workspace}"
        ;;
    esac
  done
  if [ "$is_agent" = true ] && [ -n "$workspace_mount" ]; then
    case "${MOCK_DOCKER_MODE:-}" in
      invalid)
        printf 'invalid trailing whitespace \n' >> "$workspace_mount/file.txt"
        ;;
      valid)
        printf 'valid change\n' >> "$workspace_mount/file.txt"
        ;;
    esac
  fi
  exit 0
fi

exit 0
MOCK
  chmod +x "$tmp/bin/docker"
  ( cd "$tmp/repo" && PATH="$tmp/bin:$PATH" MOCK_DOCKER_MODE="$mode" \
      RUNNER_TEMP="$tmp" GITHUB_RUN_ID=validation123 GITHUB_OUTPUT="$tmp/out" \
      TASK_FILE="$tmp/task.json" AGENT_CREDENTIAL_VALUE=mock-openrouter-key \
      export PATH MOCK_DOCKER_MODE RUNNER_TEMP GITHUB_RUN_ID GITHUB_OUTPUT TASK_FILE AGENT_CREDENTIAL_VALUE; \
      bash "$CONTAINER" >"$tmp/stdout" 2>"$tmp/stderr" )
  printf '%s\n' "$?" > "$tmp/code"
}

# The trusted wrapper rejects a patch with trailing whitespace and records the
# distinct post-agent validation category without changing the target tree.
tmp="$(make_temp)"
make_target "$tmp"
run_container_case "$tmp" invalid
t "invalid returned patch is rejected" "1|AGENT_PATCH_INVALID" "$(cat "$tmp/code")|$(cat "$tmp/failure_category")"
t "invalid returned patch is not imported" "base" "$(cat "$tmp/repo/file.txt")"

# A clean patch still crosses the same trusted import boundary successfully.
tmp="$(make_temp)"
make_target "$tmp"
run_container_case "$tmp" valid
t "valid returned patch imports" "0|" "$(cat "$tmp/code")|$(cat "$tmp/failure_category")"
t "valid patch content is imported" "valid change" "$(tail -n 1 "$tmp/repo/file.txt")"

# Infrastructure failures before agent completion remain AGENT_START_FAILED.
tmp="$(make_temp)"
make_target "$tmp"
run_container_case "$tmp" agent-start-fail
t "agent start failure keeps existing category" "1|AGENT_START_FAILED" "$(cat "$tmp/code")|$(cat "$tmp/failure_category")"

run_agent_case() { # <tmp> <mock-agent-mode>
  local tmp="$1" mode="$2"
  mkdir -p "$tmp/bin"
  printf 'trusted prompt\n' > "$tmp/prompt"
  cat > "$tmp/bin/opencode" <<'MOCK'
#!/usr/bin/env bash
printf 'mock API failure\n'
exit 7
MOCK
  if [ "$mode" = timeout ]; then
    cat > "$tmp/bin/timeout" <<'MOCK'
#!/usr/bin/env bash
exit 124
MOCK
    chmod +x "$tmp/bin/timeout"
  fi
  chmod +x "$tmp/bin/opencode"
  ( PATH="$tmp/bin:$PATH" AGENT=opencode MOCK_AGENT_MODE="$mode" RUNNER_TEMP="$tmp" \
      GITHUB_OUTPUT="$tmp/out" GITHUB_STEP_SUMMARY="$tmp/summary.md" \
      PROMPT_FILE="$tmp/prompt" AGENT_LOG="$tmp/agent.log" \
      AGENT_USE_PREBUILT_PROMPT=true AGENT_AUTO_INSTALL=false \
      AGENT_MAX_ATTEMPTS=1 AGENT_MAX_RUNTIME=1 OPENROUTER_MODEL=test/model \
      OPENROUTER_API_KEY=mock-openrouter-key; \
      export PATH AGENT MOCK_AGENT_MODE RUNNER_TEMP GITHUB_OUTPUT GITHUB_STEP_SUMMARY PROMPT_FILE AGENT_LOG \
        AGENT_USE_PREBUILT_PROMPT AGENT_AUTO_INSTALL AGENT_MAX_ATTEMPTS AGENT_MAX_RUNTIME \
        OPENROUTER_MODEL OPENROUTER_API_KEY; \
      bash "$RUN_AGENT" >"$tmp/stdout" 2>"$tmp/stderr" )
  printf '%s\n' "$?" > "$tmp/code"
}

# Existing model API and timeout categories remain distinct from patch errors.
tmp="$(make_temp)"
run_agent_case "$tmp" api
t "API failure keeps existing category" "7|MODEL_API_FAILED" "$(cat "$tmp/code")|$(cat "$tmp/failure_category")"

tmp="$(make_temp)"
run_agent_case "$tmp" timeout
t "timeout keeps existing category" "124|AGENT_TIMEOUT" "$(cat "$tmp/code")|$(cat "$tmp/failure_category")"

finish
