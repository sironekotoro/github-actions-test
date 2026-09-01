#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CANDIDATE="${1:-$ROOT}"
[ -f "$CANDIDATE/docker/review-repair-agent.Dockerfile" ] || { echo "CODEX_B2A_INVALID_CANDIDATE: missing pinned agent Dockerfile" >&2; exit 1; }
[ -f "$CANDIDATE/scripts/agents/codex.sh" ] || { echo "CODEX_B2A_INVALID_CANDIDATE: missing Codex adapter" >&2; exit 1; }

suffix="${GITHUB_RUN_ID:-$$}-${RANDOM}"
agent_image="codex-b2a-agent:${suffix}"
network="codex-b2a-${suffix}"
mock_name="codex-b2a-mock-${suffix}"
probe_name="codex-b2a-probe-${suffix}"
tmpdir="$(mktemp -d)"
mock_script="$tmpdir/mock.mjs"
workspace="$tmpdir/workspace"
mkdir -p "$workspace"
printf 'B2a local request-shape discovery workspace.\n' > "$workspace/README.txt"

cleanup() {
  docker rm -f "$probe_name" "$mock_name" >/dev/null 2>&1 || true
  docker network rm "$network" >/dev/null 2>&1 || true
  docker image rm -f "$agent_image" >/dev/null 2>&1 || true
  rm -rf "$tmpdir"
}
trap cleanup EXIT

echo "Building pinned Agent Dispatch image from trusted checkout..."
docker build --tag "$agent_image" --file "$CANDIDATE/docker/review-repair-agent.Dockerfile" "$CANDIDATE" >/dev/null

codex_version="$(docker run --rm --network none --read-only --cap-drop=ALL --security-opt=no-new-privileges "$agent_image" codex --version 2>&1)"
printf 'Pinned Codex CLI: %s\n' "$codex_version"
case "$codex_version" in
  *0.147.0*) ;;
  *) echo "CODEX_B2A_VERSION_MISMATCH: expected pinned Codex CLI 0.147.0" >&2; exit 1 ;;
esac

cat > "$mock_script" <<'NODE'
import http from "node:http";
const expectedCapability = "b2a-local-capability";
const safeHeader = (req, name) => req.headers[name] ?? null;

function summarizeBody(raw, contentEncoding) {
  let parsed = null;
  let parseOk = false;
  if (!contentEncoding || contentEncoding === "identity") {
    try {
      parsed = JSON.parse(raw.toString("utf8"));
      parseOk = true;
    } catch {}
  }
  const inputItemTypes = Array.isArray(parsed?.input) ? parsed.input.map((item) => item?.type ?? null) : [];
  const toolTypes = Array.isArray(parsed?.tools) ? parsed.tools.map((tool) => tool?.type ?? null) : [];
  return {
    rawBytes: raw.length,
    parseOk,
    bodyKeys: parsed && typeof parsed === "object" && !Array.isArray(parsed) ? Object.keys(parsed).sort() : [],
    model: parsed?.model ?? null,
    stream: parsed?.stream ?? null,
    store: parsed?.store ?? null,
    include: parsed?.include ?? null,
    inputItemTypes,
    toolTypes,
  };
}

const server = http.createServer(async (req, res) => {
  const chunks = [];
  for await (const chunk of req) chunks.push(chunk);
  const raw = Buffer.concat(chunks);
  const authorization = safeHeader(req, "authorization");
  const contentEncoding = safeHeader(req, "content-encoding");
  const url = new URL(req.url, "http://mock");

  const capture = {
    method: req.method,
    path: url.pathname,
    query: url.search,
    authorizationScheme: authorization?.split(" ", 1)[0] ?? null,
    authorizationMatchesCapability: authorization === `Bearer ${expectedCapability}`,
    contentType: safeHeader(req, "content-type"),
    contentEncoding,
    accept: safeHeader(req, "accept"),
    userAgent: safeHeader(req, "user-agent"),
    originator: safeHeader(req, "originator"),
    version: safeHeader(req, "version"),
    ...summarizeBody(raw, contentEncoding),
  };
  process.stdout.write(`CAPTURE ${JSON.stringify(capture)}\n`);

  if (req.method === "GET" && req.url === "/healthz") {
    res.writeHead(200, {"content-type": "text/plain"});
    res.end("ok");
    return;
  }
  if (req.method === "POST" && url.pathname === "/v1/responses") {
    const created = {type: "response.created", response: {id: "resp_b2a"}};
    const completed = {
      type: "response.completed",
      response: {
        id: "resp_b2a",
        usage: {input_tokens: 0, input_tokens_details: null, output_tokens: 0, output_tokens_details: null, total_tokens: 0},
      },
    };
    res.writeHead(200, {"content-type": "text/event-stream", "cache-control": "no-cache", connection: "close"});
    res.end(`event: response.created\ndata: ${JSON.stringify(created)}\n\n` +
            `event: response.completed\ndata: ${JSON.stringify(completed)}\n\n`);
    return;
  }
  res.writeHead(404, {"content-type": "application/json"});
  res.end(JSON.stringify({error: {message: "local discovery mock: unsupported route"}}));
});
server.listen(8080, "0.0.0.0", () => process.stdout.write("MOCK_READY\n"));
NODE

