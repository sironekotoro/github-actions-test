#!/usr/bin/env bash
set -euo pipefail

TRUSTED="${1:?trusted checkout required}"
CANDIDATE="${2:?candidate checkout required}"
[ -d "$TRUSTED/.git" ] && [ -d "$CANDIDATE/.git" ] || { echo 'B3C_ORDINARY_E2E_INVALID_CHECKOUT' >&2; exit 1; }

for path in \
  docker/review-repair-agent.Dockerfile \
  docker/review-repair-egress.Dockerfile \
  docker/review-repair-squid.conf \
  docker/provider-broker-package.json \
  scripts/provider-broker.mjs \
  scripts/provider-broker-anthropic.mjs \
  scripts/lib/anthropic-spend-guard.mjs \
  scripts/lib/common.sh \
  scripts/lib/review-repair-cleanup.sh \
  scripts/run-agent.sh \
  scripts/agents/claude-code.sh; do
  cmp -s "$TRUSTED/$path" "$CANDIDATE/$path" || {
    echo "B3C_ORDINARY_E2E_UNEXPECTED_EXECUTED_FILE: $path differs from trusted master" >&2
    exit 1
  }
done
cmp -s "$TRUSTED/tests/fixtures/b3c-provider-broker.Dockerfile" "$CANDIDATE/docker/provider-broker.Dockerfile" \
  || { echo 'B3C_ORDINARY_E2E_UNTRUSTED_BROKER_DOCKERFILE' >&2; exit 1; }
cmp -s "$TRUSTED/tests/fixtures/b3c-provider-broker-entrypoint.sh" "$CANDIDATE/scripts/provider-broker-entrypoint.sh" \
  || { echo 'B3C_ORDINARY_E2E_UNTRUSTED_BROKER_ENTRYPOINT' >&2; exit 1; }

# The candidate wrapper executes on the self-hosted runner and can access the
# Docker socket. Pin every changed executable routing input to the exact blobs
# audited for PR #175; a later candidate revision requires a new trusted review.
[ "$(git -C "$CANDIDATE" hash-object scripts/run-agent-dispatch-container.sh)" = '19d36bcf93f5fe26f2207f86fca7c01b7188e047' ] \
  || { echo 'B3C_ORDINARY_E2E_UNTRUSTED_HOST_WRAPPER' >&2; exit 1; }
[ "$(git -C "$CANDIDATE" hash-object scripts/lib/credentials.sh)" = '6334ff748d3994f9065e42f7d37f4996518a66e0' ] \
  || { echo 'B3C_ORDINARY_E2E_UNTRUSTED_CREDENTIAL_ROUTING' >&2; exit 1; }

runner_uid="$(id -u)"
runner_gid="$(id -g)"
[ "$runner_uid" -ne 0 ] || { echo 'B3C_ORDINARY_E2E_ROOT_RUNNER_FORBIDDEN' >&2; exit 1; }
run_key="$(printf '%s' "${GITHUB_RUN_ID:-$$}" | tr -cd '[:alnum:]')"
[ -n "$run_key" ] || { echo 'B3C_ORDINARY_E2E_INVALID_RUN_KEY' >&2; exit 1; }

agent_image="agent-dispatch-agent:$run_key"
egress_image="agent-dispatch-egress:$run_key"
production_broker_image="provider-broker-production:$run_key"
broker_image="provider-broker:$run_key"
private_network="agent-dispatch-private-$run_key"
egress_network="agent-dispatch-egress-$run_key"
broker_egress_network="agent-dispatch-broker-egress-$run_key"
mock_network="b3c-ordinary-mock-net-$run_key"
mock_name="b3c-ordinary-mock-$run_key"
tmpdir="$(mktemp -d)"
runtime_root="$tmpdir/runtime"
task_file="$tmpdir/task.json"
test_layer="$tmpdir/test-layer"
mock_script="$tmpdir/mock.mjs"
mkdir -p "$runtime_root" "$test_layer"

remove_by_ancestor() {
  local image="$1" cid
  while IFS= read -r cid; do
    [ -n "$cid" ] && docker rm -f "$cid" >/dev/null 2>&1 || true
  done < <(docker ps -aq --filter "ancestor=$image")
}

