#!/usr/bin/env bash
# Execute ordinary Agent Dispatch work only in an ephemeral, capability-free
# container. The trusted outer executor receives back only a checked patch.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/review-repair-cleanup.sh"

target_dir="${TARGET_DIR:-$PWD}"
task_file="${TASK_FILE:-${RUNNER_TEMP:-/tmp}/task.json}"
runtime_root="${RUNNER_TEMP:-/tmp}"
agent_root=""
run_key="${GITHUB_RUN_ID:-$$}"
run_key="$(printf '%s' "$run_key" | tr -cd '[:alnum:]')"
agent_image="agent-dispatch-agent:$run_key"
egress_image="agent-dispatch-egress:$run_key"

[ -d "$target_dir/.git" ] || fail_with "$CAT_AGENT_START" "validated target checkout is missing .git"
[ -f "$task_file" ] || fail_with "$CAT_AGENT_START" "validated task is missing"
[ -n "$run_key" ] || fail_with "$CAT_AGENT_START" "agent dispatch run identifier is invalid"
command -v docker >/dev/null 2>&1 || fail_with "$CAT_AGENT_START" "docker is required for isolated Agent Dispatch"
docker info >/dev/null 2>&1 || fail_with "$CAT_AGENT_START" "docker daemon is unavailable for isolated Agent Dispatch"
docker image inspect "$agent_image" >/dev/null 2>&1 || fail_with "$CAT_AGENT_START" "trusted Agent Dispatch image is unavailable"
docker image inspect "$egress_image" >/dev/null 2>&1 || fail_with "$CAT_AGENT_START" "trusted Agent Dispatch egress image is unavailable"

runner_uid="$(id -u)"
runner_gid="$(id -g)"
[ "$runner_uid" -ne 0 ] || fail_with "$CAT_AGENT_START" "Agent Dispatch requires a non-root self-hosted runner user"

private_network="agent-dispatch-private-$run_key"
egress_network="agent-dispatch-egress-net-$run_key"
proxy_name="agent-dispatch-proxy-$run_key"
cleanup() {
  local status="$?"
  docker rm -f "$proxy_name" >/dev/null 2>&1 || true
  docker network rm "$private_network" >/dev/null 2>&1 || true
  docker network rm "$egress_network" >/dev/null 2>&1 || true
  cleanup_review_repair_staging "$agent_root" "$runtime_root" || true
  return "$status"
}
trap cleanup EXIT

docker network create --internal "$private_network" >/dev/null \
  || fail_with "$CAT_AGENT_START" "could not create isolated Agent Dispatch network"
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

agent_root="$(mktemp -d "$runtime_root/agent-dispatch-agent.XXXXXX")" \
  || fail_with "$CAT_AGENT_START" "could not create isolated agent workspace"
base_dir="$agent_root/base"
workspace_dir="$agent_root/workspace"
prompt_dir="$agent_root/prompt"
prompt_file="$prompt_dir/agent-prompt.txt"
mkdir -p "$base_dir" "$workspace_dir" "$prompt_dir"

# The untrusted agent sees only a disposable .git-free source copy. The base
# copy remains outside the container solely to construct a checked patch.
tar -C "$target_dir" --exclude=.git -cf - . | tar -C "$base_dir" -xf - \
  || fail_with "$CAT_AGENT_START" "could not stage target for isolated agent"
tar -C "$base_dir" -cf - . | tar -C "$workspace_dir" -xf - \
  || fail_with "$CAT_AGENT_START" "could not create isolated agent workspace"
TASK_FILE="$task_file" PROMPT_FILE="$prompt_file" \
  bash "$SCRIPT_DIR/build-agent-prompt.sh" \
  || fail_with "$CAT_AGENT_START" "could not prepare isolated agent prompt"
chmod 700 "$agent_root" "$base_dir" "$workspace_dir" "$prompt_dir"
chmod 400 "$prompt_file"

# source credentials and resolve the selected agent's credential
source "$SCRIPT_DIR/lib/credentials.sh"
agent_credential=""
agent="$(jq -r '.agent // "opencode"' "$task_file")"
profile="$(resolve_credential_profile "$agent")"
cred_var="$(profile_env_var "$profile")"
if [ -n "$cred_var" ]; then
  agent_credential="${!cred_var:-}"
  credential_env="--env ${cred_var}=${agent_credential}"
else
  credential_env=""
fi

agent_started_epoch="$(date +%s)"
set +e
docker run --rm --init \
  --network "$private_network" \
  --dns 127.0.0.1 \
  --read-only \
  --user "$runner_uid:$runner_gid" \
  --cap-drop=ALL \
  --security-opt=no-new-privileges \
  --pids-limit="${AGENT_DISPATCH_CONTAINER_PIDS_LIMIT:-512}" \
  --memory="${AGENT_DISPATCH_CONTAINER_MEMORY:-4g}" \
  --mount "type=bind,src=$workspace_dir,dst=/workspace" \
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
  --env RUNNER_TEMP=/tmp \
  --env AGENT_LOG=/tmp/agent.log \
  --env GITHUB_OUTPUT=/tmp/agent-output \
  --env AGENT_MAX_RUNTIME="${AGENT_MAX_RUNTIME:-30}" \
  --env OPENROUTER_MODEL="${OPENROUTER_MODEL:-}" \
  --env AGENT_AUTO_INSTALL=false \
  $credential_env \
  "$agent_image" bash -ceu '
    bash /opt/review-repair-runner/run-agent.sh
    # Repository tests are untrusted code and do not inherit the API key.
    unset OPENROUTER_API_KEY
    unset OPENAI_API_KEY
    unset ANTHROPIC_API_KEY
    if [ -f package.json ]; then
      npm test
    fi
  '
container_status=$?
set -e
agent_finished_epoch="$(date +%s)"
agent_runtime_seconds=$((agent_finished_epoch - agent_started_epoch))

echo "runtime_seconds=$agent_runtime_seconds" >> "${GITHUB_OUTPUT:-/dev/null}"
[ "$container_status" -eq 0 ] || exit "$container_status"

# Some coding runtimes initialize a local repository for their own tooling.
# It is entirely inside the disposable workspace, and must never influence the
# trusted outer Git state, hooks, or patch. Remove it before calculating the
# filesystem-only patch; no agent-owned Git metadata can cross this boundary.
if [ -e "$workspace_dir/.git" ]; then
  rm -rf -- "$workspace_dir/.git" \
    || fail_with "$CAT_AGENT_START" "could not discard isolated agent .git entry"
fi

patch_file="$agent_root/agent.patch"
set +e
(
  cd "$agent_root"
  git diff --no-index --binary --no-ext-diff --src-prefix=a/ --dst-prefix=b/ base workspace
) > "$patch_file"
diff_status=$?
set -e
[ "$diff_status" -eq 0 ] || [ "$diff_status" -eq 1 ] \
  || fail_with "$CAT_AGENT_START" "could not create agent patch from isolated workspace"
git -C "$target_dir" apply --check --whitespace=error -p2 "$patch_file" \
  || fail_with "$CAT_AGENT_PATCH_INVALID" "isolated agent patch failed validation"
git -C "$target_dir" apply --whitespace=error -p2 "$patch_file" \
  || fail_with "$CAT_AGENT_PATCH_INVALID" "could not import isolated agent patch"

summary "| agent isolation | Docker; non-root; read-only root; OpenRouter-only egress; no host credentials, .git, or Docker socket |"
summary "| tests | pass (isolated agent container) |"
echo "result=pass" >> "${GITHUB_OUTPUT:-/dev/null}"
