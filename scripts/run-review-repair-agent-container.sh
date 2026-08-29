#!/usr/bin/env bash
# Execute untrusted review repair work only in an ephemeral, capability-free
# container. The host receives back only a checked patch; it never executes the
# agent's tests, hooks, package scripts, or Git configuration.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_REVIEW_SCRIPT_DIR="$SCRIPT_DIR"
source "$_REVIEW_SCRIPT_DIR/lib/common.sh"
source "$_REVIEW_SCRIPT_DIR/lib/review-repair-cleanup.sh"

target_dir="${TARGET_DIR:-$PWD}"
task_file="${TASK_FILE:-${RUNNER_TEMP:-/tmp}/task.json}"
runtime_root="${RUNNER_TEMP:-/tmp}"
agent_root=""
run_key="${GITHUB_RUN_ID:-$$}"
run_key="$(printf '%s' "$run_key" | tr -cd '[:alnum:]')"
agent_image="review-repair-agent:$run_key"
egress_image="review-repair-egress:$run_key"

[ -d "$target_dir/.git" ] || fail_with "$CAT_AGENT_START" "validated target checkout is missing .git"
[ -f "$task_file" ] || fail_with "$CAT_AGENT_START" "validated repair task is missing"
[ -n "$run_key" ] || fail_with "$CAT_AGENT_START" "review repair run identifier is invalid"
command -v docker >/dev/null 2>&1 || fail_with "$CAT_AGENT_START" "docker is required for isolated review repair"
docker info >/dev/null 2>&1 || fail_with "$CAT_AGENT_START" "docker daemon is unavailable for isolated review repair"
docker image inspect "$agent_image" >/dev/null 2>&1 || fail_with "$CAT_AGENT_START" "trusted review repair agent image is unavailable"
docker image inspect "$egress_image" >/dev/null 2>&1 || fail_with "$CAT_AGENT_START" "trusted review repair egress image is unavailable"

runner_uid="$(id -u)"
runner_gid="$(id -g)"
[ "$runner_uid" -ne 0 ] || fail_with "$CAT_AGENT_START" "review repair requires a non-root self-hosted runner user"

private_network="review-repair-private-$run_key"
egress_network="review-repair-egress-net-$run_key"
proxy_name="review-repair-proxy-$run_key"
agent_name="review-repair-agent-run-$run_key"
cleanup_networks() {
  local status="$?"
  docker rm -f "$agent_name" >/dev/null 2>&1 || true
  docker rm -f "$proxy_name" >/dev/null 2>&1 || true
  docker network rm "$private_network" >/dev/null 2>&1 || true
  docker network rm "$egress_network" >/dev/null 2>&1 || true
  cleanup_review_repair_staging "$agent_root" "$runtime_root" || true
  return "$status"
}
trap cleanup_networks EXIT

docker network create --internal "$private_network" >/dev/null \
  || fail_with "$CAT_AGENT_START" "could not create isolated agent network"
docker network create "$egress_network" >/dev/null \
  || fail_with "$CAT_AGENT_START" "could not create isolated egress network"
docker run --detach --name "$proxy_name" --network "$private_network" \
  --read-only --user 31:31 --cap-drop=ALL --security-opt=no-new-privileges \
  --tmpfs /run:rw,nosuid,nodev,noexec,mode=1777,size=16m \
  --tmpfs /var/cache/squid:rw,nosuid,nodev,noexec,mode=1777,size=64m \
  "$egress_image" >/dev/null \
  || fail_with "$CAT_AGENT_START" "could not start restricted egress proxy"
docker network connect "$egress_network" "$proxy_name" \
  || fail_with "$CAT_AGENT_START" "could not connect restricted egress proxy"
proxy_ip="$(docker inspect "$proxy_name" 2>/dev/null \
  | jq -r --arg network "$private_network" '.[0].NetworkSettings.Networks[$network].IPAddress // empty')"
[ -n "$proxy_ip" ] || fail_with "$CAT_AGENT_START" "could not determine restricted egress proxy address"

agent_root="$(mktemp -d "$runtime_root/review-repair-agent.XXXXXX")" \
  || fail_with "$CAT_AGENT_START" "could not create isolated agent workspace"
base_dir="$agent_root/base"
workspace_dir="$agent_root/workspace"
prompt_dir="$agent_root/prompt"
prompt_file="$prompt_dir/agent-prompt.txt"
mkdir -p "$base_dir" "$workspace_dir" "$prompt_dir"

# The agent sees a disposable source copy, never the checkout or its .git
# metadata. The .git-free base is mounted read-only for validation and remains
# the trusted outer executor's source for patch construction.
tar -C "$target_dir" --exclude=.git -cf - . | tar -C "$base_dir" -xf - \
  || fail_with "$CAT_AGENT_START" "could not stage target for isolated agent"
tar -C "$base_dir" -cf - . | tar -C "$workspace_dir" -xf - \
  || fail_with "$CAT_AGENT_START" "could not create isolated agent workspace"
