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
broker_image="provider-broker:$run_key"

[ -d "$target_dir/.git" ] || fail_with "$CAT_AGENT_START" "validated target checkout is missing .git"
[ -f "$task_file" ] || fail_with "$CAT_AGENT_START" "validated repair task is missing"
[ -n "$run_key" ] || fail_with "$CAT_AGENT_START" "review repair run identifier is invalid"
command -v docker >/dev/null 2>&1 || fail_with "$CAT_AGENT_START" "docker is required for isolated review repair"
docker info >/dev/null 2>&1 || fail_with "$CAT_AGENT_START" "docker daemon is unavailable for isolated review repair"
docker image inspect "$agent_image" >/dev/null 2>&1 || fail_with "$CAT_AGENT_START" "trusted review repair agent image is unavailable"
docker image inspect "$egress_image" >/dev/null 2>&1 || fail_with "$CAT_AGENT_START" "trusted review repair egress image is unavailable"

if [ "${PROVIDER_BROKER_ENABLED:-false}" = "true" ]; then
  docker image inspect "$broker_image" >/dev/null 2>&1 || fail_with "$CAT_BROKER_UNAVAILABLE" "provider broker image is unavailable"
  [ -n "${OPENROUTER_MANAGEMENT_KEY:-}" ] || fail_with "$CAT_BROKER_UNAVAILABLE" "OPENROUTER_MANAGEMENT_KEY required when broker enabled"
fi

runner_uid="$(id -u)"
runner_gid="$(id -g)"
[ "$runner_uid" -ne 0 ] || fail_with "$CAT_AGENT_START" "review repair requires a non-root self-hosted runner user"

private_network="review-repair-private-$run_key"
egress_network="review-repair-egress-net-$run_key"
broker_egress_network="review-repair-broker-egress-$run_key"
proxy_name="review-repair-proxy-$run_key"
agent_name="review-repair-agent-run-$run_key"
broker_name="review-repair-broker-$run_key"
broker_started=false

cleanup_networks() {
  local status="$?"
  if [ "$broker_started" = true ]; then
    docker stop --time 10 "$broker_name" >/dev/null 2>&1 || true
    docker rm -f "$broker_name" >/dev/null 2>&1 || true
  fi
  docker rm -f "$agent_name" >/dev/null 2>&1 || true
  docker rm -f "$proxy_name" >/dev/null 2>&1 || true
  docker network rm "$broker_egress_network" >/dev/null 2>&1 || true
  docker network rm "$private_network" >/dev/null 2>&1 || true
  docker network rm "$egress_network" >/dev/null 2>&1 || true
  cleanup_review_repair_staging "$agent_root" "$runtime_root" || true
  return "$status"
}
trap cleanup_networks EXIT

# Start broker container when broker is enabled
openroute_model="${OPENROUTER_MODEL:-openrouter/deepseek/deepseek-v4-flash}"
opencode_broker_base_url=""
broker_capability=""
if [ "${PROVIDER_BROKER_ENABLED:-false}" = "true" ] && [ -n "${OPENROUTER_MANAGEMENT_KEY:-}" ]; then
  generate_broker_capability broker_capability

  setup_broker_network_topology "$private_network" "$egress_network" "$broker_egress_network" \
    "$proxy_name" "$egress_image" "$run_key"

  # Export capability values to env so docker -e NAME (name-only) picks them up
  export BROKER_CAPABILITY="$broker_capability"
  export OPENROUTER_API_KEY="$broker_capability"

  # Start broker on private_network (agent comms) and connect to broker_egress_network (restricted egress)
  docker run --detach --name "$broker_name" \
    --network "$private_network" \
    --read-only \
    --cap-drop=ALL \
    --security-opt=no-new-privileges \
    --pids-limit=64 \
    --memory=256m \
    --tmpfs /tmp:rw,nosuid,nodev,noexec,mode=1777,size=64m \
    -e BROKER_PORT=3080 \
    -e OPENROUTER_MANAGEMENT_KEY \
    -e BROKER_CAPABILITY \
    -e BROKER_TASK_ID="${GITHUB_RUN_ID:-unknown}" \
    -e BROKER_ALLOWED_MODEL="$openroute_model" \
    -e BROKER_JOB_MAX_USD="${PROVIDER_JOB_MAX_USD:-0.25}" \
    -e BROKER_MAX_REQUESTS="${BROKER_MAX_REQUESTS:-500}" \
    -e BROKER_CAPABILITY_EXPIRY_MS="${BROKER_CAPABILITY_EXPIRY_MS:-3600000}" \
    -e BROKER_PROXY_URL="http://${PROXY_BROKER_IP}:3128" \
    -e NO_PROXY=localhost,127.0.0.1 \
    "$broker_image" >/dev/null \
    || { cleanup_networks; fail_with "$CAT_BROKER_UNAVAILABLE" "could not start broker container"; }

  docker network connect "$broker_egress_network" "$broker_name" \
    || { cleanup_networks; fail_with "$CAT_BROKER_UNAVAILABLE" "could not connect broker to egress network"; }

  broker_ip="$(docker inspect "$broker_name" 2>/dev/null \
    | jq -r --arg network "$private_network" '.[0].NetworkSettings.Networks[$network].IPAddress // empty')"
  [ -n "$broker_ip" ] || { cleanup_networks; fail_with "$CAT_BROKER_UNAVAILABLE" "could not determine broker address"; }

  # Wait for broker health
  i=0
  while [ "$i" -lt 30 ]; do
    if docker run --rm --network "$private_network" "$agent_image" \
      node -e "
        http = require('http');
        http.get('http://$broker_ip:3080/health', r => { process.exit(r.statusCode === 200 ? 0 : 1); }).on('error', () => process.exit(1));
      " >/dev/null 2>&1; then
      break
    fi
    i=$((i + 1))
    sleep 0.5
  done
  [ "$i" -lt 30 ] || { cleanup_networks; fail_with "$CAT_BROKER_UNAVAILABLE" "broker health check timed out"; }

  broker_started=true
  opencode_broker_base_url="http://$broker_ip:3080"