cleanup() {
  set +e
  [ -n "${wrapper_pid:-}" ] && kill "$wrapper_pid" >/dev/null 2>&1 || true
  docker rm -f "$mock_name" >/dev/null 2>&1 || true
  remove_by_ancestor "$agent_image"
  remove_by_ancestor "$broker_image"
  remove_by_ancestor "$production_broker_image"
  remove_by_ancestor "$egress_image"
  docker network rm "$mock_network" "$private_network" "$broker_egress_network" "$egress_network" >/dev/null 2>&1 || true
  docker image rm -f "$agent_image" "$egress_image" "$broker_image" "$production_broker_image" >/dev/null 2>&1 || true
  rm -rf "$tmpdir"
}
trap cleanup EXIT

cat > "$task_file" <<'JSON'
{
  "task_id": "b3c-ordinary-claude-wiring-e2e",
  "target_repository": "sironekotoro/github-actions-test",
  "title": "B3c ordinary Claude broker wiring E2E",
  "prompt": "Return exactly B3C_OK without invoking tools or changing files. This is a zero-paid local wiring acceptance.",
  "agent": "claude-code",
  "requested_model": "claude-sonnet-5",
  "max_runtime": 2,
  "dry_run": false,
  "runner_mode": "self-hosted"
}
JSON

cat > "$mock_script" <<'NODE'
import http from 'node:http';

const expectedKey = 'b3c-local-provider-marker';
const expectedModel = 'claude-sonnet-5';
const server = http.createServer(async (req, res) => {
  const url = new URL(req.url || '/', 'http://mock');
  if (req.method === 'GET' && url.pathname === '/health') {
    res.writeHead(200); res.end('ok'); return;
  }
  const chunks = [];
  for await (const chunk of req) chunks.push(chunk);
  let body = null;
  try { body = JSON.parse(Buffer.concat(chunks).toString('utf8')); } catch {}

  if (req.method === 'POST' && url.pathname === '/v1/messages/count_tokens' && url.search === '?beta=true') {
    const capture = {
      providerKeyMatch: req.headers['x-api-key'] === expectedKey,
      authorizationAbsent: req.headers.authorization === undefined,
      modelMatch: body?.model === expectedModel,
      maxTokensAbsent: !Object.hasOwn(body || {}, 'max_tokens'),
      streamAbsent: !Object.hasOwn(body || {}, 'stream'),
    };
    process.stdout.write(`COUNT_CAPTURE ${JSON.stringify(capture)}\n`);
    const payload = JSON.stringify(capture.providerKeyMatch && capture.authorizationAbsent && capture.modelMatch && capture.maxTokensAbsent && capture.streamAbsent
      ? {input_tokens:12000} : {error:{message:'count contract mismatch'}});
    res.writeHead(capture.providerKeyMatch && capture.authorizationAbsent && capture.modelMatch && capture.maxTokensAbsent && capture.streamAbsent ? 200 : 400,
      {'content-type':'application/json','content-length':Buffer.byteLength(payload)});
    res.end(payload);
    return;
  }

  if (req.method === 'POST' && url.pathname === '/v1/messages' && url.search === '?beta=true') {
    const capture = {
      providerKeyMatch: req.headers['x-api-key'] === expectedKey,
      authorizationAbsent: req.headers.authorization === undefined,
      modelMatch: body?.model === expectedModel,
      stream: body?.stream ?? null,
      maxTokens: body?.max_tokens ?? null,
      anthropicVersion: req.headers['anthropic-version'] ?? null,
    };
    process.stdout.write(`MESSAGE_CAPTURE ${JSON.stringify(capture)}\n`);
    if (!capture.providerKeyMatch || !capture.authorizationAbsent || !capture.modelMatch || capture.stream !== true || capture.maxTokens !== 4096) {
      res.writeHead(400, {'content-type':'application/json'});
      res.end(JSON.stringify({error:{message:'message contract mismatch'}}));
      return;
    }
    await new Promise((resolve) => setTimeout(resolve, 2200));
    const message = {id:'msg_b3c',type:'message',role:'assistant',model:expectedModel,content:[],stop_reason:null,stop_sequence:null,usage:{input_tokens:0,output_tokens:0}};
    res.writeHead(200, {'content-type':'text/event-stream','cache-control':'no-cache','connection':'close'});
    res.end(
      `event: message_start\ndata: ${JSON.stringify({type:'message_start',message})}\n\n` +
      `event: content_block_start\ndata: ${JSON.stringify({type:'content_block_start',index:0,content_block:{type:'text',text:''}})}\n\n` +
      `event: content_block_delta\ndata: ${JSON.stringify({type:'content_block_delta',index:0,delta:{type:'text_delta',text:'B3C_OK'}})}\n\n` +
      `event: content_block_stop\ndata: ${JSON.stringify({type:'content_block_stop',index:0})}\n\n` +
      `event: message_delta\ndata: ${JSON.stringify({type:'message_delta',delta:{stop_reason:'end_turn',stop_sequence:null},usage:{output_tokens:1}})}\n\n` +
      `event: message_stop\ndata: ${JSON.stringify({type:'message_stop'})}\n\n`
    );
    return;
  }

  process.stdout.write(`UNEXPECTED_ROUTE ${req.method} ${url.pathname}${url.search}\n`);
  res.writeHead(404, {'content-type':'application/json'});
  res.end('{}');
});
server.listen(8080, '0.0.0.0', () => process.stdout.write('MOCK_READY\n'));
NODE

