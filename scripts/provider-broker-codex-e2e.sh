#!/usr/bin/env bash
set -euo pipefail

candidate_dir="${1:-}"
if [[ -z "$candidate_dir" || ! -d "$candidate_dir" ]]; then
  echo "CODEX_BROKER_E2E_INVALID_CANDIDATE: candidate directory is required" >&2
  exit 2
fi

for required in \
  docker/review-repair-agent.Dockerfile \
  docker/provider-broker.Dockerfile \
  scripts/provider-broker.mjs \
  scripts/run-agent.sh \
  scripts/agents/codex.sh
do
  path="$candidate_dir/$required"
  if [[ ! -f "$path" || -L "$path" ]]; then
    echo "CODEX_BROKER_E2E_INVALID_CANDIDATE: required regular file missing or symlinked: $required" >&2
    exit 2
  fi
done

command -v docker >/dev/null 2>&1 || {
  echo "CODEX_BROKER_E2E_DOCKER_UNAVAILABLE: docker CLI not found" >&2
  exit 2
}
docker info >/dev/null

run_key="${GITHUB_RUN_ID:-manual}-${GITHUB_RUN_ATTEMPT:-1}-$$"
safe_key="$(printf '%s' "$run_key" | tr -cd 'A-Za-z0-9_.-' | cut -c1-48)"
prefix="broker-codex-e2e-${safe_key}"
agent_net="${prefix}-agent"
mock_net="${prefix}-mock"
broker_name="${prefix}-broker"
mock_name="${prefix}-mock"
probe_name="${prefix}-probe"
agent_image="${prefix}-agent-image"
broker_image="${prefix}-broker-image"
tmp_root="${RUNNER_TEMP:-/tmp}/${prefix}"
mkdir -p "$tmp_root/workspace"
printf 'Pinned Codex broker acceptance workspace.\n' > "$tmp_root/workspace/README.txt"

cleanup() {
  set +e
  docker rm -f "$probe_name" "$broker_name" "$mock_name" >/dev/null 2>&1 || true
  docker network rm "$agent_net" "$mock_net" >/dev/null 2>&1 || true
  docker image rm -f "$agent_image" "$broker_image" >/dev/null 2>&1 || true
  rm -rf "$tmp_root"
}
trap cleanup EXIT INT TERM

wait_for_log() {
  local container="$1" needle="$2" attempts="${3:-100}" i
  for ((i=0; i<attempts; i++)); do
    if docker logs "$container" 2>&1 | grep -Fq "$needle"; then
      return 0
    fi
    sleep 0.2
  done
  echo "CODEX_BROKER_E2E_TIMEOUT: $container did not log [$needle]" >&2
  docker logs "$container" >&2 || true
  return 1
}

cat > "$tmp_root/mock.mjs" <<'NODE'
import http from 'node:http';

const adminKey = 'b2b-e2e-admin-key';
const projectId = 'proj_b2b_e2e';
const serviceId = 'svc_b2b_e2e';
const projectKey = 'sk-b2b-e2e-project-key';
const expectedModel = 'gpt-5.6-sol';

