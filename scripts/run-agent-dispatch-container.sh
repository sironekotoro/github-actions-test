#!/usr/bin/env bash
# Execute ordinary Agent Dispatch work only in an ephemeral, capability-free
# container. The trusted outer executor receives back only a checked patch.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_CONTAINER_SCRIPT_DIR="$SCRIPT_DIR"
source "$_CONTAINER_SCRIPT_DIR/lib/common.sh"
source "$_CONTAINER_SCRIPT_DIR/lib/credentials.sh"
source "$_CONTAINER_SCRIPT_DIR/lib/review-repair-cleanup.sh"

target_dir="${TARGET_DIR:-$PWD}"
task_file="${TASK_FILE:-${RUNNER_TEMP:-/tmp}/task.json}"
runtime_root="${RUNNER_TEMP:-/tmp}"
agent_root=""
run_key="${GITHUB_RUN_ID:-$$}"
run_key="$(printf '%s' "$run_key" | tr -cd '[:alnum:]')"
agent_image="agent-dispatch-agent:$run_key"
egress_image="agent-dispatch-egress:$run_key"
broker_image="provider-broker:$run_key"

[ -d "$target_dir/.git" ] || fail_with "$CAT_AGENT_START" "validated target checkout is missing .git"
[ -f "$task_file" ] || fail_with "$CAT_AGENT_START" "validated task is missing"
[ -n "$run_key" ] || fail_with "$CAT_AGENT_START" "agent dispatch run identifier is invalid"

# Resolve and validate the selected profile before creating any container or
# starting the agent. The outer shell receives at most one generic direct
# credential value. Broker profiles generate a fresh opaque capability here.
agent="$(jq -r '.agent // "opencode"' "$task_file")"
if ! profile="$(resolve_credential_profile "$agent")"; then
  exit 1
fi
assert_execution_profile_supported "$profile"
cred_var="$(profile_env_var "$profile")"
agent_credential=""
broker_capability=""
broker_profile=false
case "$profile" in
  openrouter-broker|openai-broker|anthropic-broker) broker_profile=true ;;
esac

if [ -n "$cred_var" ]; then
  if [ "${PROVIDER_BROKER_ENABLED:-false}" = "true" ] && [ "$broker_profile" = true ]; then
    generate_broker_capability broker_capability
    [ -n "$broker_capability" ] || fail_with "$CAT_BROKER_AUTH_FAILED" "broker capability generation failed"
  else
    if [ -n "${AGENT_CREDENTIAL_VALUE:-}" ]; then
      agent_credential="$AGENT_CREDENTIAL_VALUE"
    else
      agent_credential="${!cred_var:-}"
    fi
    assert_credential_available "$profile" "$agent_credential"
  fi
fi

command -v docker >/dev/null 2>&1 || fail_with "$CAT_AGENT_START" "docker is required for isolated Agent Dispatch"
docker info >/dev/null 2>&1 || fail_with "$CAT_AGENT_START" "docker daemon is unavailable for isolated Agent Dispatch"
docker image inspect "$agent_image" >/dev/null 2>&1 || fail_with "$CAT_AGENT_START" "trusted Agent Dispatch image is unavailable"
docker image inspect "$egress_image" >/dev/null 2>&1 || fail_with "$CAT_AGENT_START" "trusted Agent Dispatch egress image is unavailable"

if [ "${PROVIDER_BROKER_ENABLED:-false}" = "true" ] && [ "$broker_profile" = true ]; then
  docker image inspect "$broker_image" >/dev/null 2>&1 || fail_with "$CAT_BROKER_UNAVAILABLE" "provider broker image is unavailable"
fi

runner_uid="$(id -u)"
runner_gid="$(id -g)"
[ "$runner_uid" -ne 0 ] || fail_with "$CAT_AGENT_START" "Agent Dispatch requires a non-root self-hosted runner user"

private_network="agent-dispatch-private-$run_key"
egress_network="agent-dispatch-egress-net-$run_key"
broker_egress_network="agent-dispatch-broker-egress-$run_key"
proxy_name="agent-dispatch-proxy-$run_key"
broker_name="agent-dispatch-broker-$run_key"
broker_started=false
cleanup() {
  local status="$?"
  if [ "$broker_started" = true ]; then
    docker stop --time 10 "$broker_name" >/dev/null 2>&1 || true
    docker rm -f "$broker_name" >/dev/null 2>&1 || true
  fi
  docker rm -f "$proxy_name" >/dev/null 2>&1 || true
  docker network rm "$broker_egress_network" >/dev/null 2>&1 || true
  docker network rm "$private_network" >/dev/null 2>&1 || true
  docker network rm "$egress_network" >/dev/null 2>&1 || true
  cleanup_review_repair_staging "$agent_root" "$runtime_root" || true
  return "$status"
}
trap cleanup EXIT