cat > "$test_layer/entrypoint.sh" <<'SH'
#!/usr/bin/env sh
set -eu
unset BROKER_PROXY_URL
export ANTHROPIC_PROVIDER_API_URL=http://mock:8080
exec sh /opt/provider-broker/entrypoint.sh
SH
cat > "$test_layer/Dockerfile" <<'DOCKER'
ARG BASE_IMAGE
FROM ${BASE_IMAGE}
COPY entrypoint.sh /opt/provider-broker/e2e-entrypoint.sh
USER nobody
CMD ["sh", "/opt/provider-broker/e2e-entrypoint.sh"]
DOCKER

echo 'Building pinned agent, egress, and exact production broker images...'
docker build --tag "$agent_image" --file "$TRUSTED/docker/review-repair-agent.Dockerfile" "$CANDIDATE" >/dev/null
docker build --tag "$egress_image" --file "$TRUSTED/docker/review-repair-egress.Dockerfile" "$CANDIDATE" >/dev/null
docker build --tag "$production_broker_image" --file "$CANDIDATE/docker/provider-broker.Dockerfile" "$CANDIDATE" >/dev/null
docker build --tag "$broker_image" --build-arg "BASE_IMAGE=$production_broker_image" "$test_layer" >/dev/null

claude_version="$(docker run --rm --network none --read-only --cap-drop=ALL --security-opt=no-new-privileges "$agent_image" claude --version 2>&1)"
case "$claude_version" in
  *2.1.165*) echo "PASS: pinned Claude version is $claude_version" ;;
  *) echo "B3C_ORDINARY_E2E_CLAUDE_VERSION_MISMATCH: $claude_version" >&2; exit 1 ;;
esac

docker network create --internal "$mock_network" >/dev/null
docker run -d --name "$mock_name" --network "$mock_network" --network-alias mock \
  --read-only --cap-drop=ALL --security-opt=no-new-privileges \
  --tmpfs /tmp:rw,nosuid,nodev,noexec,size=16m \
  --mount "type=bind,src=$mock_script,dst=/runtime/mock.mjs,readonly" \
  "$agent_image" node /runtime/mock.mjs >/dev/null
for _ in $(seq 1 50); do
  docker logs "$mock_name" 2>&1 | grep -q '^MOCK_READY$' && break
  sleep 0.1
done
docker logs "$mock_name" 2>&1 | grep -q '^MOCK_READY$' || { echo 'B3C_ORDINARY_E2E_MOCK_START_FAILED' >&2; exit 1; }

wrapper_stdout="$tmpdir/wrapper.stdout"
wrapper_stderr="$tmpdir/wrapper.stderr"
set +e
RUNNER_TEMP="$runtime_root" \
TARGET_DIR="$CANDIDATE" \
TASK_FILE="$task_file" \
GITHUB_RUN_ID="$run_key" \
PROVIDER_BROKER_ENABLED=true \
PROVIDER_JOB_MAX_USD=0.25 \
ANTHROPIC_API_KEY='b3c-local-provider-marker' \
ANTHROPIC_BROKER_LIVE_ALLOWED=true \
AGENT_MAX_RUNTIME=2 \
CLAUDE_MODEL='should-not-win-over-task-model' \
bash "$CANDIDATE/scripts/run-agent-dispatch-container.sh" >"$wrapper_stdout" 2>"$wrapper_stderr" &
wrapper_pid=$!
set -e

