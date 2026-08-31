#!/usr/bin/env bash
set -euo pipefail

candidate_dir="${1:-}"
if [[ -z "$candidate_dir" || ! -d "$candidate_dir" ]]; then
  echo "E2E_INVALID_CANDIDATE: candidate directory is required" >&2
  exit 2
fi

for required in \
  docker/provider-broker.Dockerfile \
  docker/provider-broker-package.json \
  scripts/provider-broker.mjs
do
  path="$candidate_dir/$required"
  if [[ ! -f "$path" || -L "$path" ]]; then
    echo "E2E_INVALID_CANDIDATE: required regular file missing or symlinked: $required" >&2
    exit 2
  fi
done

command -v docker >/dev/null 2>&1 || {
  echo "E2E_DOCKER_UNAVAILABLE: docker CLI not found" >&2
  exit 2
}
docker info >/dev/null

run_key="${GITHUB_RUN_ID:-manual}-${GITHUB_RUN_ATTEMPT:-1}-$$"
safe_key="$(printf '%s' "$run_key" | tr -cd 'A-Za-z0-9_.-' | cut -c1-48)"
prefix="broker-e2e-${safe_key}"
agent_net="${prefix}-agent"
broker_net="${prefix}-broker-egress"
egress_net="${prefix}-egress"
broker_name="${prefix}-broker"
proxy_name="${prefix}-proxy"
mock_name="${prefix}-mock"
agent_name="${prefix}-agent-probe"
broker_image="${prefix}-broker-image"
proxy_image="${prefix}-proxy-image"
mock_image="${prefix}-mock-image"
tmp_root="${RUNNER_TEMP:-/tmp}/${prefix}"
mkdir -p "$tmp_root"

cleanup() {
  set +e
  docker rm -f "$agent_name" "$broker_name" "$proxy_name" "$mock_name" >/dev/null 2>&1 || true
  docker network rm "$agent_net" "$broker_net" "$egress_net" >/dev/null 2>&1 || true
  docker image rm -f "$broker_image" "$proxy_image" "$mock_image" >/dev/null 2>&1 || true
  rm -rf "$tmp_root"
}
trap cleanup EXIT INT TERM

assert_contains() {
  local haystack="$1"
  local needle="$2"
  local label="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    echo "E2E_ASSERT_FAILED: $label missing [$needle] in [$haystack]" >&2
    exit 1
  fi
  printf 'PASS: %s\n' "$label"
}

assert_not_contains() {
  local haystack="$1"
  local needle="$2"
  local label="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    echo "E2E_ASSERT_FAILED: $label unexpectedly contains [$needle] in [$haystack]" >&2
    exit 1
  fi
  printf 'PASS: %s\n' "$label"
}

wait_for_log() {
  local container="$1"
  local needle="$2"
  local attempts="${3:-40}"
  local i
  for ((i=0; i<attempts; i++)); do
    if docker logs "$container" 2>&1 | grep -Fq "$needle"; then
      return 0
    fi
    sleep 0.25
  done
  echo "E2E_TIMEOUT: $container did not log [$needle]" >&2
  docker logs "$container" >&2 || true
  return 1
}

network_members() {
  docker network inspect "$1" --format '{{range .Containers}}{{.Name}} {{end}}'
}

# Never send the candidate checkout's .git metadata to the Docker daemon.
rm -rf -- "$candidate_dir/.git"

cat >"$tmp_root/mock.mjs" <<'EOF'
import http from 'node:http';

const port = 8080;
const tempKey = 'sk-or-e2e-temporary-key';
const tempHash = 'e2e-temporary-key-hash';

const server = http.createServer(async (req, res) => {
  const url = req.url || '/';
  let body = '';
  for await (const chunk of req) body += chunk.toString();

  if (req.method === 'GET' && url === '/health') {
    res.writeHead(200, {'content-type': 'application/json'});
    res.end(JSON.stringify({status: 'ok'}));
    return;
  }
  if (req.method === 'POST' && url === '/api/v1/keys') {
    console.log('MGMT_CREATE');
    res.writeHead(201, {'content-type': 'application/json'});
    res.end(JSON.stringify({
      key: tempKey,
      data: {hash: tempHash, limit: 0.25, limit_reset: null}
    }));
    return;
  }
  if (req.method === 'DELETE' && url === `/api/v1/keys/${tempHash}`) {
    console.log('MGMT_DELETE');
    res.writeHead(200, {'content-type': 'application/json'});
    res.end(JSON.stringify({deleted: true}));
    return;
  }
  if (req.method === 'POST' && url === '/api/v1/chat/completions') {
    const auth = req.headers.authorization || '';
    if (auth !== `Bearer ${tempKey}`) {
      console.log('UPSTREAM_AUTH_BAD');
      res.writeHead(401, {'content-type': 'application/json'});
      res.end(JSON.stringify({error: 'bad auth'}));
      return;
    }
    console.log('UPSTREAM_AUTH_OK');
    res.writeHead(200, {'content-type': 'application/json'});
    res.end(JSON.stringify({
      id: 'e2e',
      choices: [{message: {role: 'assistant', content: 'local mock only'}}]
    }));
    return;
  }
  if (req.method === 'GET' && url === '/api/v1/models') {
    console.log('UPSTREAM_MODELS_OK');
    res.writeHead(200, {'content-type': 'application/json'});
    res.end(JSON.stringify({data: [{id: 'deepseek/deepseek-v4-flash'}]}));
    return;
  }

  res.writeHead(404, {'content-type': 'application/json'});
  res.end(JSON.stringify({error: 'not found'}));
});