# The trusted outer wrapper resolves the exact model before broker startup.
# This same value is passed into the isolated CLI so provider-side exact-model
# policy and the actual Codex/OpenCode request cannot diverge.
openrouter_model="${OPENROUTER_MODEL:-openrouter/deepseek/deepseek-v4-flash}"
codex_model="$(jq -r '.requested_model // empty' "$task_file")"
[ -n "$codex_model" ] || codex_model="${CODEX_MODEL:-gpt-5.6-sol}"
claude_model="$(jq -r '.requested_model // empty' "$task_file")"
[ -n "$claude_model" ] || claude_model="${CLAUDE_MODEL:-claude-sonnet-5}"

opencode_broker_base_url=""
codex_broker_base_url=""
anthropic_broker_base_url=""
if [ "${PROVIDER_BROKER_ENABLED:-false}" = "true" ] && [ "$broker_profile" = true ]; then
  broker_task_id="$(jq -r '.task_id // empty' "$task_file")"
  [ -n "$broker_task_id" ] || fail_with "$CAT_BROKER_UNAVAILABLE" "validated task id is missing for broker"
  agent_runtime_minutes="${AGENT_MAX_RUNTIME:-30}"
  case "$agent_runtime_minutes" in
    ''|*[!0-9]*) fail_with "$CAT_BROKER_UNAVAILABLE" "AGENT_MAX_RUNTIME must be a positive integer" ;;
  esac
  [ "$agent_runtime_minutes" -gt 0 ] || fail_with "$CAT_BROKER_UNAVAILABLE" "AGENT_MAX_RUNTIME must be a positive integer"
  broker_capability_expiry_ms="$(((agent_runtime_minutes + 5) * 60 * 1000))"

  broker_provider=""
  broker_allowed_model=""
  broker_secret_args=()
  case "$profile" in
    openrouter-broker)
      [ -n "${OPENROUTER_MANAGEMENT_KEY:-}" ] || fail_with "$CAT_BROKER_UNAVAILABLE" "OPENROUTER_MANAGEMENT_KEY required for OpenRouter broker"
      broker_provider="openrouter"
      broker_allowed_model="$openrouter_model"
      broker_secret_args+=(--env "OPENROUTER_MANAGEMENT_KEY")
      ;;
    openai-broker)
      [ -n "${OPENAI_ADMIN_KEY:-}" ] || fail_with "$CAT_BROKER_UNAVAILABLE" "OPENAI_ADMIN_KEY required for OpenAI broker"
      broker_provider="openai"
      broker_allowed_model="$codex_model"
      broker_secret_args+=(--env "OPENAI_ADMIN_KEY")
      ;;
    anthropic-broker)
      [ -n "${ANTHROPIC_API_KEY:-}" ] || fail_with "$CAT_BROKER_UNAVAILABLE" "ANTHROPIC_API_KEY required for Anthropic broker"
      broker_provider="anthropic"
      broker_allowed_model="$claude_model"
      broker_secret_args+=(--env "ANTHROPIC_API_KEY")
      ;;
    *)
      fail_with "$CAT_BROKER_UNAVAILABLE" "unsupported broker profile=$profile"
      ;;
  esac

  setup_broker_network_topology "$private_network" "$egress_network" "$broker_egress_network" \
    "$proxy_name" "$egress_image" "$run_key"

  export BROKER_CAPABILITY="$broker_capability"

  docker run --detach --name "$broker_name" \
    --network "$private_network" \
    --read-only \
    --cap-drop=ALL \
    --security-opt=no-new-privileges \
    --pids-limit=64 \
    --memory=256m \
    --tmpfs /tmp:rw,nosuid,nodev,noexec,mode=1777,size=64m \
    -e BROKER_PROVIDER="$broker_provider" \
    -e BROKER_PORT=3080 \
    "${broker_secret_args[@]}" \
    -e BROKER_CAPABILITY \
    -e BROKER_TASK_ID="$broker_task_id" \
    -e BROKER_ALLOWED_MODEL="$broker_allowed_model" \
    -e BROKER_JOB_MAX_USD="${PROVIDER_JOB_MAX_USD:-0.25}" \
    -e BROKER_ANTHROPIC_SPEND_GUARD_ENABLED="$([ "$profile" = "anthropic-broker" ] && printf true || printf false)" \
    -e BROKER_ANTHROPIC_LIVE_ALLOWED="${ANTHROPIC_BROKER_LIVE_ALLOWED:-false}" \
    -e BROKER_MAX_REQUESTS="${BROKER_MAX_REQUESTS:-500}" \
    -e BROKER_CAPABILITY_EXPIRY_MS="$broker_capability_expiry_ms" \
    -e BROKER_PROXY_URL="http://${PROXY_BROKER_IP}:3128" \
    -e NO_PROXY=localhost,127.0.0.1 \
    "$broker_image" >/dev/null \
    || { cleanup; fail_with "$CAT_BROKER_UNAVAILABLE" "could not start broker container"; }
  broker_started=true

  docker network connect "$broker_egress_network" "$broker_name" \
    || { cleanup; fail_with "$CAT_BROKER_UNAVAILABLE" "could not connect broker to egress network"; }

  broker_ip="$(docker inspect "$broker_name" 2>/dev/null \
    | jq -r --arg network "$private_network" '.[0].NetworkSettings.Networks[$network].IPAddress // empty')"
  [ -n "$broker_ip" ] || { cleanup; fail_with "$CAT_BROKER_UNAVAILABLE" "could not determine broker address"; }

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
  [ "$i" -lt 30 ] || { cleanup; fail_with "$CAT_BROKER_UNAVAILABLE" "broker health check timed out"; }

  case "$profile" in
    openrouter-broker) opencode_broker_base_url="http://$broker_ip:3080" ;;
    openai-broker) codex_broker_base_url="http://$broker_ip:3080" ;;
    anthropic-broker) anthropic_broker_base_url="http://$broker_ip:3080" ;;
  esac