TASK_FILE="$task_file" PROMPT_FILE="$prompt_file" \
  bash "$_REVIEW_SCRIPT_DIR/build-review-prompt.sh" \
  || fail_with "$CAT_AGENT_START" "could not prepare isolated agent prompt"
chmod 700 "$agent_root" "$base_dir" "$workspace_dir" "$prompt_dir"
chmod 400 "$prompt_file"

agent_started_epoch="$(date +%s)"
set +e
# Pass the single review credential by name so its value is not present in
# the host-visible docker command line.
docker run --name "$agent_name" --init \
  --network "$private_network" \
  --dns 127.0.0.1 \
  --read-only \
  --user "$runner_uid:$runner_gid" \
  --cap-drop=ALL \
  --security-opt=no-new-privileges \
  --pids-limit="${REVIEW_REPAIR_CONTAINER_PIDS_LIMIT:-512}" \
  --memory="${REVIEW_REPAIR_CONTAINER_MEMORY:-4g}" \
  --mount "type=bind,src=$workspace_dir,dst=/workspace" \
  --mount "type=bind,src=$base_dir,dst=/baseline,readonly" \
  --mount "type=bind,src=$prompt_file,dst=/runtime/agent-prompt.txt,readonly" \
  --tmpfs /tmp:rw,nosuid,nodev,noexec,mode=1777,size=1g \
  --tmpfs /home/agent:rw,nosuid,nodev,noexec,mode=1777,size=512m \
  --workdir /workspace \
  --env HOME=/home/agent \
  --env XDG_CONFIG_HOME=/home/agent/.config \
  --env XDG_CACHE_HOME=/home/agent/.cache \
  --env HTTPS_PROXY="http://$proxy_ip:3128" \
  --env HTTP_PROXY="http://$proxy_ip:3128" \
  --env ALL_PROXY="http://$proxy_ip:3128" \
  --env NO_PROXY=localhost,127.0.0.1 \
  --env OPENCODE_DISABLE_AUTOUPDATE=true \
  --env AGENT_USE_PREBUILT_PROMPT=true \
  --env PROMPT_FILE=/runtime/agent-prompt.txt \
  --env AGENT_LOG=/tmp/agent.log \
  --env GITHUB_OUTPUT=/tmp/agent-output \
  --env AGENT_MAX_RUNTIME="${AGENT_MAX_RUNTIME:-45}" \
  --env OPENROUTER_API_KEY \
  --env OPENROUTER_MODEL="${OPENROUTER_MODEL:-}" \
  --env AGENT_AUTO_INSTALL=false \
  "$agent_image" bash -ceu '
    selected_credential="${OPENROUTER_API_KEY:-}"
    bash /opt/review-repair-runner/run-agent.sh
    # Tests are untrusted repository code too; they must not inherit the API key.
    unset OPENROUTER_API_KEY
    if [ -f package.json ]; then
      npm test
    fi
    # Prepare a bounded diagnostic copy while the raw log is still confined to
    # the disposable container. Only this redacted copy can cross to the host.
    source /opt/review-repair-runner/lib/common.sh
    redacted_agent_log_tail /tmp/agent.log "$selected_credential" /runtime/agent-prompt.txt \
      2>/tmp/agent-redacted.log
    unset selected_credential
  '
container_status=$?
set -e
agent_finished_epoch="$(date +%s)"
agent_runtime_seconds=$((agent_finished_epoch - agent_started_epoch))

echo "runtime_seconds=$agent_runtime_seconds" >> "${GITHUB_OUTPUT:-/dev/null}"
if [ "$container_status" -ne 0 ]; then
  docker rm -f "$agent_name" >/dev/null 2>&1 || true
  exit "$container_status"
fi

# An agent-created .git is never importable: it could otherwise smuggle Git
# config or hooks into the trusted outer commit/push stage.
[ ! -e "$workspace_dir/.git" ] \
  || fail_with "$CAT_AGENT_START" "isolated agent created forbidden .git entry"

scan_final_workspace_for_credential "$workspace_dir" "${OPENROUTER_API_KEY:-}"

patch_file="$agent_root/repair.patch"
set +e
(
  cd "$agent_root"
  git diff --no-index --binary --no-ext-diff --src-prefix=a/ --dst-prefix=b/ base workspace
) > "$patch_file"
diff_status=$?
set -e

# A successful no-op is the only case that needs the agent tail. Copy only the
# already-redacted bounded diagnostic; raw /tmp/agent.log never leaves Docker.
agent_log=""
if [ "$diff_status" -eq 0 ]; then
  agent_log="$agent_root/agent-redacted.log"
  docker cp "$agent_name:/tmp/agent-redacted.log" "$agent_log" >/dev/null 2>&1 || true
fi
docker rm -f "$agent_name" >/dev/null 2>&1 || true

apply_agent_patch "$target_dir" "$patch_file" "$diff_status" "$agent_log" "${OPENROUTER_API_KEY:-}" "$prompt_file"

summary "| agent isolation | Docker; non-root; read-only root; OpenRouter-only egress; no host credentials, .git, or Docker socket |"
summary "| tests | pass (isolated agent container) |"
echo "result=pass" >> "${GITHUB_OUTPUT:-/dev/null}"