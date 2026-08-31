#!/usr/bin/env bash
set -euo pipefail

candidate_dir="${1:-}"
if [[ -z "$candidate_dir" || ! -d "$candidate_dir" ]]; then
  echo "OPENCODE_E2E_INVALID_CANDIDATE: candidate directory is required" >&2
  exit 2
fi

for required in \
  docker/review-repair-agent.Dockerfile \
  docker/provider-broker.Dockerfile \
  docker/provider-broker-package.json \
  scripts/provider-broker.mjs \
  scripts/run-agent.sh \
  scripts/agents/opencode.sh
do
  path="$candidate_dir/$required"
  if [[ ! -f "$path" || -L "$path" ]]; then
    echo "OPENCODE_E2E_INVALID_CANDIDATE: required regular file missing or symlinked: $required" >&2
    exit 2
  fi
done

command -v docker >/dev/null 2>&1 || {
  echo "OPENCODE_E2E_DOCKER_UNAVAILABLE: docker CLI not found" >&2
  exit 2
}
docker info >/dev/null

run_key="${GITHUB_RUN_ID:-manual}-${GITHUB_RUN_ATTEMPT:-1}-$$"
safe_key="$(printf '%s' "$run_key" | tr -cd 'A-Za-z0-9_.-' | cut -c1-48)"
prefix="broker-opencode-e2e-${safe_key}"
agent_net="${prefix}-agent"
mock_net="${prefix}-mock"
broker_name="${prefix}-broker"
mock_name="${prefix}-mock"
agent_image="${prefix}-agent-image"
broker_image="${prefix}-broker-image"
mock_image="${prefix}-mock-image"
tmp_root="${RUNNER_TEMP:-/tmp}/${prefix}"
mkdir -p "$tmp_root"

cleanup() {
  set +e
  docker rm -f "$broker_name" "$mock_name" >/dev/null 2>&1 || true
  docker network rm "$agent_net" "$mock_net" >/dev/null 2>&1 || true
  docker image rm -f "$agent_image" "$broker_image" "$mock_image" >/dev/null 2>&1 || true
  rm -rf "$tmp_root"
}
trap cleanup EXIT INT TERM

wait_for_log() {
  local container="$1" needle="$2" attempts="${3:-80}" i
  for ((i=0; i<attempts; i++)); do
    if docker logs "$container" 2>&1 | grep -Fq "$needle"; then
      return 0
    fi
    sleep 0.25
  done
  echo "OPENCODE_E2E_TIMEOUT: $container did not log [$needle]" >&2
  docker logs "$container" >&2 || true
  return 1
}

# The mock is deliberately OpenRouter-shaped but entirely local. It records the
# endpoint/method/body shape used by the real pinned OpenCode binary. It never
# prints credentials or request bodies.
cat >"$tmp_root/mock.mjs" <<'EOF'
import http from 'node:http';

const port = 8080;
const tempKey = 'sk-or-opencode-e2e-temporary-key';
const tempHash = 'opencode-e2e-temporary-key-hash';

function json(res, status, body) {
  const data = JSON.stringify(body);
  res.writeHead(status, {'content-type': 'application/json', 'content-length': Buffer.byteLength(data)});
  res.end(data);
}

