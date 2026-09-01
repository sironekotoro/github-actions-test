#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CANDIDATE="${1:-}"
[ -n "$CANDIDATE" ] && [ -d "$CANDIDATE/.git" ] || { echo 'B2C_E2E_INVALID_CANDIDATE' >&2; exit 1; }

for path in \
  docker/review-repair-agent.Dockerfile \
  docker/review-repair-egress.Dockerfile \
  docker/review-repair-squid.conf; do
  cmp -s "$ROOT/$path" "$CANDIDATE/$path" || {
    echo "B2C_E2E_UNTRUSTED_BUILD_INPUT: $path differs from trusted master" >&2
    exit 1
  }
done

run_key="$(printf '%s' "${GITHUB_RUN_ID:-$$}" | tr -cd '[:alnum:]')"
[ -n "$run_key" ] || { echo 'B2C_E2E_INVALID_RUN_KEY' >&2; exit 1; }
agent_image="agent-dispatch-agent:$run_key"
egress_image="agent-dispatch-egress:$run_key"
broker_image="provider-broker:$run_key"
tmpdir="$(mktemp -d)"
task_file="$tmpdir/task.json"
runtime_root="$tmpdir/runtime"
fake_context="$tmpdir/fake-broker"
mkdir -p "$runtime_root" "$fake_context"

remove_by_ancestor() {
  local image="$1" cid
  while IFS= read -r cid; do
    [ -n "$cid" ] && docker rm -f "$cid" >/dev/null 2>&1 || true
  done < <(docker ps -aq --filter "ancestor=$image")
}

cleanup() {
  set +e
  [ -n "${wrapper_pid:-}" ] && kill "$wrapper_pid" >/dev/null 2>&1 || true
  remove_by_ancestor "$agent_image"
  remove_by_ancestor "$broker_image"
  remove_by_ancestor "$egress_image"
  docker image rm -f "$agent_image" "$egress_image" "$broker_image" >/dev/null 2>&1 || true
  rm -rf "$tmpdir"
}
trap cleanup EXIT

cat > "$task_file" <<'JSON'
{
  "task_id": "b2c-ordinary-codex-wiring-e2e",
  "target_repository": "sironekotoro/github-actions-test",
  "title": "B2c ordinary Codex broker wiring E2E",
  "prompt": "Return without changing any files. This is a zero-paid local wiring acceptance.",
  "agent": "codex",
  "requested_model": "gpt-5.6-sol",
  "max_runtime": 2,
  "dry_run": false,
  "runner_mode": "self-hosted"
}
JSON

cat > "$fake_context/mock.mjs" <<'NODE'
import http from 'node:http';

const capability = process.env.BROKER_CAPABILITY || '';
const allowedModel = process.env.BROKER_ALLOWED_MODEL || '';
const provider = process.env.BROKER_PROVIDER || '';
const adminPresent = Boolean(process.env.OPENAI_ADMIN_KEY);

if (!capability || provider !== 'openai' || !adminPresent || allowedModel !== 'gpt-5.6-sol') {
  process.stderr.write('FAKE_BROKER_CONFIG_INVALID\n');
  process.exit(1);
}

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url || '/', 'http://fake');
  if (req.method === 'GET' && url.pathname === '/health') {
    res.writeHead(200, {'content-type': 'application/json'});
    res.end('{"status":"ok"}');
    return;
  }

  const authOk = req.headers.authorization === `Bearer ${capability}`;
  if (req.method === 'GET' && url.pathname === '/v1/responses') {
    process.stdout.write(`B2C_WS_AUTH_OK=${authOk ? '1' : '0'}\n`);
    res.writeHead(authOk ? 426 : 401, {'content-type': 'application/json'});
    res.end('{}');
    return;
  }

  if (req.method === 'POST' && url.pathname === '/v1/responses') {
    const chunks = [];
    for await (const chunk of req) chunks.push(chunk);
    let body = null;
    try { body = JSON.parse(Buffer.concat(chunks).toString('utf8')); } catch {}
    const modelOk = body?.model === allowedModel;
    const requestOk = authOk && modelOk;
    process.stdout.write(`B2C_POST_AUTH_OK=${authOk ? '1' : '0'}\n`);
    process.stdout.write(`B2C_POST_MODEL_OK=${modelOk ? '1' : '0'}\n`);
    await new Promise((resolve) => setTimeout(resolve, 2200));
    const created = {type:'response.created',response:{id:'resp_b2c'}};
    const completed = {type:'response.completed',response:{id:'resp_b2c',usage:{input_tokens:0,input_tokens_details:null,output_tokens:0,output_tokens_details:null,total_tokens:0}}};
    res.writeHead(requestOk ? 200 : 400, {'content-type':'text/event-stream','cache-control':'no-cache',connection:'close'});
    res.end(`event: response.created\ndata: ${JSON.stringify(created)}\n\n` +
            `event: response.completed\ndata: ${JSON.stringify(completed)}\n\n`);
    return;
  }

  res.writeHead(403, {'content-type':'application/json'});
  res.end('{}');
});

