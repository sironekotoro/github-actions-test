#!/usr/bin/env bash
# Start a provider-broker container and output the capability token.
# The trusted outer executor calls this; the agent never receives the
# management key or temporary upstream key.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

run_key="${GITHUB_RUN_ID:-$$}"
run_key="$(printf '%s' "$run_key" | tr -cd '[:alnum:]')"
broker_image="provider-broker:$run_key"
broker_name="provider-broker-$run_key"
broker_network="broker-egress-net-$run_key"

BROKER_PORT="${BROKER_PORT:-3080}"
OPENROUTER_MODEL="${OPENROUTER_MODEL:-openrouter/deepseek/deepseek-v4-flash}"
BROKER_JOB_MAX_USD="${PROVIDER_JOB_MAX_USD:-0.25}"
BROKER_TASK_ID="${BROKER_TASK_ID:-unknown}"
BROKER_MAX_REQUESTS="${BROKER_MAX_REQUESTS:-500}"
BROKER_CAPABILITY_EXPIRY_MINUTES="${BROKER_CAPABILITY_EXPIRY_MINUTES:-60}"

command -v docker >/dev/null 2>&1 || fail_with "$CAT_AGENT_START" "docker required for broker"
docker info >/dev/null 2>&1 || fail_with "$CAT_AGENT_START" "docker daemon unavailable"
docker image inspect "$broker_image" >/dev/null 2>&1 || fail_with "$CAT_AGENT_START" "broker image unavailable"

# Generate cryptographically random opaque capability token
BROKER_CAPABILITY="$(node -e "console.log(require('crypto').randomBytes(32).toString('hex'))")"
[ -n "$BROKER_CAPABILITY" ] || fail_with "$CAT_AGENT_START" "could not generate broker capability"

OPENROUTER_MANAGEMENT_KEY="${OPENROUTER_MANAGEMENT_KEY:-}"
[ -n "$OPENROUTER_MANAGEMENT_KEY" ] || fail_with "$CAT_AGENT_START" "OPENROUTER_MANAGEMENT_KEY is required for broker"

# Cleanup function
broker_cleanup() {
  docker rm -f "$broker_name" >/dev/null 2>&1 || true
  docker network rm "$broker_network" >/dev/null 2>&1 || true
}

# Create broker egress network (not --internal, connects to squid proxy)
docker network create "$broker_network" >/dev/null \
  || fail_with "$CAT_AGENT_START" "could not create broker egress network"

# Start the broker container
docker run --detach --name "$broker_name" \
  --network "$broker_network" \
  --read-only \
  --cap-drop=ALL \
  --security-opt=no-new-privileges \
  --pids-limit=64 \
  --memory=256m \
  --tmpfs /tmp:rw,nosuid,nodev,noexec,mode=1777,size=64m \
  -e BROKER_PORT="$BROKER_PORT" \
  -e OPENROUTER_MANAGEMENT_KEY="$OPENROUTER_MANAGEMENT_KEY" \
  -e BROKER_CAPABILITY="$BROKER_CAPABILITY" \
  -e BROKER_TASK_ID="$BROKER_TASK_ID" \
  -e BROKER_ALLOWED_MODEL="$OPENROUTER_MODEL" \
  -e BROKER_JOB_MAX_USD="$BROKER_JOB_MAX_USD" \
  -e BROKER_MAX_REQUESTS="$BROKER_MAX_REQUESTS" \
  -e BROKER_CAPABILITY_EXPIRY_MS="$((BROKER_CAPABILITY_EXPIRY_MINUTES * 60 * 1000))" \
  "$broker_image" >/dev/null \
  || { broker_cleanup; fail_with "$CAT_AGENT_START" "could not start broker container"; }

broker_ip="$(docker inspect "$broker_name" 2>/dev/null \
  | jq -r '.[0].NetworkSettings.Networks["'"$broker_network"'"].IPAddress // empty')"
[ -n "$broker_ip" ] || { broker_cleanup; fail_with "$CAT_AGENT_START" "could not determine broker address"; }

# Wait for broker health
i=0
while [ "$i" -lt 30 ]; do
  if docker exec "$broker_name" node -e "
    http = require('http');
    http.get('http://127.0.0.1:$BROKER_PORT/health', r => { process.exit(r.statusCode === 200 ? 0 : 1); }).on('error', () => process.exit(1));
  " >/dev/null 2>&1; then
    break
  fi
  i=$((i + 1))
  sleep 0.5
done
[ "$i" -lt 30 ] || { broker_cleanup; fail_with "$CAT_AGENT_START" "broker health check failed"; }

echo "BROKER_CAPABILITY=$BROKER_CAPABILITY"
echo "BROKER_IP=$broker_ip"
echo "BROKER_PORT=$BROKER_PORT"
echo "BROKER_NAME=$broker_name"
echo "BROKER_NETWORK=$broker_network"