broker_connected=false
for _ in $(seq 1 500); do
  if docker inspect "agent-dispatch-broker-$run_key" >/dev/null 2>&1; then
    if docker network connect "$mock_network" "agent-dispatch-broker-$run_key" >/dev/null 2>&1; then
      broker_connected=true
      break
    fi
  fi
  sleep 0.02
done
[ "$broker_connected" = true ] || { wait "$wrapper_pid" || true; echo 'B3C_ORDINARY_E2E_BROKER_MOCK_NETWORK_FAILED' >&2; cat "$wrapper_stderr" >&2 || true; exit 1; }

agent_container=''
for _ in $(seq 1 200); do
  while IFS= read -r cid; do
    [ -n "$cid" ] || continue
    profile="$(docker inspect "$cid" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null | sed -n 's/^AGENT_CREDENTIAL_PROFILE=//p')"
    if [ "$profile" = 'anthropic-broker' ]; then agent_container="$cid"; break 2; fi
  done < <(docker ps -q --filter "ancestor=$agent_image")
  sleep 0.03
done
[ -n "$agent_container" ] || { wait "$wrapper_pid" || true; echo 'B3C_ORDINARY_E2E_AGENT_CONTAINER_NOT_OBSERVED' >&2; cat "$wrapper_stderr" >&2 || true; exit 1; }

agent_env="$(docker inspect "$agent_container" --format '{{range .Config.Env}}{{println .}}{{end}}')"
has_name() { printf '%s\n' "$agent_env" | grep -q "^$1="; }
value_of() { printf '%s\n' "$agent_env" | sed -n "s/^$1=//p"; }
! has_name ANTHROPIC_API_KEY || { echo 'B3C_ORDINARY_E2E_PROVIDER_KEY_LEAKED_TO_AGENT' >&2; exit 1; }
! has_name HTTP_PROXY || { echo 'B3C_ORDINARY_E2E_HTTP_PROXY_LEAKED_TO_AGENT' >&2; exit 1; }
! has_name HTTPS_PROXY || { echo 'B3C_ORDINARY_E2E_HTTPS_PROXY_LEAKED_TO_AGENT' >&2; exit 1; }
! has_name ALL_PROXY || { echo 'B3C_ORDINARY_E2E_ALL_PROXY_LEAKED_TO_AGENT' >&2; exit 1; }
has_name AGENT_CREDENTIAL_VALUE || { echo 'B3C_ORDINARY_E2E_CAPABILITY_MISSING' >&2; exit 1; }
[ "$(value_of AGENT_CREDENTIAL_PROFILE)" = 'anthropic-broker' ] || { echo 'B3C_ORDINARY_E2E_PROFILE_MISMATCH' >&2; exit 1; }
[ "$(value_of CLAUDE_MODEL)" = 'claude-sonnet-5' ] || { echo 'B3C_ORDINARY_E2E_CLAUDE_MODEL_MISMATCH' >&2; exit 1; }
case "$(value_of ANTHROPIC_BROKER_BASE_URL)" in http://*:3080) ;; *) echo 'B3C_ORDINARY_E2E_BROKER_URL_MISSING' >&2; exit 1 ;; esac
[ "$(docker inspect "$private_network" --format '{{.Internal}}')" = true ] || { echo 'B3C_ORDINARY_E2E_AGENT_NETWORK_NOT_INTERNAL' >&2; exit 1; }

mock_logs=''
for _ in $(seq 1 160); do
  mock_logs="$(docker logs "$mock_name" 2>&1 || true)"
  printf '%s\n' "$mock_logs" | grep -q '^MESSAGE_CAPTURE ' && break
  sleep 0.05
