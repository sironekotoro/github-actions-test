#!/usr/bin/env bash
set -euo pipefail

TRUSTED="${1:?trusted checkout required}"
CANDIDATE="${2:?candidate checkout required}"

[ -f "$TRUSTED/docker/review-repair-agent.Dockerfile" ] || { echo 'CLAUDE_B3B_E2E_INVALID_TRUSTED: missing Dockerfile' >&2; exit 1; }
for file in scripts/run-agent.sh scripts/agents/claude-code.sh scripts/provider-broker-anthropic.mjs; do
  [ -f "$CANDIDATE/$file" ] || { echo "CLAUDE_B3B_E2E_INVALID_CANDIDATE: missing $file" >&2; exit 1; }
done

runner_uid="$(id -u)"
runner_gid="$(id -g)"
[ "$runner_uid" -ne 0 ] || { echo 'CLAUDE_B3B_E2E_ROOT_RUNNER_FORBIDDEN' >&2; exit 1; }

suffix="${GITHUB_RUN_ID:-$$}-${RANDOM}"
image="claude-b3b-agent:${suffix}"
network="claude-b3b-${suffix}"
mock_name="claude-b3b-mock-${suffix}"
broker_name="claude-b3b-broker-${suffix}"
agent_name="claude-b3b-agent-${suffix}"
tmpdir="$(mktemp -d)"
workspace="$tmpdir/workspace"
mock_script="$tmpdir/mock.mjs"
mkdir -p "$workspace"
printf 'B3b Claude broker E2E workspace.\n' > "$workspace/README.txt"

cleanup() {
  docker rm -f "$agent_name" "$broker_name" "$mock_name" >/dev/null 2>&1 || true
  docker network rm "$network" >/dev/null 2>&1 || true
  docker image rm -f "$image" >/dev/null 2>&1 || true
  rm -rf "$tmpdir"
}
trap cleanup EXIT

echo 'Building candidate runtime with trusted pinned Dockerfile...'
docker build --tag "$image" --file "$TRUSTED/docker/review-repair-agent.Dockerfile" "$CANDIDATE" >/dev/null
claude_version="$(docker run --rm --network none --read-only --cap-drop=ALL --security-opt=no-new-privileges "$image" claude --version 2>&1)"
printf 'Pinned Claude Code CLI: %s\n' "$claude_version"
case "$claude_version" in
  *2.1.165*) ;;
  *) echo 'CLAUDE_B3B_E2E_VERSION_MISMATCH' >&2; exit 1 ;;
esac