else
  setup_standard_proxy "$private_network" "$egress_network" "$proxy_name" "$egress_image"

  proxy_ip="$(docker inspect "$proxy_name" 2>/dev/null \
    | jq -r --arg network "$private_network" '.[0].NetworkSettings.Networks[$network].IPAddress // empty')"
  [ -n "$proxy_ip" ] || fail_with "$CAT_AGENT_START" "could not determine restricted egress proxy address"
fi

agent_root="$(mktemp -d "$runtime_root/agent-dispatch-agent.XXXXXX")" \
  || fail_with "$CAT_AGENT_START" "could not create isolated agent workspace"
base_dir="$agent_root/base"
workspace_dir="$agent_root/workspace"
prompt_dir="$agent_root/prompt"
prompt_file="$prompt_dir/agent-prompt.txt"
mkdir -p "$base_dir" "$workspace_dir" "$prompt_dir"

# The untrusted agent sees only a disposable .git-free source copy. The base
# copy is mounted read-only as /baseline so the agent can validate whitespace
# without receiving repository metadata. The same base is later used by the
# trusted outer executor to construct the checked import patch.
tar -C "$target_dir" --exclude=.git -cf - . | tar -C "$base_dir" -xf - \
  || fail_with "$CAT_AGENT_START" "could not stage target for isolated agent"
tar -C "$base_dir" -cf - . | tar -C "$workspace_dir" -xf - \
  || fail_with "$CAT_AGENT_START" "could not create isolated agent workspace"
AGENT_ISOLATED_WORKSPACE=true TASK_FILE="$task_file" PROMPT_FILE="$prompt_file" \
  bash "$_CONTAINER_SCRIPT_DIR/build-agent-prompt.sh" \
  || fail_with "$CAT_AGENT_START" "could not prepare isolated agent prompt"
chmod 700 "$agent_root" "$base_dir" "$workspace_dir" "$prompt_dir"
chmod 400 "$prompt_file"

agent_started_epoch="$(date +%s)"
credential_args=()
if [ -n "$cred_var" ]; then
  if [ "${PROVIDER_BROKER_ENABLED:-false}" = "true" ] && [ "$broker_profile" = true ]; then
    case "$profile" in
      openrouter-broker)
        export OPENROUTER_API_KEY="$broker_capability"
        credential_args+=(--env OPENROUTER_API_KEY)
        ;;
      openai-broker|anthropic-broker)
        export AGENT_CREDENTIAL_VALUE="$broker_capability"
        credential_args+=(--env AGENT_CREDENTIAL_VALUE)
        ;;
    esac
  else
    AGENT_CREDENTIAL_VALUE="$agent_credential"
    export AGENT_CREDENTIAL_VALUE
    credential_args+=(--env AGENT_CREDENTIAL_VALUE)
  fi