done
broker_logs="$(docker logs "agent-dispatch-broker-$run_key" 2>&1 || true)"
[ "$(printf '%s\n' "$mock_logs" | grep -c '^COUNT_CAPTURE ' || true)" -eq 1 ] || { echo 'B3C_ORDINARY_E2E_COUNT_REQUEST_MISMATCH' >&2; exit 1; }
[ "$(printf '%s\n' "$mock_logs" | grep -c '^MESSAGE_CAPTURE ' || true)" -eq 1 ] || { echo 'B3C_ORDINARY_E2E_MESSAGE_REQUEST_MISMATCH' >&2; exit 1; }
count_line="$(printf '%s\n' "$mock_logs" | grep -n '^COUNT_CAPTURE ' | cut -d: -f1)"
message_line="$(printf '%s\n' "$mock_logs" | grep -n '^MESSAGE_CAPTURE ' | cut -d: -f1)"
[ "$count_line" -lt "$message_line" ] || { echo 'B3C_ORDINARY_E2E_COUNT_NOT_BEFORE_MESSAGES' >&2; exit 1; }
printf '%s\n' "$mock_logs" | grep '^COUNT_CAPTURE ' | grep -q '"providerKeyMatch":true' || { echo 'B3C_ORDINARY_E2E_COUNT_AUTH_NOT_PROVEN' >&2; exit 1; }
printf '%s\n' "$mock_logs" | grep '^COUNT_CAPTURE ' | grep -q '"maxTokensAbsent":true' || { echo 'B3C_ORDINARY_E2E_COUNT_BODY_NOT_PROVEN' >&2; exit 1; }
printf '%s\n' "$mock_logs" | grep '^MESSAGE_CAPTURE ' | grep -q '"modelMatch":true' || { echo 'B3C_ORDINARY_E2E_MODEL_NOT_PROVEN' >&2; exit 1; }
printf '%s\n' "$mock_logs" | grep '^MESSAGE_CAPTURE ' | grep -q '"maxTokens":4096' || { echo 'B3C_ORDINARY_E2E_MAX_TOKENS_NOT_GUARDED' >&2; exit 1; }
printf '%s\n' "$broker_logs" | grep -q 'spend reservation pricing=' || { echo 'B3C_ORDINARY_E2E_RESERVATION_NOT_RECORDED' >&2; exit 1; }

set +e
wait "$wrapper_pid"
wrapper_status=$?
set -e
wrapper_pid=''
[ "$wrapper_status" -ne 0 ] || { echo 'B3C_ORDINARY_E2E_EXPECTED_NO_CHANGE_FAILURE_MISSING' >&2; exit 1; }
[ "$(cat "$runtime_root/failure_category" 2>/dev/null || true)" = 'AGENT_PATCH_INVALID' ] || { echo 'B3C_ORDINARY_E2E_UNEXPECTED_FAILURE_CATEGORY' >&2; exit 1; }
[ "$(cat "$runtime_root/failure_reason" 2>/dev/null || true)" = 'NO_CHANGES' ] || { echo 'B3C_ORDINARY_E2E_UNEXPECTED_FAILURE_REASON' >&2; exit 1; }

docker rm -f "$mock_name" >/dev/null
docker network disconnect "$mock_network" "agent-dispatch-broker-$run_key" >/dev/null 2>&1 || true
docker network rm "$mock_network" >/dev/null
docker network rm "$private_network" >/dev/null 2>&1 || true

for secret in 'b3c-local-provider-marker'; do
  if grep -Fq "$secret" "$wrapper_stdout" "$wrapper_stderr" || printf '%s\n' "$broker_logs" | grep -Fq "$secret"; then
    echo 'B3C_ORDINARY_E2E_SECRET_LEAKED_TO_LOG' >&2
    exit 1
  fi
done
docker ps -aq --filter "name=agent-dispatch-broker-$run_key" | grep -q . && { echo 'B3C_ORDINARY_E2E_BROKER_CLEANUP_FAILED' >&2; exit 1; }
docker network inspect "$mock_network" >/dev/null 2>&1 && { echo 'B3C_ORDINARY_E2E_MOCK_NETWORK_CLEANUP_FAILED' >&2; exit 1; }
docker network inspect "$private_network" >/dev/null 2>&1 && { echo 'B3C_ORDINARY_E2E_PRIVATE_NETWORK_CLEANUP_FAILED' >&2; exit 1; }

echo 'PASS: ordinary Claude container received capability-only broker environment'
echo 'PASS: Count Tokens admission and guarded Messages request used local mock only'
echo 'PASS: wrapper cleanup removed the per-job broker container'
echo 'B3C_ORDINARY_CLAUDE_BROKER_E2E=PASS'
echo 'CLAUDE_CLI=2.1.165'
echo 'PROVIDER_INFERENCE=0'