cat > "$mock_script" <<'NODE'
import http from 'node:http';
const expectedKey = 'b3b-fake-provider-key';
const expectedModel = 'b3b-requested-model-marker';
const state = { posts: 0, head: 0 };
const server = http.createServer(async (req, res) => {
  const url = new URL(req.url || '/', 'http://mock');
  const chunks = [];
  for await (const chunk of req) chunks.push(chunk);
  const raw = Buffer.concat(chunks);
  if (req.method === 'GET' && url.pathname === '/health') {
    res.writeHead(200); res.end('ok'); return;
  }
  if (req.method === 'HEAD' && url.pathname === '/') {
    state.head++;
    process.stdout.write('UPSTREAM_HEAD_UNEXPECTED\n');
    res.writeHead(500); res.end(); return;
  }
  if (req.method !== 'POST' || url.pathname !== '/v1/messages' || url.search !== '?beta=true') {
    res.writeHead(404, {'content-type':'application/json'});
    res.end(JSON.stringify({error:{message:'unexpected local mock route'}}));
    return;
  }
  let body = null;
  try { body = JSON.parse(raw.toString('utf8')); } catch {}
  state.posts++;
  const capture = {
    method: req.method,
    path: url.pathname,
    query: url.search,
    providerKeyMatch: req.headers['x-api-key'] === expectedKey,
    authorizationAbsent: req.headers.authorization === undefined,
    modelMatch: body?.model === expectedModel,
    stream: body?.stream ?? null,
    maxTokens: body?.max_tokens ?? null,
    anthropicVersion: req.headers['anthropic-version'] ?? null,
    hasAnthropicBeta: typeof req.headers['anthropic-beta'] === 'string' && req.headers['anthropic-beta'].length > 0,
    rawBytes: raw.length,
  };
  process.stdout.write(`CAPTURE ${JSON.stringify(capture)}\n`);
  if (!capture.providerKeyMatch || !capture.authorizationAbsent || !capture.modelMatch || body?.stream !== true) {
    res.writeHead(400, {'content-type':'application/json'});
    res.end(JSON.stringify({error:{message:'contract mismatch'}}));
    return;
  }
  const message = {
    id:'msg_b3b', type:'message', role:'assistant', model:expectedModel,
    content:[], stop_reason:null, stop_sequence:null,
    usage:{input_tokens:0, output_tokens:0},
  };
  res.writeHead(200, {'content-type':'text/event-stream','cache-control':'no-cache',connection:'close'});
  res.end(
    `event: message_start\ndata: ${JSON.stringify({type:'message_start',message})}\n\n` +
    `event: content_block_start\ndata: ${JSON.stringify({type:'content_block_start',index:0,content_block:{type:'text',text:''}})}\n\n` +
    `event: content_block_delta\ndata: ${JSON.stringify({type:'content_block_delta',index:0,delta:{type:'text_delta',text:'B3B_OK'}})}\n\n` +
    `event: content_block_stop\ndata: ${JSON.stringify({type:'content_block_stop',index:0})}\n\n` +
    `event: message_delta\ndata: ${JSON.stringify({type:'message_delta',delta:{stop_reason:'end_turn',stop_sequence:null},usage:{output_tokens:1}})}\n\n` +
    `event: message_stop\ndata: ${JSON.stringify({type:'message_stop'})}\n\n`
  );
});
server.listen(8080, '0.0.0.0', () => process.stdout.write('MOCK_READY\n'));
NODE

docker network create --internal "$network" >/dev/null

docker run -d --name "$mock_name" --network "$network" --network-alias mock \
  --read-only --cap-drop=ALL --security-opt=no-new-privileges \
  --tmpfs /tmp:rw,nosuid,nodev,noexec,size=16m \
  --mount "type=bind,src=$mock_script,dst=/runtime/mock.mjs,readonly" \
  "$image" node /runtime/mock.mjs >/dev/null

for _ in $(seq 1 50); do
  docker logs "$mock_name" 2>&1 | grep -q '^MOCK_READY$' && break
  sleep 0.1
done
docker logs "$mock_name" 2>&1 | grep -q '^MOCK_READY$' || { echo 'CLAUDE_B3B_E2E_MOCK_START_FAILED' >&2; exit 1; }

docker run -d --name "$broker_name" --network "$network" --network-alias broker \
  --read-only --cap-drop=ALL --security-opt=no-new-privileges \
  --tmpfs /tmp:rw,nosuid,nodev,noexec,size=16m \
  --mount "type=bind,src=$CANDIDATE/scripts/provider-broker-anthropic.mjs,dst=/runtime/provider-broker-anthropic.mjs,readonly" \
  --env BROKER_PORT=3080 \
  --env ANTHROPIC_API_KEY=b3b-fake-provider-key \
  --env ANTHROPIC_PROVIDER_API_URL=http://mock:8080 \
  --env BROKER_ANTHROPIC_LIVE_ALLOWED=true \
  --env BROKER_CAPABILITY=b3b-agent-capability-marker \
  --env BROKER_TASK_ID=b3b-e2e \
  --env BROKER_ALLOWED_MODEL=b3b-requested-model-marker \
  --env BROKER_CAPABILITY_EXPIRY_MS=600000 \
  --env BROKER_MAX_REQUESTS=20 \
  "$image" node /runtime/provider-broker-anthropic.mjs >/dev/null

broker_ready=false
for _ in $(seq 1 50); do
  if docker run --rm --network "$network" "$image" node -e \
    "fetch('http://broker:3080/health').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))" >/dev/null 2>&1; then
    broker_ready=true; break
  fi
  sleep 0.1