server.listen(3080, '0.0.0.0', () => process.stdout.write('FAKE_BROKER_READY\n'));
NODE

cat > "$fake_context/Dockerfile" <<'DOCKER'
FROM node:22-bookworm-slim@sha256:83f487e0a63425e5b4d146fb5e5be574bcbe1b7b843d3ebafdd95eaf7767a7e5
COPY mock.mjs /opt/mock.mjs
USER node
CMD ["node", "/opt/mock.mjs"]
DOCKER

echo 'Building trusted/candidate runtime images...'
docker build --tag "$agent_image" --file "$CANDIDATE/docker/review-repair-agent.Dockerfile" "$CANDIDATE" >/dev/null
docker build --tag "$egress_image" --file "$CANDIDATE/docker/review-repair-egress.Dockerfile" "$CANDIDATE" >/dev/null
docker build --tag "$broker_image" "$fake_context" >/dev/null

codex_version="$(docker run --rm --network none --read-only --cap-drop=ALL --security-opt=no-new-privileges "$agent_image" codex --version 2>&1)"
case "$codex_version" in
  *0.147.0*) echo "PASS: pinned Codex version is $codex_version" ;;
  *) echo "B2C_E2E_CODEX_VERSION_MISMATCH: $codex_version" >&2; exit 1 ;;
esac

wrapper_stdout="$tmpdir/wrapper.stdout"
wrapper_stderr="$tmpdir/wrapper.stderr"
set +e
RUNNER_TEMP="$runtime_root" \
TARGET_DIR="$CANDIDATE" \
TASK_FILE="$task_file" \
GITHUB_RUN_ID="$run_key" \
PROVIDER_BROKER_ENABLED=true \
PROVIDER_JOB_MAX_USD=0.25 \
OPENAI_ADMIN_KEY='b2c-local-admin-marker' \
AGENT_MAX_RUNTIME=2 \
CODEX_MODEL='should-not-win-over-task-model' \
bash "$CANDIDATE/scripts/run-agent-dispatch-container.sh" >"$wrapper_stdout" 2>"$wrapper_stderr" &
wrapper_pid=$!
set -e

agent_container=''
for _ in $(seq 1 120); do
  while IFS= read -r cid; do
    [ -n "$cid" ] || continue
    env_names="$(docker inspect "$cid" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null | sed 's/=.*//' || true)"
    if printf '%s\n' "$env_names" | grep -qx 'AGENT_CREDENTIAL_PROFILE'; then
      profile="$(docker inspect "$cid" --format '{{range .Config.Env}}{{println .}}{{end}}' | sed -n 's/^AGENT_CREDENTIAL_PROFILE=//p')"
      if [ "$profile" = 'openai-broker' ]; then
        agent_container="$cid"
        break 2
      fi
    fi
  done < <(docker ps -q --filter "ancestor=$agent_image")
  sleep 0.05
done

[ -n "$agent_container" ] || {
  wait "$wrapper_pid" || true
  echo 'B2C_E2E_AGENT_CONTAINER_NOT_OBSERVED' >&2
  cat "$wrapper_stderr" >&2 || true
  exit 1
}

agent_env="$(docker inspect "$agent_container" --format '{{range .Config.Env}}{{println .}}{{end}}')"
has_name() { printf '%s\n' "$agent_env" | grep -q "^$1="; }
value_of() { printf '%s\n' "$agent_env" | sed -n "s/^$1=//p"; }