function json(res, status, body) {
  const data = JSON.stringify(body);
  res.writeHead(status, {'content-type': 'application/json', 'content-length': Buffer.byteLength(data)});
  res.end(data);
}

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url || '/', 'http://mock');
  const chunks = [];
  for await (const chunk of req) chunks.push(chunk);
  const raw = Buffer.concat(chunks);
  let body = null;
  if (raw.length) {
    try { body = JSON.parse(raw.toString('utf8')); } catch {}
  }

  if (req.method === 'GET' && url.pathname === '/health') {
    json(res, 200, {status: 'ok'});
    return;
  }

  if (url.pathname.startsWith('/v1/organization/')) {
    if (req.headers.authorization !== `Bearer ${adminKey}`) {
      console.log(`ADMIN_AUTH_BAD ${req.method} ${url.pathname}`);
      json(res, 401, {error: {message: 'bad admin auth'}});
      return;
    }
    console.log(`ADMIN ${req.method} ${url.pathname}`);

    if (req.method === 'POST' && url.pathname === '/v1/organization/projects') {
      json(res, 200, {id: projectId, object: 'organization.project', status: 'active'});
      return;
    }
    if (req.method === 'POST' && url.pathname === `/v1/organization/projects/${projectId}/spend_limit`) {
      console.log(`SPEND cents=${String(body?.threshold_amount ?? '')}`);
      json(res, 200, {currency: 'USD', interval: 'month', threshold_amount: body?.threshold_amount, enforcement: {status: 'enforcing'}});
      return;
    }
    if (req.method === 'POST' && url.pathname === `/v1/organization/projects/${projectId}/model_permissions`) {
      console.log(`MODEL_POLICY mode=${String(body?.mode ?? '')} model=${String(body?.model_ids?.[0] ?? '')}`);
      json(res, 200, {mode: body?.mode, model_ids: body?.model_ids});
      return;
    }
    if (req.method === 'POST' && url.pathname === `/v1/organization/projects/${projectId}/hosted_tool_permissions`) {
      console.log('HOSTED_TOOLS_POLICY');
      json(res, 200, body || {});
      return;
    }
    if (req.method === 'POST' && url.pathname === `/v1/organization/projects/${projectId}/service_accounts`) {
      console.log('SERVICE_CREATE');
      json(res, 200, {id: serviceId, role: 'member', api_key: {id: 'key_b2b_e2e', value: projectKey}});
      return;
    }
    if (req.method === 'DELETE' && url.pathname === `/v1/organization/projects/${projectId}/service_accounts/${serviceId}`) {
      console.log('SERVICE_DELETE');
      json(res, 200, {id: serviceId, deleted: true});
      return;
    }
    if (req.method === 'POST' && url.pathname === `/v1/organization/projects/${projectId}/archive`) {
      console.log('PROJECT_ARCHIVE');
      json(res, 200, {id: projectId, status: 'archived'});
      return;
    }
    json(res, 404, {error: {message: 'unhandled admin route'}});
    return;
  }

  if (req.method === 'POST' && url.pathname === '/v1/responses') {
    const authOk = req.headers.authorization === `Bearer ${projectKey}`;
    const projectOk = req.headers['openai-project'] === projectId;
    const model = String(body?.model ?? '');
    console.log(`RESPONSES auth=${authOk ? 'ok' : 'bad'} project=${projectOk ? 'ok' : 'bad'} model=${model} stream=${body?.stream === true ? 'true' : 'false'} store=${body?.store === false ? 'false' : String(body?.store)}`);
    if (!authOk || !projectOk || model !== expectedModel || body?.stream !== true || body?.store !== false) {
      json(res, 400, {error: {message: 'contract mismatch'}});
      return;
    }
    const created = {type: 'response.created', response: {id: 'resp_b2b_e2e'}};
    const completed = {
      type: 'response.completed',
      response: {
        id: 'resp_b2b_e2e',
        usage: {input_tokens: 0, input_tokens_details: null, output_tokens: 0, output_tokens_details: null, total_tokens: 0},
      },
    };
    res.writeHead(200, {'content-type': 'text/event-stream', 'cache-control': 'no-cache', connection: 'close'});
    res.end(`event: response.created\ndata: ${JSON.stringify(created)}\n\n` +
            `event: response.completed\ndata: ${JSON.stringify(completed)}\n\n`);
    return;
  }

  json(res, 404, {error: {message: `unhandled ${req.method} ${url.pathname}`}});
});

server.listen(8080, '0.0.0.0', () => console.log('MOCK_READY'));
NODE

cat > "$tmp_root/prompt.txt" <<'EOF'
Return exactly B2B_CODEX_BROKER_OK without invoking tools, then finish.
EOF
chmod 644 "$tmp_root/prompt.txt"

echo 'Building candidate pinned agent and broker images...'
docker build --tag "$agent_image" --file "$candidate_dir/docker/review-repair-agent.Dockerfile" "$candidate_dir"
docker build --tag "$broker_image" --file "$candidate_dir/docker/provider-broker.Dockerfile" "$candidate_dir"

version="$(docker run --rm --network none --entrypoint codex "$agent_image" --version 2>&1 | head -1 | tr -d '\r')"
if [[ "$version" != *'0.147.0'* ]]; then
  echo "CODEX_BROKER_E2E_VERSION_MISMATCH: expected 0.147.0, got [$version]" >&2
  exit 1
fi
echo "PASS: pinned Codex version is $version"

docker network create --internal "$agent_net" >/dev/null
docker network create --internal "$mock_net" >/dev/null

docker run -d --name "$mock_name" --network "$mock_net" --network-alias mock \
  --read-only --cap-drop=ALL --security-opt=no-new-privileges \
  --tmpfs /tmp:rw,nosuid,nodev,noexec,size=32m \
  --mount "type=bind,src=$tmp_root/mock.mjs,dst=/runtime/mock.mjs,readonly" \
  "$agent_image" node /runtime/mock.mjs >/dev/null
wait_for_log "$mock_name" MOCK_READY

export BROKER_CAPABILITY="b2b-codex-e2e-capability-${safe_key}"
export OPENAI_ADMIN_KEY="b2b-e2e-admin-key"
docker run -d \
  --name "$broker_name" \
  --network "$mock_net" \
  --read-only \
  --cap-drop=ALL \
  --security-opt=no-new-privileges \
  --pids-limit=64 \
  --memory=256m \
  --tmpfs /tmp:rw,nosuid,nodev,noexec,mode=1777,size=64m \
  -e BROKER_PROVIDER=openai \
  -e BROKER_PORT=3080 \
  -e OPENAI_ADMIN_KEY \
  -e BROKER_CAPABILITY \
  -e BROKER_TASK_ID=provider-broker-codex-contract-e2e \
  -e BROKER_ALLOWED_MODEL=gpt-5.6-sol \
  -e BROKER_CAPABILITY_EXPIRY_MS=600000 \
  -e BROKER_MAX_REQUESTS=20 \
  -e BROKER_JOB_MAX_USD=0.25 \
  -e OPENAI_ADMIN_API_URL=http://mock:8080/v1 \
  -e OPENAI_PROVIDER_API_URL=http://mock:8080 \
  "$broker_image" >/dev/null