const server = http.createServer(async (req, res) => {
  const url = req.url || '/';
  let raw = '';
  for await (const chunk of req) raw += chunk.toString();

  if (req.method === 'GET' && url === '/health') {
    json(res, 200, {status: 'ok'});
    return;
  }
  if (req.method === 'POST' && url === '/api/v1/keys') {
    console.log('MGMT_CREATE');
    json(res, 201, {key: tempKey, data: {hash: tempHash, limit: 0.25, limit_reset: null}});
    return;
  }
  if (req.method === 'DELETE' && url === `/api/v1/keys/${tempHash}`) {
    console.log('MGMT_DELETE');
    json(res, 200, {deleted: true});
    return;
  }

  if (req.headers.authorization !== `Bearer ${tempKey}`) {
    console.log(`REQ ${req.method} ${url} AUTH_BAD`);
    json(res, 401, {error: {message: 'bad auth'}});
    return;
  }

  console.log(`REQ ${req.method} ${url}`);

  if (req.method === 'GET' && url === '/api/v1/models') {
    json(res, 200, {data: [{id: 'deepseek/deepseek-v4-flash', name: 'E2E model'}]});
    return;
  }
  if (req.method === 'GET' && url.startsWith('/api/v1/models/')) {
    json(res, 200, {id: 'deepseek/deepseek-v4-flash', name: 'E2E model'});
    return;
  }
  if (req.method === 'POST' && url === '/api/v1/chat/completions') {
    let body;
    try {
      body = JSON.parse(raw || '{}');
    } catch {
      json(res, 400, {error: {message: 'invalid json'}});
      return;
    }
    console.log(`CHAT model=${String(body.model || '')} stream=${body.stream === true ? 'true' : 'false'}`);
    if (body.stream === true) {
      res.writeHead(200, {'content-type': 'text/event-stream', 'cache-control': 'no-cache', connection: 'keep-alive'});
      const first = {
        id: 'chatcmpl-opencode-e2e', object: 'chat.completion.chunk', created: 1,
        model: 'deepseek/deepseek-v4-flash',
        choices: [{index: 0, delta: {role: 'assistant', content: 'OPENCODE_BROKER_OK'}, finish_reason: null}]
      };
      const last = {
        id: 'chatcmpl-opencode-e2e', object: 'chat.completion.chunk', created: 1,
        model: 'deepseek/deepseek-v4-flash',
        choices: [{index: 0, delta: {}, finish_reason: 'stop'}]
      };
      res.write(`data: ${JSON.stringify(first)}\n\n`);
      res.write(`data: ${JSON.stringify(last)}\n\n`);
      res.end('data: [DONE]\n\n');
      return;
    }
    json(res, 200, {
      id: 'chatcmpl-opencode-e2e', object: 'chat.completion', created: 1,
      model: 'deepseek/deepseek-v4-flash',
      choices: [{index: 0, message: {role: 'assistant', content: 'OPENCODE_BROKER_OK'}, finish_reason: 'stop'}]
    });
    return;
  }

  json(res, 404, {error: {message: `unhandled ${req.method} ${url}`}});
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

cat >"$tmp_root/prompt.txt" <<'EOF'
Reply with exactly OPENCODE_BROKER_OK. Do not use tools and do not modify files.
EOF
chmod 644 "$tmp_root/prompt.txt"

# Define the test model explicitly so the contract test does not depend on an
# external models.dev lookup. The candidate adapter must add the broker baseURL.
opencode_config='{"provider":{"openrouter":{"models":{"deepseek/deepseek-v4-flash":{"name":"Provider Broker Contract E2E","limit":{"context":131072,"output":8192}}}}}}'

# Build phase may access public package registries. No provider/API credentials
# exist in this job. All runtime networks created below are --internal.
echo 'Building candidate agent and broker images...'
docker build --tag "$agent_image" --file "$candidate_dir/docker/review-repair-agent.Dockerfile" "$candidate_dir"
docker build --tag "$broker_image" --file "$candidate_dir/docker/provider-broker.Dockerfile" "$candidate_dir"
docker build --tag "$mock_image" --file "$tmp_root/mock.Dockerfile" "$tmp_root"

version="$(docker run --rm --network none --entrypoint opencode "$agent_image" --version 2>&1 | head -1 | tr -d '\r')"
if [[ "$version" != *'1.18.16'* ]]; then
  echo "OPENCODE_E2E_VERSION_MISMATCH: expected 1.18.16, got [$version]" >&2
  exit 1
fi
echo "PASS: pinned OpenCode version is $version"

docker network create --internal "$agent_net" >/dev/null
docker network create --internal "$mock_net" >/dev/null

docker run -d --name "$mock_name" --network "$mock_net" --network-alias mock "$mock_image" >/dev/null
wait_for_log "$mock_name" MOCK_READY

export BROKER_CAPABILITY="opencode-e2e-capability-${safe_key}"
export OPENROUTER_MANAGEMENT_KEY="opencode-e2e-management-${safe_key}"
# Start the broker on the mock-side internal network so provisioning can reach
# the local Management API immediately. Only after startup do we attach the
# separate agent-side network with the broker alias used by OpenCode.
docker run -d \
  --name "$broker_name" \
  --network "$mock_net" \
  --read-only \
  --cap-drop=ALL \
  --security-opt=no-new-privileges \
  --pids-limit=64 \
  --memory=256m \
  --tmpfs /tmp:rw,nosuid,nodev,noexec,mode=1777,size=64m \
  -e BROKER_PORT=3080 \
  -e OPENROUTER_MANAGEMENT_KEY \
  -e BROKER_CAPABILITY \
  -e BROKER_TASK_ID=provider-broker-opencode-contract-e2e \
  -e BROKER_ALLOWED_MODEL=openrouter/deepseek/deepseek-v4-flash \
  -e BROKER_CAPABILITY_EXPIRY_MS=600000 \
  -e BROKER_MAX_REQUESTS=20 \
  -e BROKER_JOB_MAX_USD=0.25 \
  -e OPENROUTER_MANAGEMENT_API_URL=http://mock:8080/api/v1/keys \
  -e OPENROUTER_PROVIDER_API_URL=http://mock:8080 \
  "$broker_image" >/dev/null

docker network connect --alias broker "$agent_net" "$broker_name"
wait_for_log "$broker_name" 'temporary key provisioned'

# Run the real candidate adapter through run-agent.sh, not a handcrafted HTTP
# client. There is no external route on agent_net or mock_net.
set +e
docker run --rm --init \
  --network "$agent_net" \
  --read-only \
  --user 65534:65534 \
  --cap-drop=ALL \
  --security-opt=no-new-privileges \
  --pids-limit=256 \
  --memory=2g \
  --tmpfs /tmp:rw,nosuid,nodev,noexec,mode=1777,size=256m \
  --tmpfs /home/agent:rw,nosuid,nodev,noexec,mode=1777,size=256m \
  --tmpfs /workspace:rw,nosuid,nodev,mode=1777,size=64m \
  --mount "type=bind,src=$tmp_root/prompt.txt,dst=/runtime/prompt.txt,readonly" \
  --workdir /workspace \
  --env HOME=/home/agent \
  --env XDG_CONFIG_HOME=/home/agent/.config \
  --env XDG_CACHE_HOME=/home/agent/.cache \
  --env RUNNER_TEMP=/tmp \
  --env TASK_FILE=/tmp/nonexistent-task.json \
  --env PROMPT_FILE=/runtime/prompt.txt \
  --env AGENT_LOG=/tmp/agent.log \
  --env GITHUB_OUTPUT=/tmp/agent-output \
  --env GITHUB_STEP_SUMMARY=/tmp/agent-summary \
  --env AGENT=opencode \
  --env AGENT_USE_PREBUILT_PROMPT=true \
  --env AGENT_AUTO_INSTALL=false \
  --env AGENT_MAX_ATTEMPTS=1 \
  --env AGENT_MAX_RUNTIME=2 \
  --env PROVIDER_BROKER_ENABLED=true \
  --env AGENT_CREDENTIAL_PROFILE=openrouter-broker \
  --env OPENROUTER_API_KEY="$BROKER_CAPABILITY" \
  --env OPENROUTER_MODEL=openrouter/deepseek/deepseek-v4-flash \
  --env OPENCODE_BROKER_BASE_URL=http://broker:3080 \
  --env OPENCODE_CONFIG_CONTENT="$opencode_config" \
  "$agent_image" bash /opt/review-repair-runner/run-agent.sh \
  >"$tmp_root/opencode.out" 2>"$tmp_root/opencode.err"
agent_status=$?
set -e

if [[ "$agent_status" -ne 0 ]]; then
  echo "OPENCODE_E2E_AGENT_FAILED: exit=$agent_status" >&2
  sed -n '1,160p' "$tmp_root/opencode.out" >&2 || true
  sed -n '1,200p' "$tmp_root/opencode.err" >&2 || true
  echo '--- broker logs ---' >&2
  docker logs "$broker_name" >&2 || true
  echo '--- local mock request log ---' >&2
  docker logs "$mock_name" >&2 || true
  exit 1
fi

echo 'PASS: pinned OpenCode completed through candidate broker adapter'

mock_logs="$(docker logs "$mock_name" 2>&1)"
if [[ "$mock_logs" != *'CHAT model=deepseek/deepseek-v4-flash'* ]]; then
  echo 'OPENCODE_E2E_ASSERT_FAILED: local mock did not receive expected chat request' >&2
  printf '%s\n' "$mock_logs" >&2
  exit 1
fi
echo 'PASS: local mock received OpenCode chat request with normalized model'

# Emit only endpoint/method evidence, never request bodies or credentials.
echo 'Observed pinned OpenCode provider requests:'
printf '%s\n' "$mock_logs" | grep '^REQ ' || true

if printf '%s\n' "$mock_logs" | grep -q 'AUTH_BAD'; then
  echo 'OPENCODE_E2E_ASSERT_FAILED: broker did not inject temporary upstream key' >&2
  exit 1
fi
echo 'PASS: broker injected temporary upstream key for real OpenCode request'

docker stop --time 10 "$broker_name" >/dev/null
wait_for_log "$mock_name" MGMT_DELETE
echo 'PASS: graceful broker stop deleted temporary key'

mock_logs="$(docker logs "$mock_name" 2>&1)"
[[ "$mock_logs" == *MGMT_CREATE* && "$mock_logs" == *MGMT_DELETE* ]] || {
  echo 'OPENCODE_E2E_ASSERT_FAILED: temporary key lifecycle incomplete' >&2
  exit 1
}
[[ "$mock_logs" != *"$BROKER_CAPABILITY"* ]] || {
  echo 'OPENCODE_E2E_ASSERT_FAILED: capability leaked to mock log' >&2
  exit 1
}
[[ "$mock_logs" != *"$OPENROUTER_MANAGEMENT_KEY"* ]] || {
  echo 'OPENCODE_E2E_ASSERT_FAILED: management key leaked to mock log' >&2
  exit 1
}

echo 'PROVIDER_BROKER_OPENCODE_E2E=PASS'