docker network create --internal "$network" >/dev/null
docker run -d --name "$mock_name" --network "$network" --network-alias mock \
  --read-only --cap-drop=ALL --security-opt=no-new-privileges \
  --tmpfs /tmp:rw,nosuid,nodev,noexec,size=16m \
  --mount "type=bind,src=$mock_script,dst=/runtime/mock.mjs,readonly" \
  "$agent_image" node /runtime/mock.mjs >/dev/null

mock_ready=false
for _ in $(seq 1 50); do
  if docker logs "$mock_name" 2>&1 | grep -q '^MOCK_READY$'; then mock_ready=true; break; fi
  sleep 0.1
done
[ "$mock_ready" = true ] || { echo "CODEX_B2A_MOCK_START_FAILED" >&2; docker logs "$mock_name" >&2 || true; exit 1; }

set +e
docker run --name "$probe_name" --network "$network" \
  --read-only --cap-drop=ALL --security-opt=no-new-privileges \
  --tmpfs /runtime:rw,nosuid,nodev,size=64m \
  --tmpfs /tmp:rw,nosuid,nodev,size=64m \
  --mount "type=bind,src=$workspace,dst=/workspace" --workdir /workspace \
  --env AGENT=codex \
  --env AGENT_USE_PREBUILT_PROMPT=true \
  --env AGENT_CREDENTIAL_PROFILE=openai-api \
  --env AGENT_CREDENTIAL_VALUE=b2a-local-capability \
  --env AGENT_HOME=/runtime/home \
  --env AGENT_MODEL=b2a-requested-model-marker \
  --env AGENT_MAX_RUNTIME=2 \
  --env AGENT_MAX_ATTEMPTS=1 \
  --env PROMPT_FILE=/runtime/prompt.txt \
  --env AGENT_LOG=/runtime/agent.log \
  "$agent_image" bash -lc '
    set -euo pipefail
    mkdir -p "$AGENT_HOME/.codex"
    cat > "$AGENT_HOME/.codex/config.toml" <<EOF
openai_base_url = "http://mock:8080/v1"
EOF
    printf "%s\n" "Return exactly B2A_OK without invoking tools, then finish." > "$PROMPT_FILE"
    /opt/review-repair-runner/run-agent.sh
  '
probe_status=$?
set -e

probe_logs="$(docker logs "$probe_name" 2>&1 || true)"
mock_logs="$(docker logs "$mock_name" 2>&1 || true)"
printf '%s\n' "$mock_logs" | grep '^CAPTURE ' || true

if [ "$probe_status" -ne 0 ]; then
  echo "CODEX_B2A_PROBE_FAILED: production adapter exited $probe_status" >&2
  printf '%s\n' "$probe_logs" >&2
  exit "$probe_status"
fi

capture_count="$(printf '%s\n' "$mock_logs" | grep -c '^CAPTURE ' || true)"
[ "$capture_count" -ge 1 ] || { echo "CODEX_B2A_NO_REQUEST_CAPTURED" >&2; exit 1; }

responses_count="$(printf '%s\n' "$mock_logs" | grep '^CAPTURE ' | grep -c '"method":"POST","path":"/v1/responses"' || true)"
[ "$responses_count" -ge 1 ] || { echo "CODEX_B2A_RESPONSES_NOT_OBSERVED" >&2; exit 1; }

printf '%s\n' "$mock_logs" | grep '^CAPTURE ' | grep '"method":"POST","path":"/v1/responses"' | grep -q '"authorizationMatchesCapability":true' || {
  echo "CODEX_B2A_AUTH_SHAPE_MISMATCH" >&2
  exit 1
}

echo "CODEX_B2A_DISCOVERY=PASS"
echo "CODEX_B2A_CAPTURE_COUNT=$capture_count"
echo "CODEX_B2A_RESPONSES_COUNT=$responses_count"
echo "CODEX_B2A_PROVIDER_INFERENCE=0"