server.listen(port, '0.0.0.0', () => console.log('MOCK_READY'));
EOF

cat >"$tmp_root/mock.Dockerfile" <<'EOF'
FROM node:22-bookworm-slim@sha256:83f487e0a63425e5b4d146fb5e5be574bcbe1b7b843d3ebafdd95eaf7767a7e5
WORKDIR /opt/e2e
COPY mock.mjs /opt/e2e/mock.mjs
USER nobody
CMD ["node", "/opt/e2e/mock.mjs"]
EOF

cat >"$tmp_root/squid.conf" <<'EOF'
http_port 3128
visible_hostname provider-broker-e2e-proxy
pid_filename /run/squid.pid
coredump_dir /var/cache/squid
acl mock_host dstdomain mock
acl mock_port port 8080
http_access allow mock_host mock_port
http_access deny all
cache deny all
access_log none
cache_log /dev/stderr
EOF

cat >"$tmp_root/proxy.Dockerfile" <<'EOF'
FROM alpine:3.21@sha256:48b0309ca019d89d40f670aa1bc06e426dc0931948452e8491e3d65087abc07d
RUN apk add --no-cache squid
COPY squid.conf /etc/squid/squid.conf
CMD ["squid", "-N", "-f", "/etc/squid/squid.conf"]
EOF

echo "Building candidate broker image without provider credentials..."
docker build --tag "$broker_image" --file "$candidate_dir/docker/provider-broker.Dockerfile" "$candidate_dir"
docker build --tag "$mock_image" --file "$tmp_root/mock.Dockerfile" "$tmp_root"
docker build --tag "$proxy_image" --file "$tmp_root/proxy.Dockerfile" "$tmp_root"

docker network create --internal "$agent_net" >/dev/null
docker network create --internal "$broker_net" >/dev/null
docker network create "$egress_net" >/dev/null

docker run -d --name "$mock_name" --network "$egress_net" --network-alias mock "$mock_image" >/dev/null
wait_for_log "$mock_name" MOCK_READY