fi

# Brokered agents receive no provider-capable proxy route. They can reach only
# the broker on the internal network; the broker owns the restricted egress.
# Keep one harmless NO_PROXY entry so macOS Bash 3.2 + nounset never expands an
# empty array in broker mode. Provider-capable proxy variables remain absent.
agent_proxy_env=(--env NO_PROXY=localhost,127.0.0.1)
if [ "$broker_profile" != true ]; then
  agent_proxy_env+=(
    --env HTTPS_PROXY="http://$proxy_ip:3128"
    --env HTTP_PROXY="http://$proxy_ip:3128"
    --env ALL_PROXY="http://$proxy_ip:3128"
  )
fi

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
  --env RUNNER_TEMP=/tmp \
  --env AGENT_LOG=/tmp/agent.log \
  --env GITHUB_OUTPUT=/tmp/agent-output \
  --env AGENT="$agent" \
  --env AGENT_CREDENTIAL_PROFILE="$profile" \
  --env AGENT_MAX_RUNTIME="${AGENT_MAX_RUNTIME:-30}" \
  --env OPENROUTER_MODEL="${OPENROUTER_MODEL:-}" \
  --env CODEX_MODEL="$codex_model" \
  --env CLAUDE_MODEL="$claude_model" \
  --env OPENCODE_BROKER_BASE_URL="${opencode_broker_base_url:-}" \
  --env CODEX_BROKER_BASE_URL="${codex_broker_base_url:-}" \
  --env ANTHROPIC_BROKER_BASE_URL="${anthropic_broker_base_url:-}" \
  --env OPENCODE_CONFIG_CONTENT="${OPENCODE_CONFIG_CONTENT:-}" \
  --env PROVIDER_BROKER_ENABLED="${PROVIDER_BROKER_ENABLED:-false}" \
  --env AGENT_AUTO_INSTALL=false \
  "${credential_args[@]}" \
  "$agent_image" bash -ceu '
    if [ -n "${CODEX_BROKER_BASE_URL:-}" ]; then
      mkdir -p "$HOME/.codex"
      printf "openai_base_url = \"%s/v1\"\n" "$CODEX_BROKER_BASE_URL" > "$HOME/.codex/config.toml"
      chmod 600 "$HOME/.codex/config.toml"
    fi
    bash /opt/review-repair-runner/run-agent.sh
  '
container_status=$?
set -e
agent_finished_epoch="$(date +%s)"
agent_runtime_seconds=$((agent_finished_epoch - agent_started_epoch))

echo "runtime_seconds=$agent_runtime_seconds" >> "${GITHUB_OUTPUT:-/dev/null}"
[ "$container_status" -eq 0 ] || exit "$container_status"

# Some coding runtimes initialize a local repository for their own tooling.
if [ -e "$workspace_dir/.git" ]; then
  rm -rf -- "$workspace_dir/.git" \
    || fail_with "$CAT_AGENT_START" "could not discard isolated agent .git entry"
fi

if [ "$broker_profile" = true ]; then
  scan_final_workspace_for_credential "$workspace_dir" "$broker_capability"
else
  scan_final_workspace_for_credential "$workspace_dir" "$agent_credential"
fi

patch_file="$agent_root/agent.patch"
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
  bash "$_CONTAINER_SCRIPT_DIR/run-isolated-repository-tests.sh" || exit $?

apply_agent_patch "$target_dir" "$patch_file" "$diff_status"

if [ "$broker_profile" = true ]; then
  summary "| agent isolation | Docker; non-root; read-only root; broker-proxied egress; capability-only credential; no direct provider route; no host credentials, .git, or Docker socket |"
else
  summary "| agent isolation | Docker; non-root; read-only root; provider-allowlisted egress; selected credential only; read-only .git-free baseline; no host credentials, .git, or Docker socket |"
fi
summary "| tests | pass (separate no-network disposable container; agent patch frozen first) |"
echo "result=pass" >> "${GITHUB_OUTPUT:-/dev/null}"