! has_name OPENAI_ADMIN_KEY || { echo 'B2C_E2E_ADMIN_KEY_LEAKED_TO_AGENT' >&2; exit 1; }
! has_name OPENAI_API_KEY || { echo 'B2C_E2E_DIRECT_OPENAI_KEY_LEAKED_TO_AGENT' >&2; exit 1; }
! has_name HTTP_PROXY || { echo 'B2C_E2E_HTTP_PROXY_LEAKED_TO_AGENT' >&2; exit 1; }
! has_name HTTPS_PROXY || { echo 'B2C_E2E_HTTPS_PROXY_LEAKED_TO_AGENT' >&2; exit 1; }
! has_name ALL_PROXY || { echo 'B2C_E2E_ALL_PROXY_LEAKED_TO_AGENT' >&2; exit 1; }
has_name AGENT_CREDENTIAL_VALUE || { echo 'B2C_E2E_CAPABILITY_MISSING' >&2; exit 1; }
[ "$(value_of AGENT_CREDENTIAL_PROFILE)" = 'openai-broker' ] || { echo 'B2C_E2E_PROFILE_MISMATCH' >&2; exit 1; }
[ "$(value_of CODEX_MODEL)" = 'gpt-5.6-sol' ] || { echo 'B2C_E2E_CODEX_MODEL_MISMATCH' >&2; exit 1; }
case "$(value_of CODEX_BROKER_BASE_URL)" in
  http://*:3080) ;;
  *) echo 'B2C_E2E_BROKER_URL_MISSING' >&2; exit 1 ;;
esac

echo 'PASS: live untrusted Codex container has capability-only broker environment'

broker_logs=''
for _ in $(seq 1 80); do
  broker_logs="$(docker logs "agent-dispatch-broker-$run_key" 2>&1 || true)"
  if printf '%s\n' "$broker_logs" | grep -q '^B2C_POST_MODEL_OK=1$'; then
    break
  fi
  sleep 0.05
done
printf '%s\n' "$broker_logs" | grep -q '^B2C_WS_AUTH_OK=1$' || { echo 'B2C_E2E_WS_AUTH_NOT_PROVEN' >&2; exit 1; }
printf '%s\n' "$broker_logs" | grep -q '^B2C_POST_AUTH_OK=1$' || { echo 'B2C_E2E_POST_AUTH_NOT_PROVEN' >&2; exit 1; }
printf '%s\n' "$broker_logs" | grep -q '^B2C_POST_MODEL_OK=1$' || { echo 'B2C_E2E_MODEL_NOT_PROVEN' >&2; exit 1; }

set +e
wait "$wrapper_pid"
wrapper_status=$?
set -e
wrapper_pid=''

# No-change is intentional: the local mock returns a successful response but no
# editing tool calls. The wrapper must reach patch validation, proving the real
# Codex process completed through the broker, then fail closed on no changes.
[ "$wrapper_status" -ne 0 ] || { echo 'B2C_E2E_EXPECTED_NO_CHANGE_FAILURE_MISSING' >&2; exit 1; }
category="$(cat "$runtime_root/failure_category" 2>/dev/null || true)"
reason="$(cat "$runtime_root/failure_reason" 2>/dev/null || true)"
[ "$category" = 'AGENT_PATCH_INVALID' ] || { echo "B2C_E2E_UNEXPECTED_CATEGORY=$category" >&2; exit 1; }
[ "$reason" = 'NO_CHANGES' ] || { echo "B2C_E2E_UNEXPECTED_REASON=$reason" >&2; exit 1; }

for secret in 'b2c-local-admin-marker'; do
  if grep -Fq "$secret" "$wrapper_stdout" "$wrapper_stderr" || printf '%s\n' "$broker_logs" | grep -Fq "$secret"; then
    echo 'B2C_E2E_SECRET_LEAKED_TO_LOG' >&2
    exit 1
  fi
done

echo 'PASS: real Codex used opaque capability and exact model through ordinary broker wiring'
echo 'B2C_ORDINARY_CODEX_BROKER_E2E=PASS'
echo 'PROVIDER_INFERENCE=0'