docker run -d --name "$proxy_name" --network "$broker_net" "$proxy_image" >/dev/null
docker network connect "$egress_net" "$proxy_name"
proxy_ip="$(docker inspect -f "{{(index .NetworkSettings.Networks \"$broker_net\").IPAddress}}" "$proxy_name")"
[[ -n "$proxy_ip" ]] || {
  echo "E2E_PROXY_IP_MISSING" >&2
  exit 1
}

export BROKER_CAPABILITY="e2e-capability-sentinel-${safe_key}"
export OPENROUTER_MANAGEMENT_KEY="e2e-management-sentinel-${safe_key}"
docker run -d \
  --name "$broker_name" \
  --network "$agent_net" \
  --network-alias broker \
  -e BROKER_CAPABILITY \
  -e OPENROUTER_MANAGEMENT_KEY \
  -e BROKER_PORT=3080 \
  -e BROKER_TASK_ID=provider-broker-docker-e2e \
  -e BROKER_ALLOWED_MODEL=openrouter/deepseek/deepseek-v4-flash \
  -e BROKER_CAPABILITY_EXPIRY_MS=300000 \
  -e BROKER_MAX_REQUESTS=10 \
  -e BROKER_JOB_MAX_USD=0.25 \
  -e OPENROUTER_MANAGEMENT_API_URL=http://mock:8080/api/v1/keys \
  -e OPENROUTER_PROVIDER_API_URL=http://mock:8080 \
  -e BROKER_PROXY_URL="http://${proxy_ip}:3128" \
  "$broker_image" >/dev/null
docker network connect "$broker_net" "$broker_name"

export OPENROUTER_API_KEY="$BROKER_CAPABILITY"
docker run -d \
  --name "$agent_name" \
  --network "$agent_net" \
  --env OPENROUTER_API_KEY \
  --entrypoint node \
  "$broker_image" \
  -e 'setInterval(() => {}, 1000)' >/dev/null

wait_for_log "$broker_name" "temporary key provisioned"

agent_members="$(network_members "$agent_net")"
broker_members="$(network_members "$broker_net")"
egress_members="$(network_members "$egress_net")"

assert_contains "$agent_members" "$agent_name" "agent network contains test agent"
assert_contains "$agent_members" "$broker_name" "agent network contains broker"
assert_not_contains "$agent_members" "$proxy_name" "agent network excludes Squid"
assert_not_contains "$agent_members" "$mock_name" "agent network excludes provider mock"

assert_contains "$broker_members" "$broker_name" "broker-egress network contains broker"
assert_contains "$broker_members" "$proxy_name" "broker-egress network contains Squid"
assert_not_contains "$broker_members" "$agent_name" "broker-egress network excludes agent"
assert_not_contains "$broker_members" "$mock_name" "broker-egress network excludes provider mock"

assert_contains "$egress_members" "$proxy_name" "external egress network contains Squid"
assert_contains "$egress_members" "$mock_name" "external egress network contains provider mock"
assert_not_contains "$egress_members" "$broker_name" "external egress network excludes broker"
assert_not_contains "$egress_members" "$agent_name" "external egress network excludes agent"

broker_argv="$(docker inspect "$broker_name" --format '{{json .Path}} {{json .Args}} {{json .Config.Cmd}}')"
agent_argv="$(docker inspect "$agent_name" --format '{{json .Path}} {{json .Args}} {{json .Config.Cmd}}')"
assert_not_contains "$broker_argv" "$BROKER_CAPABILITY" "broker capability absent from Docker argv"
assert_not_contains "$broker_argv" "$OPENROUTER_MANAGEMENT_KEY" "management key absent from Docker argv"
assert_not_contains "$agent_argv" "$OPENROUTER_API_KEY" "agent capability absent from Docker argv"

agent_cap="$(docker exec "$agent_name" sh -c 'printf %s "$OPENROUTER_API_KEY"')"
[[ "$agent_cap" == "$BROKER_CAPABILITY" ]] || {
  echo "E2E_ASSERT_FAILED: agent capability env handoff mismatch" >&2
  exit 1
}
printf 'PASS: agent receives opaque broker capability via env\n'

if docker exec "$agent_name" node -e \
  'fetch("http://mock:8080/health",{signal:AbortSignal.timeout(2000)}).then(()=>process.exit(1)).catch(()=>process.exit(0))'
then
  printf 'PASS: agent direct provider-mock route denied\n'
else
  echo "E2E_ASSERT_FAILED: agent reached provider mock directly" >&2
  exit 1
fi

if docker exec "$broker_name" node -e \
  'fetch("http://mock:8080/health",{signal:AbortSignal.timeout(2000)}).then(()=>process.exit(1)).catch(()=>process.exit(0))'
then
  printf 'PASS: broker direct provider-mock route denied\n'
else
  echo "E2E_ASSERT_FAILED: broker reached provider mock directly" >&2
  exit 1
fi

if docker exec "$agent_name" node -e \
  'fetch("https://openrouter.ai",{signal:AbortSignal.timeout(2500)}).then(()=>process.exit(1)).catch(()=>process.exit(0))'
then
  printf 'PASS: agent direct external provider route denied\n'
else
  echo "E2E_ASSERT_FAILED: agent reached external provider directly" >&2
  exit 1
fi

if docker exec "$broker_name" node -e \
  'fetch("https://openrouter.ai",{signal:AbortSignal.timeout(2500)}).then(()=>process.exit(1)).catch(()=>process.exit(0))'
then
  printf 'PASS: broker direct external provider route denied\n'
else
  echo "E2E_ASSERT_FAILED: broker reached external provider directly" >&2
  exit 1
fi

docker exec -i "$agent_name" node - <<'EOF'
const body = {
  model: 'openrouter/deepseek/deepseek-v4-flash',
  messages: [{role: 'user', content: 'local docker e2e'}]
};
const res = await fetch('http://broker:3080/api/v1/chat/completions', {
  method: 'POST',
  headers: {
    authorization: `Bearer ${process.env.OPENROUTER_API_KEY}`,
    'content-type': 'application/json'
  },
  body: JSON.stringify(body),
  signal: AbortSignal.timeout(5000)
});
const text = await res.text();
if (res.status !== 200 || !text.includes('local mock only')) {
  console.error(`broker request failed status=${res.status} body=${text}`);
  process.exit(1);
}
console.log('BROKER_PROXY_REQUEST_OK');
EOF
printf 'PASS: agent -> broker -> Squid -> local provider mock\n'

wait_for_log "$mock_name" UPSTREAM_AUTH_OK
printf 'PASS: broker injected temporary upstream key\n'

docker stop --time 10 "$broker_name" >/dev/null
wait_for_log "$mock_name" MGMT_DELETE
printf 'PASS: graceful broker stop deleted temporary key\n'

mock_logs="$(docker logs "$mock_name" 2>&1)"
assert_contains "$mock_logs" MGMT_CREATE "temporary key create observed"
assert_contains "$mock_logs" MGMT_DELETE "temporary key delete observed"
assert_not_contains "$mock_logs" "$BROKER_CAPABILITY" "capability absent from mock logs"
assert_not_contains "$mock_logs" "$OPENROUTER_MANAGEMENT_KEY" "management key absent from mock logs"

echo "PROVIDER_BROKER_DOCKER_E2E=PASS"