done
[ "$broker_ready" = true ] || { echo 'CLAUDE_B3B_E2E_BROKER_START_FAILED' >&2; docker logs "$broker_name" >&2 || true; exit 1; }

set +e
docker run --name "$agent_name" --network "$network" --user "$runner_uid:$runner_gid" \
  --read-only --cap-drop=ALL --security-opt=no-new-privileges \
  --tmpfs /runtime:rw,nosuid,nodev,mode=1777,size=128m \
  --tmpfs /tmp:rw,nosuid,nodev,mode=1777,size=128m \
  --mount "type=bind,src=$workspace,dst=/workspace" --workdir /workspace \
  --env AGENT=claude-code \
  --env AGENT_USE_PREBUILT_PROMPT=true \
  --env AGENT_CREDENTIAL_PROFILE=anthropic-api \
  --env AGENT_CREDENTIAL_VALUE=b3b-agent-capability-marker \
  --env AGENT_HOME=/runtime/home \
  --env AGENT_MODEL=b3b-requested-model-marker \
  --env AGENT_MAX_RUNTIME=2 \
  --env AGENT_MAX_ATTEMPTS=1 \
  --env ANTHROPIC_BROKER_BASE_URL=http://broker:3080 \
  --env PROMPT_FILE=/runtime/prompt.txt \
  --env AGENT_LOG=/runtime/agent.log \
  "$image" bash -lc '
    set -euo pipefail
    printf "%s\n" "Return exactly B3B_OK without invoking tools, then finish." > "$PROMPT_FILE"
    /opt/review-repair-runner/run-agent.sh
  '
agent_status=$?
set -e

agent_logs="$(docker logs "$agent_name" 2>&1 || true)"
mock_logs="$(docker logs "$mock_name" 2>&1 || true)"
broker_logs="$(docker logs "$broker_name" 2>&1 || true)"
printf '%s\n' "$mock_logs" | grep '^CAPTURE ' || true

[ "$agent_status" -eq 0 ] || { echo "CLAUDE_B3B_E2E_AGENT_FAILED: $agent_status" >&2; printf '%s\n' "$agent_logs" >&2; exit "$agent_status"; }
[ "$(printf '%s\n' "$mock_logs" | grep -c '^CAPTURE ' || true)" -eq 1 ] || { echo 'CLAUDE_B3B_E2E_POST_COUNT_MISMATCH' >&2; exit 1; }
! printf '%s\n' "$mock_logs" | grep -q '^UPSTREAM_HEAD_UNEXPECTED$' || { echo 'CLAUDE_B3B_E2E_HEAD_FORWARDED' >&2; exit 1; }
printf '%s\n' "$mock_logs" | grep '^CAPTURE ' | grep -q '"providerKeyMatch":true' || { echo 'CLAUDE_B3B_E2E_PROVIDER_AUTH_MISMATCH' >&2; exit 1; }
printf '%s\n' "$mock_logs" | grep '^CAPTURE ' | grep -q '"authorizationAbsent":true' || { echo 'CLAUDE_B3B_E2E_AUTH_HEADER_LEAK' >&2; exit 1; }
printf '%s\n' "$mock_logs" | grep '^CAPTURE ' | grep -q '"modelMatch":true' || { echo 'CLAUDE_B3B_E2E_MODEL_MISMATCH' >&2; exit 1; }
printf '%s\n' "$mock_logs" | grep '^CAPTURE ' | grep -q '"stream":true' || { echo 'CLAUDE_B3B_E2E_STREAM_MISMATCH' >&2; exit 1; }
! printf '%s\n%s\n' "$agent_logs" "$broker_logs" | grep -Fq 'b3b-fake-provider-key' || { echo 'CLAUDE_B3B_E2E_PROVIDER_KEY_LEAK' >&2; exit 1; }
! printf '%s\n' "$broker_logs" | grep -Fq 'b3b-agent-capability-marker' || { echo 'CLAUDE_B3B_E2E_CAPABILITY_LEAK' >&2; exit 1; }

echo 'CLAUDE_B3B_BROKER_E2E=PASS'
echo 'CLAUDE_CLI=2.1.165'
echo 'PROVIDER_INFERENCE=0'