else
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
fi

agent_root="$(mktemp -d "$runtime_root/review-repair-agent.XXXXXX")" \
  || fail_with "$CAT_AGENT_START" "could not create isolated agent workspace"
base_dir="$agent_root/base"
workspace_dir="$agent_root/workspace"
prompt_dir="$agent_root/prompt"
prompt_file="$prompt_dir/agent-prompt.txt"
mkdir -p "$base_dir" "$workspace_dir" "$prompt_dir"

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

# When broker is enabled, do NOT set HTTP_PROXY/HTTPS_PROXY for the agent.
agent_proxy_env=()
if [ "${PROVIDER_BROKER_ENABLED:-false}" != "true" ]; then
  proxy_ip="$(docker inspect "$proxy_name" 2>/dev/null \
    | jq -r --arg network "$private_network" '.[0].NetworkSettings.Networks[$network].IPAddress // empty')"
  [ -n "$proxy_ip" ] || { cleanup_networks; fail_with "$CAT_AGENT_START" "could not determine proxy address"; }
  agent_proxy_env+=(
    --env HTTPS_PROXY="http://$proxy_ip:3128"
    --env HTTP_PROXY="http://$proxy_ip:3128"
    --env ALL_PROXY="http://$proxy_ip:3128"
    --env NO_PROXY=localhost,127.0.0.1
  )
fi

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
  "${agent_proxy_env[@]}" \
  --env OPENCODE_DISABLE_AUTOUPDATE=true \
  --env AGENT_USE_PREBUILT_PROMPT=true \
  --env PROMPT_FILE=/runtime/agent-prompt.txt \
  --env AGENT_LOG=/tmp/agent.log \
  --env GITHUB_OUTPUT=/tmp/agent-output \
  --env AGENT_MAX_RUNTIME="${AGENT_MAX_RUNTIME:-45}" \
  --env OPENROUTER_API_KEY \
  --env OPENROUTER_MODEL="${OPENROUTER_MODEL:-}" \
  --env OPENCODE_BROKER_BASE_URL="${opencode_broker_base_url:-}" \
  --env OPENCODE_CONFIG_CONTENT="${OPENCODE_CONFIG_CONTENT:-}" \
  --env PROVIDER_BROKER_ENABLED="${PROVIDER_BROKER_ENABLED:-false}" \
  --env AGENT_AUTO_INSTALL=false \
  "$agent_image" bash -ceu '
    bash /opt/review-repair-runner/run-agent.sh
  '
container_status=$?
set -e
agent_finished_epoch="$(date +%s)"
agent_runtime_seconds=$((agent_finished_epoch - agent_started_epoch))

agent_log="$agent_root/agent.log"
if [ "$container_status" -eq 0 ]; then
  docker cp "$agent_name:/tmp/agent.log" "$agent_log" >/dev/null 2>&1 || true
fi
docker rm -f "$agent_name" >/dev/null 2>&1 || true

echo "runtime_seconds=$agent_runtime_seconds" >> "${GITHUB_OUTPUT:-/dev/null}"
[ "$container_status" -eq 0 ] || exit "$container_status"

[ ! -e "$workspace_dir/.git" ] \
  || fail_with "$CAT_AGENT_START" "isolated agent created forbidden .git entry"

if [ "${PROVIDER_BROKER_ENABLED:-false}" = "true" ] && [ -n "$broker_capability" ]; then
  scan_final_workspace_for_credential "$workspace_dir" "$broker_capability"
else
  scan_final_workspace_for_credential "$workspace_dir" "${OPENROUTER_API_KEY:-}"
fi

patch_file="$agent_root/repair.patch"
set +e
(
  cd "$agent_root"
  git diff --no-index --binary --no-ext-diff --src-prefix=a/ --dst-prefix=b/ base workspace
) > "$patch_file"
diff_status=$?
set -e
chmod 400 "$patch_file"
TEST_SOURCE_DIR="$workspace_dir" \
TEST_STAGING_ROOT="$agent_root" \
TEST_IMAGE="$agent_image" \
TEST_RUNNER_UID="$runner_uid" \
TEST_RUNNER_GID="$runner_gid" \
  bash "$_REVIEW_SCRIPT_DIR/run-isolated-repository-tests.sh" || exit $?

if [ "${PROVIDER_BROKER_ENABLED:-false}" = "true" ] && [ -n "$broker_capability" ]; then
  apply_agent_patch "$target_dir" "$patch_file" "$diff_status" "$agent_log" "$broker_capability" "$prompt_file"
else
  apply_agent_patch "$target_dir" "$patch_file" "$diff_status" "$agent_log" "${OPENROUTER_API_KEY:-}" "$prompt_file"
fi

summary "| agent isolation | Docker; non-root; read-only root; broker-proxied egress; no host credentials, .git, or Docker socket |"
summary "| tests | pass (separate no-network disposable container; agent patch frozen first) |"
echo "result=pass" >> "${GITHUB_OUTPUT:-/dev/null}"