docker network connect --alias broker "$agent_net" "$broker_name"
wait_for_log "$broker_name" 'ephemeral OpenAI project credential provisioned'

set +e
docker run --name "$probe_name" --init \
  --network "$agent_net" \
  --read-only \
  --user 65534:65534 \
  --cap-drop=ALL \
  --security-opt=no-new-privileges \
  --pids-limit=256 \
  --memory=2g \
  --tmpfs /runtime:rw,nosuid,nodev,mode=1777,size=128m \
  --tmpfs /tmp:rw,nosuid,nodev,mode=1777,size=128m \
  --mount "type=bind,src=$tmp_root/workspace,dst=/workspace" \
  --mount "type=bind,src=$tmp_root/prompt.txt,dst=/seed/prompt.txt,readonly" \
  --workdir /workspace \
  --env AGENT=codex \
  --env AGENT_USE_PREBUILT_PROMPT=true \
  --env AGENT_CREDENTIAL_PROFILE=openai-api \
  --env AGENT_CREDENTIAL_VALUE="$BROKER_CAPABILITY" \
  --env AGENT_HOME=/runtime/home \
  --env AGENT_MODEL=gpt-5.6-sol \
  --env AGENT_MAX_RUNTIME=2 \
  --env AGENT_MAX_ATTEMPTS=1 \
  --env PROMPT_FILE=/runtime/prompt.txt \
  --env AGENT_LOG=/runtime/agent.log \
  "$agent_image" bash -lc '
    set -euo pipefail
    mkdir -p "$AGENT_HOME/.codex"
    cat > "$AGENT_HOME/.codex/config.toml" <<EOF
openai_base_url = "http://broker:3080/v1"
EOF
    cp /seed/prompt.txt "$PROMPT_FILE"
    /opt/review-repair-runner/run-agent.sh
  ' >"$tmp_root/codex.out" 2>"$tmp_root/codex.err"
agent_status=$?
set -e

if [[ "$agent_status" -ne 0 ]]; then
  echo "CODEX_BROKER_E2E_AGENT_FAILED: exit=$agent_status" >&2
  sed -n '1,160p' "$tmp_root/codex.out" >&2 || true
  sed -n '1,200p' "$tmp_root/codex.err" >&2 || true
  echo '--- broker logs ---' >&2
  docker logs "$broker_name" >&2 || true
  echo '--- local mock logs ---' >&2
  docker logs "$mock_name" >&2 || true
  exit 1
fi

echo 'PASS: pinned Codex completed through candidate OpenAI broker'
mock_logs="$(docker logs "$mock_name" 2>&1)"
[[ "$mock_logs" == *'SPEND cents=25'* ]] || { echo 'CODEX_BROKER_E2E_ASSERT_FAILED: provider hard cap was not 25 cents' >&2; exit 1; }
[[ "$mock_logs" == *'MODEL_POLICY mode=allow_list model=gpt-5.6-sol'* ]] || { echo 'CODEX_BROKER_E2E_ASSERT_FAILED: exact model policy missing' >&2; exit 1; }
[[ "$mock_logs" == *'HOSTED_TOOLS_POLICY'* ]] || { echo 'CODEX_BROKER_E2E_ASSERT_FAILED: hosted tool policy missing' >&2; exit 1; }
[[ "$mock_logs" == *'RESPONSES auth=ok project=ok model=gpt-5.6-sol stream=true store=false'* ]] || {
  echo 'CODEX_BROKER_E2E_ASSERT_FAILED: real Codex request did not satisfy broker/provider contract' >&2
  printf '%s\n' "$mock_logs" >&2
  exit 1
}
echo 'PASS: real Codex request used ephemeral project key and exact requested model'

if printf '%s\n' "$mock_logs" | grep -q 'AUTH_BAD'; then
  echo 'CODEX_BROKER_E2E_ASSERT_FAILED: credential injection mismatch' >&2
  exit 1
fi

docker stop --time 10 "$broker_name" >/dev/null
wait_for_log "$mock_name" SERVICE_DELETE
wait_for_log "$mock_name" PROJECT_ARCHIVE
echo 'PASS: graceful broker shutdown deleted service account and archived disposable project'

mock_logs="$(docker logs "$mock_name" 2>&1)"
[[ "$mock_logs" != *"$BROKER_CAPABILITY"* ]] || { echo 'CODEX_BROKER_E2E_ASSERT_FAILED: capability leaked to mock log' >&2; exit 1; }
[[ "$mock_logs" != *"$OPENAI_ADMIN_KEY"* ]] || { echo 'CODEX_BROKER_E2E_ASSERT_FAILED: admin key leaked to mock log' >&2; exit 1; }

echo 'PROVIDER_BROKER_CODEX_E2E=PASS'
echo 'PROVIDER_INFERENCE=0'
